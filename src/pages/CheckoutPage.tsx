import { useEffect, useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'
import { useCart } from '../context/CartContext'
import { useStore } from '../context/StoreContext'
import { useToast } from '../context/ToastContext'
import { formatPrice, optionPrice } from '../lib/format'
import { api } from '../lib/api'
import { liqPayEnabled, monobankEnabled, novaPoshtaEnabled, redirectToLiqPay, startLiqPayCheckout, startMonobankCheckout } from '../lib/payments'
import { supabaseRequest } from '../lib/supabase'
import type { CheckoutInput } from '../types'
import { useTranslation } from 'react-i18next'

export function CheckoutPage() {
  const { store, products } = useStore()
  const { items, clear } = useCart()
  const { user, token } = useAuth()
  const { addToast } = useToast()
  const navigate = useNavigate()
  const { t } = useTranslation()
  const [submitting, setSubmitting] = useState(false)
  const [provider, setProvider] = useState<'LIQPAY' | 'MONOBANK' | 'CASH_ON_DELIVERY'>(monobankEnabled ? 'MONOBANK' : liqPayEnabled ? 'LIQPAY' : 'CASH_ON_DELIVERY')
  const [error, setError] = useState<string | null>(null)
  const [cityRef, setCityRef] = useState<string | null>(null)
  const [addressRef, setAddressRef] = useState<string | null>(null)
  const [deliveryServiceType, setDeliveryServiceType] = useState<'WarehouseWarehouse' | 'WarehousePostomat'>('WarehouseWarehouse')
  const [cities, setCities] = useState<Array<{ ref: string; name: string; area: string }>>([])
  const [warehouses, setWarehouses] = useState<Array<{ ref: string; name: string; type: string }>>([])
  const [deliveryError, setDeliveryError] = useState<string | null>(null)
  const [form, setForm] = useState<CheckoutInput>({
    name: user?.name ?? '',
    email: user?.email ?? '',
    phone: user?.phone ?? '',
    city: user?.city ?? '',
    address: '',
    note: '',
  })

  useEffect(() => {
    if (!novaPoshtaEnabled || cityRef || form.city.trim().length < 2) { setCities([]); setDeliveryError(null); return }
    const timeout = window.setTimeout(() => {
      void supabaseRequest<Array<{ ref: string; name: string; area: string }>>('/functions/v1/nova-poshta-directory', { method: 'POST', body: JSON.stringify({ action: 'cities', query: form.city }) })
        .then((result) => { setCities(result); setDeliveryError(null) })
        .catch((cause) => { setCities([]); setDeliveryError(cause instanceof Error ? cause.message : 'Could not load Nova Poshta cities') })
    }, 300)
    return () => window.clearTimeout(timeout)
  }, [form.city, cityRef])

  useEffect(() => {
    if (!novaPoshtaEnabled || !cityRef) { setWarehouses([]); return }
    void supabaseRequest<Array<{ ref: string; name: string; type: string }>>('/functions/v1/nova-poshta-directory', { method: 'POST', body: JSON.stringify({ action: 'warehouses', cityRef }) })
      .then((result) => { setWarehouses(result); setDeliveryError(null) })
      .catch((cause) => { setWarehouses([]); setDeliveryError(cause instanceof Error ? cause.message : 'Could not load Nova Poshta branches') })
  }, [cityRef])

  if (!store) return null

  const total = items.reduce((sum, item) => {
    const product = products.find((entry) => entry.id === item.productId)
    const option = product?.productOptions.find((entry) => entry.id === item.optionId)
    if (!option) return sum
    return sum + optionPrice(option) * item.quantity
  }, 0)
  const cartLines = items.flatMap((item) => {
    const product = products.find((entry) => entry.id === item.productId)
    const option = product?.productOptions.find((entry) => entry.id === item.optionId)
    return product && option ? [{ id: `${item.productId}-${item.optionId}`, name: product.name, image: product.imgUrls[0], option: option.name, quantity: item.quantity, total: optionPrice(option) * item.quantity }] : []
  })

  if (items.length === 0) {
    return (
      <section className="cart-empty">
        <p className="eyebrow">{t('Checkout')}</p>
        <h1>{t('Nothing to check out')}</h1>
        <Link to="/" className="cart-empty__link">{t('Back to shop')} ↗</Link>
      </section>
    )
  }

  const onSubmit = async (event: FormEvent) => {
    event.preventDefault()
    setError(null)
    setSubmitting(true)
    try {
      if (novaPoshtaEnabled && (!cityRef || !addressRef || !form.address)) throw new Error(t('Choose a city and Nova Poshta branch'))
      const checkout = novaPoshtaEnabled ? { ...form, cityRef: cityRef ?? undefined, addressRef: addressRef ?? undefined, deliveryServiceType } : form
      if (provider === 'MONOBANK' && monobankEnabled) {
        const { pageUrl } = await startMonobankCheckout({ store, items, checkout, token })
        window.location.assign(pageUrl)
        return
      }
      if (provider === 'LIQPAY' && liqPayEnabled) {
        const { data, signature } = await startLiqPayCheckout({ store, items, checkout, token })
        redirectToLiqPay(data, signature)
        return
      }
      const order = await api.createOrder({ store, items, checkout, token })
      clear()
      addToast(t('Order placed'))
      navigate(`/receipt/${order.receiptCode}`)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Checkout failed')
    } finally {
      setSubmitting(false)
    }
  }

  const setField = (key: keyof CheckoutInput) => (event: { target: { value: string } }) => {
    setForm((current) => ({ ...current, [key]: event.target.value }))
  }

  return (
    <section className="checkout-page">
      <header className="checkout-hero"><p className="eyebrow">{t('Secure checkout')}</p><h1>{t('Checkout')}</h1><div className="checkout-hero__footer"><Link to="/cart">← {t('Back to cart')}</Link><span>{t('Items in order: {{quantity}}', { quantity: items.reduce((sum, item) => sum + item.quantity, 0) })}</span></div></header>
      <div className="checkout-layout">
      <form className="form checkout-form" onSubmit={(event) => void onSubmit(event)}>
        <header className="checkout-form__head">
          <p className="eyebrow">01 / {t('Delivery')}</p>
          <h2>{t('Delivery details')}</h2>
          <p className="muted">{t('We will use these details only to prepare and send your order.')}</p>
        </header>
        {error ? <p className="error" role="alert">{error}</p> : null}
        <div className="checkout-contact">
        <label className="field">
          <span>{t('Name')}</span>
          <input required value={form.name} onChange={setField('name')} />
        </label>
        <label className="field">
          <span>{t('Phone')}</span>
          <input required value={form.phone} onChange={setField('phone')} />
        </label>
        </div>
        <div className="field"><label htmlFor="checkout-city">{t('City')}</label><input id="checkout-city" required placeholder={t('Start typing your city')} value={form.city} onChange={(event) => { setCityRef(null); setAddressRef(null); setForm((current) => ({ ...current, city: event.target.value, address: '' })) }} />{novaPoshtaEnabled && cities.length > 0 ? <div className="city-results" role="listbox">{cities.map((city) => <button type="button" role="option" key={city.ref} onClick={() => { setCityRef(city.ref); setAddressRef(null); setForm((current) => ({ ...current, city: city.name, address: '' })); setCities([]) }}><strong>{city.name}</strong>{city.area ? <small>{city.area}</small> : null}</button>)}</div> : null}{novaPoshtaEnabled && deliveryError ? <small className="error">Nova Poshta: {deliveryError}</small> : null}</div>
        {novaPoshtaEnabled && cityRef ? <label className="field"><span>{t('Nova Poshta branch or parcel locker')}</span><select required disabled={warehouses.length === 0} value={addressRef ?? ''} onChange={(event) => { const warehouse = warehouses.find((item) => item.ref === event.target.value); setAddressRef(warehouse?.ref ?? null); setDeliveryServiceType(/поштомат|postomat/i.test(warehouse?.type ?? '') || /поштомат/i.test(warehouse?.name ?? '') ? 'WarehousePostomat' : 'WarehouseWarehouse'); setForm((current) => ({ ...current, address: warehouse?.name ?? '' })) }}><option value="">{warehouses.length ? t('Choose branch') : t('Loading branches…')}</option>{warehouses.map((warehouse) => <option key={warehouse.ref} value={warehouse.ref}>{warehouse.name}</option>)}</select></label> : null}
        {!novaPoshtaEnabled ? <label className="field"><span>{t('Address')}</span><input required value={form.address} onChange={setField('address')} /></label> : null}
        <label className="field">
          <span>{t('Note')}</span>
          <textarea value={form.note} onChange={setField('note')} rows={3} />
        </label>
        {liqPayEnabled || monobankEnabled || novaPoshtaEnabled ? <fieldset className="payment-methods"><legend>{t('Payment method')}</legend>
          {monobankEnabled ? <label className="payment-method"><input type="radio" name="provider" value="MONOBANK" checked={provider === 'MONOBANK'} onChange={() => setProvider('MONOBANK')} /><span className="payment-method__radio" aria-hidden="true" /><span><strong>monobank</strong><small>{t('Secure payment page')}</small></span></label> : null}
          {liqPayEnabled ? <label className="payment-method"><input type="radio" name="provider" value="LIQPAY" checked={provider === 'LIQPAY'} onChange={() => setProvider('LIQPAY')} /><span className="payment-method__radio" aria-hidden="true" /><span><strong>LiqPay</strong><small>{t('Secure payment page')}</small></span></label> : null}
          {novaPoshtaEnabled ? <label className="payment-method"><input type="radio" name="provider" value="CASH_ON_DELIVERY" checked={provider === 'CASH_ON_DELIVERY'} onChange={() => setProvider('CASH_ON_DELIVERY')} /><span className="payment-method__radio" aria-hidden="true" /><span><strong>{t('Payment on delivery')}</strong><small>{t('Pay when receiving at Nova Poshta')}</small></span></label> : null}
        </fieldset> : null}
        <button type="submit" className="btn" disabled={submitting}>
          {submitting ? t('Placing order…') : provider === 'CASH_ON_DELIVERY' ? t('Place order') : `${t('Pay')} ${formatPrice(total, store.currency)}`}
        </button>
      </form>
      <aside className="checkout-summary">
        <div className="checkout-summary__head"><p className="eyebrow">02 / {t('Your order')}</p><h2>{t('Order summary')}</h2><span>{t('Items in order: {{quantity}}', { quantity: items.reduce((sum, item) => sum + item.quantity, 0) })}</span></div>
        <ul className="checkout-lines">{cartLines.map((line) => <li key={line.id}>{line.image ? <img src={line.image} alt="" /> : <span className="checkout-lines__placeholder" aria-hidden="true" />}<div><strong>{line.name}</strong><span>{line.option} · {t('{{quantity}} units', { quantity: line.quantity })}</span></div><b>{formatPrice(line.total, store.currency)}</b></li>)}</ul>
        <div className="checkout-delivery"><span>{t('Delivery')}</span><strong>{novaPoshtaEnabled ? t('Nova Poshta branch or parcel locker') : t('Details at checkout')}</strong><small>{t('Shipping cost is confirmed after dispatch.')}</small></div>
        <div className="checkout-total"><span>{t('Total')}</span><strong>{formatPrice(total, store.currency)}</strong></div>
        <p className="checkout-summary__note">{provider === 'CASH_ON_DELIVERY' ? t(novaPoshtaEnabled ? 'Pay when receiving at Nova Poshta' : 'Mock payments only') : t('Payment is processed on the secure page of {{provider}}.', { provider: provider === 'MONOBANK' ? 'monobank' : 'LiqPay' })}</p>
      </aside></div>
    </section>
  )
}
