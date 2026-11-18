import { useEffect, useId, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { useStore } from '../context/StoreContext'
import { formatPrice, optionPrice } from '../lib/format'
import { novaPoshtaEnabled } from '../lib/payments'
import { normalizePhone } from '../lib/phone'
import { productName } from '../lib/productText'
import { SupabaseError, supabaseRequest } from '../lib/supabase'
import type { DispatchLocation } from '../lib/ttn'
import { useDrawer } from '../lib/useDrawer'
import type { Store } from '../types'
import { TtnDispatchFields } from './TtnDispatchFields'

const maxQuantity = 20
const emptyLocation: DispatchLocation = { cityRef: '', cityName: '', warehouseRef: '', warehouseName: '' }

export function CreateOrderDrawer({ store, token, onClose, onCreated }: {
  store: Store
  token: string
  onClose: () => void
  onCreated: (id: string) => void
}) {
  const { t, i18n } = useTranslation()
  const { products, refreshProducts } = useStore()
  const titleId = useId()
  const { ref, close, onCancel, onClick } = useDrawer({ openOnMount: true, onClose })
  const [requestId] = useState(() => crypto.randomUUID())
  const [query, setQuery] = useState('')
  const [productId, setProductId] = useState('')
  const [variantId, setVariantId] = useState('')
  const [items, setItems] = useState<Array<{ variantId: string; quantity: string }>>([])
  const [customer, setCustomer] = useState({ name: '', phone: '', email: '' })
  const [manualAddress, setManualAddress] = useState(!novaPoshtaEnabled)
  const [location, setLocation] = useState(emptyLocation)
  const [address, setAddress] = useState({ city: '', address: '' })
  const [note, setNote] = useState('')
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => { void refreshProducts().catch(() => {}) }, [refreshProducts])

  const publishedProducts = products.filter(product => product.isActive)
  const language = i18n.resolvedLanguage
  const search = query.trim().toLocaleLowerCase(language)
  const matchingProducts = publishedProducts.filter(product =>
    product.id === productId || [product.name, product.name_uk, product.name_en].some(name => name?.toLocaleLowerCase(language).includes(search)))
  const selectedProduct = publishedProducts.find(product => product.id === productId)
  const options = selectedProduct?.productOptions.filter(option => !items.some(item => item.variantId === option.id)) ?? []
  const selectedVariant = options.find(option => option.id === variantId && option.quantity > 0)
  const offers = new Map(publishedProducts.flatMap(product => product.productOptions.map(option => [option.id, {
    name: productName(product, language),
    option,
  }] as const)))
  const lines = items.map(item => {
    const offer = offers.get(item.variantId)
    const quantity = Number(item.quantity)
    const limit = Math.min(maxQuantity, offer?.option.quantity ?? 0)
    const valid = Number.isSafeInteger(quantity) && quantity >= 1 && quantity <= limit
    const total = valid && offer ? Math.round(optionPrice(offer.option) * 100) * quantity : 0
    return { ...item, offer, limit, valid, total }
  })
  const total = lines.reduce((sum, line) => sum + line.total, 0)
  const currency = (amount: number) => formatPrice(amount / 100, store.currency)

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (saving || !items.length || lines.some(line => !line.valid)) return
    const phone = normalizePhone(customer.phone)
    if (!phone || !customer.name.trim()) {
      setError('Enter a valid customer name and phone number.')
      return
    }
    if (!manualAddress && (!location.cityRef || !location.warehouseRef)) {
      setError('Choose a city and Nova Poshta branch')
      return
    }
    if (manualAddress && (!address.city.trim() || !address.address.trim())) {
      setError('Enter the city and delivery address.')
      return
    }
    const delivery = manualAddress ? address : {
      city: location.cityName,
      address: location.warehouseName,
      cityRef: location.cityRef,
      addressRef: location.warehouseRef,
      serviceType: /поштомат|postomat/i.test(location.warehouseName) ? 'WarehousePostomat' : 'WarehouseWarehouse',
    }

    setSaving(true)
    setError(null)
    try {
      const order = await supabaseRequest<{ id: string }>('/rest/v1/rpc/create_crm_order', {
        method: 'POST',
        token,
        signal: AbortSignal.timeout(20000),
        body: JSON.stringify({
          p_store_id: store.id,
          p_request_id: requestId,
          p_customer: { ...customer, phone },
          p_delivery: delivery,
          p_note: note,
          p_items: items.map(item => ({ variantId: item.variantId, quantity: Number(item.quantity) })),
          p_expected_total: total,
        }),
      })
      close(() => onCreated(order.id))
    } catch (cause) {
      setError(cause instanceof Error && cause.name !== 'TimeoutError' ? cause.message : 'Could not save this order. Try again.')
      if (cause instanceof SupabaseError && cause.code === 'PT409') void refreshProducts().catch(() => {})
      setSaving(false)
    }
  }

  return <dialog ref={ref} className="order-drawer" aria-labelledby={titleId}
    onCancel={event => saving ? event.preventDefault() : onCancel(event)}
    onClick={event => { if (!saving) onClick(event) }}>
    <header className="order-drawer__header">
      <div className="order-drawer__identity">
        <span className="order-drawer__eyebrow">CRM / {t('Orders')}</span>
        <h2 id={titleId}>{t('Create order')}</h2>
      </div>
      <button type="button" className="btn btn--ghost" disabled={saving} onClick={() => close()}>{t('Close')}</button>
    </header>
    <div className="order-drawer__body">
      <form className="form" onSubmit={event => void submit(event)}>
        <section className="order-drawer__card form">
          <h3>{t('Order items')}</h3>
          <label className="field">
            <span>{t('Search products')}</span>
            <input type="search" value={query} disabled={saving} onChange={event => setQuery(event.target.value)} />
          </label>
          <div className="crm-create-order__fields">
            <label className="field">
              <span>{t('Product')}</span>
              <select value={productId} disabled={saving} onChange={event => { setProductId(event.target.value); setVariantId('') }}>
                <option value="">{t(matchingProducts.length ? 'Select a product' : 'No products match these filters.')}</option>
                {matchingProducts.map(product => <option key={product.id} value={product.id}>
                  {productName(product, language)}{!product.productOptions.some(option => option.quantity > 0) && ` · ${t('Out of stock')}`}
                </option>)}
              </select>
            </label>
            <label className="field">
              <span>{t('Size')}</span>
              <select value={variantId} disabled={saving || !options.length} onChange={event => setVariantId(event.target.value)}>
                <option value="">{t('Choose size')}</option>
                {options.map(option => <option key={option.id} value={option.id} disabled={option.quantity === 0}>
                  {option.name} · {option.quantity === 0 ? t('Out of stock') : formatPrice(optionPrice(option), store.currency)}
                </option>)}
              </select>
            </label>
          </div>
          <button type="button" className="btn btn--ghost" disabled={saving || !selectedVariant} onClick={() => {
            if (!selectedVariant) return
            setItems(current => [...current, { variantId: selectedVariant.id, quantity: '1' }])
            setVariantId('')
          }}>{t('Add to order')}</button>
          <ul className="order-drawer__items crm-create-order__items">
            {lines.map(line => <li key={line.variantId}>
              <div>
                <strong>{line.offer?.name ?? t('Product unavailable')}</strong>
                {line.offer && <small>{line.offer.option.name} · {formatPrice(optionPrice(line.offer.option), store.currency)}</small>}
                {line.limit === 0 && <small className="error">{t('Out of stock')}</small>}
              </div>
              <label className="field">
                <span>{t('Quantity')}</span>
                <input type="number" inputMode="numeric" min={1} max={line.limit} required value={line.quantity}
                  disabled={saving || line.limit === 0} onChange={event => setItems(current => current.map(item =>
                    item.variantId === line.variantId ? { ...item, quantity: event.target.value } : item))} />
              </label>
              <button type="button" className="text-btn" disabled={saving}
                onClick={() => setItems(current => current.filter(item => item.variantId !== line.variantId))}>{t('Remove')}</button>
            </li>)}
          </ul>
        </section>

        <section className="order-drawer__card form">
          <h3>{t('Customer details')}</h3>
          <label className="field"><span>{t('Name')}</span>
            <input required maxLength={200} value={customer.name} disabled={saving} onChange={event => setCustomer({ ...customer, name: event.target.value })} />
          </label>
          <div className="crm-create-order__fields">
            <label className="field"><span>{t('Phone')}</span>
              <input type="tel" required value={customer.phone} disabled={saving} onChange={event => setCustomer({ ...customer, phone: event.target.value })} />
            </label>
            <label className="field"><span>{t('Email')}</span>
              <input type="email" maxLength={254} value={customer.email} disabled={saving} onChange={event => setCustomer({ ...customer, email: event.target.value })} />
            </label>
          </div>
        </section>

        <section className="order-drawer__card form">
          <h3>{t('Delivery details')}</h3>
          {novaPoshtaEnabled && <label className="field"><span>{t('Delivery')}</span>
            <select value={manualAddress ? 'manual' : 'nova-poshta'} disabled={saving} onChange={event => setManualAddress(event.target.value === 'manual')}>
              <option value="nova-poshta">{t('Nova Poshta')}</option>
              <option value="manual">{t('Enter address manually')}</option>
            </select>
          </label>}
          {manualAddress ? <div className="crm-create-order__fields">
            <label className="field"><span>{t('City')}</span>
              <input required maxLength={200} value={address.city} disabled={saving} onChange={event => setAddress({ ...address, city: event.target.value })} />
            </label>
            <label className="field"><span>{t('Address')}</span>
              <input required maxLength={500} value={address.address} disabled={saving} onChange={event => setAddress({ ...address, address: event.target.value })} />
            </label>
          </div> : <TtnDispatchFields recipient location={location} onChange={setLocation} disabled={saving} />}
          <label className="field"><span>{t('Note')}</span>
            <textarea rows={3} maxLength={2000} value={note} disabled={saving} onChange={event => setNote(event.target.value)} />
          </label>
        </section>

        <section className="order-drawer__card form">
          <div className="crm-create-order__total">
            <div><span>{t('Payment method')}</span><strong>{t('Payment on delivery')}</strong></div>
            <div><span>{t('Total')}</span><strong>{currency(total)}</strong></div>
          </div>
          {error && <p className="error" role="alert">{t(error)}</p>}
          <button type="submit" className="btn" disabled={saving || !lines.length || lines.some(line => !line.valid)}>
            {t(saving ? 'Saving…' : 'Create order')}
          </button>
        </section>
      </form>
    </div>
  </dialog>
}
