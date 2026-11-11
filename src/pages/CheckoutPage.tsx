import { useEffect, useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'
import { useCart } from '../context/CartContext'
import { useStore } from '../context/StoreContext'
import { useToast } from '../context/ToastContext'
import { formatPrice, optionPrice } from '../lib/format'
import { productName } from '../lib/productText'
import { api } from '../lib/api'
import { novaPoshtaEnabled, redirectToLiqPay, startLiqPayCheckout, startMonobankCheckout } from '../lib/payments'
import { getPaymentSettings, paymentMethods, paymentSettingsChanged, paymentUnavailable, type PaymentProvider, type PaymentSettings } from '../lib/paymentMethods'
import { supabaseRequest } from '../lib/supabase'
import type { CheckoutInput } from '../types'
import { useTranslation } from 'react-i18next'

export function CheckoutPage() {
  const { store, products } = useStore()
  const { items, clear, rememberOnlineCheckout } = useCart()
  const { user, token } = useAuth()
  const { addToast } = useToast()
  const navigate = useNavigate()
  const { t, i18n } = useTranslation()
  const [submitting, setSubmitting] = useState(false)
  const storeId = store?.id
  const [preferredProvider, setPreferredProvider] = useState<PaymentProvider | null>(null)
  const [paymentSettings, setPaymentSettings] = useState<PaymentSettings | null>(null)
  const [paymentSettingsFailed, setPaymentSettingsFailed] = useState(false)
  const [paymentAttempt, setPaymentAttempt] = useState(0)
  const availableMethods = paymentSettings ? paymentMethods.filter(method => method.configured && paymentSettings[method.field]) : []
  const testMode = paymentSettings?.payment_test_mode ?? null
  const selectedMethod = availableMethods.find(method => method.id === preferredProvider) ?? availableMethods[0]
  const provider = selectedMethod?.id
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
    if (!storeId) return
    let cancelled = false
    void getPaymentSettings(storeId)
      .then(settings => { if (!cancelled) setPaymentSettings(settings) })
      .catch(() => { if (!cancelled) setPaymentSettingsFailed(true) })
    return () => { cancelled = true }
  }, [storeId, paymentAttempt])

  const refreshPaymentSettings = () => {
    setPaymentSettings(null)
    setPaymentSettingsFailed(false)
    setPaymentAttempt(value => value + 1)
  }

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
    return product && option ? [{ id: `${item.productId}-${item.optionId}`, name: productName(product, i18n.resolvedLanguage), image: product.imgUrls[0], option: option.name, quantity: item.quantity, total: optionPrice(option) * item.quantity }] : []
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
    if (!provider || submitting) return
    setError(null)
    setSubmitting(true)
    try {
      if (novaPoshtaEnabled && (!cityRef || !addressRef || !form.address)) throw new Error(t('Choose a city and Nova Poshta branch'))
      const checkout = novaPoshtaEnabled ? { ...form, cityRef: cityRef ?? undefined, addressRef: addressRef ?? undefined, deliveryServiceType } : form
      if (provider === 'MONOBANK') {
        const { pageUrl, receiptCode } = await startMonobankCheckout({ store, items, checkout, token, testMode })
        rememberOnlineCheckout(receiptCode)
        window.location.assign(pageUrl)
        return
      }
      if (provider === 'LIQPAY') {
        const { data, signature, receiptCode } = await startLiqPayCheckout({ store, items, checkout, token, testMode })
        rememberOnlineCheckout(receiptCode)
        redirectToLiqPay(data, signature)
        return
      }
      const order = await api.createOrder({ store, items, checkout, token })
      clear()
      addToast(t('Order placed'))
      navigate(`/receipt/${order.receiptCode}`)
    } catch (err) {
      const message = err instanceof Error ? err.message : 'Checkout failed'
      setError(message)
      if (message === paymentUnavailable || message === paymentSettingsChanged) {
        setPreferredProvider(null)
        refreshPaymentSettings()
      }
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
      <form id="checkout-form" className="form checkout-form" onSubmit={(event) => void onSubmit(event)}>
        <header className="checkout-form__head">
          <p className="eyebrow">01 / {t('Delivery')}</p>
          <h2>{t('Delivery details')}</h2>
          <p className="muted">{t('We will use these details only to prepare and send your order.')}</p>
        </header>
        {error ? <p className="error" role="alert">{t(error)}</p> : null}
        <div className="checkout-contact">
        <label className="field">
          <span>{t('Name')}</span>
          <input required value={form.name} onChange={setField('name')} />
        </label>
        <label className="field">
          <span>{t('Phone')}</span>
          <input type="tel" autoComplete="tel" required value={form.phone} onChange={setField('phone')} />
        </label>
        </div>
        <div className="field"><label htmlFor="checkout-city">{t('City')}</label><input id="checkout-city" required value={form.city} onChange={(event) => { setCityRef(null); setAddressRef(null); setForm((current) => ({ ...current, city: event.target.value, address: '' })) }} />{novaPoshtaEnabled && cities.length > 0 ? <div className="city-results" role="listbox">{cities.map((city) => <button type="button" role="option" key={city.ref} onClick={() => { setCityRef(city.ref); setAddressRef(null); setForm((current) => ({ ...current, city: city.name, address: '' })); setCities([]) }}><strong>{city.name}</strong>{city.area ? <small>{city.area}</small> : null}</button>)}</div> : null}{novaPoshtaEnabled && deliveryError ? <small className="error">Nova Poshta: {deliveryError}</small> : null}</div>
        {novaPoshtaEnabled && cityRef ? <label className="field"><span>{t('Nova Poshta branch or parcel locker')}</span><select required disabled={warehouses.length === 0} value={addressRef ?? ''} onChange={(event) => { const warehouse = warehouses.find((item) => item.ref === event.target.value); setAddressRef(warehouse?.ref ?? null); setDeliveryServiceType(/поштомат|postomat/i.test(warehouse?.type ?? '') || /поштомат/i.test(warehouse?.name ?? '') ? 'WarehousePostomat' : 'WarehouseWarehouse'); setForm((current) => ({ ...current, address: warehouse?.name ?? '' })) }}><option value="">{warehouses.length ? t('Choose branch') : t('Loading branches…')}</option>{warehouses.map((warehouse) => <option key={warehouse.ref} value={warehouse.ref}>{warehouse.name}</option>)}</select></label> : null}
        {!novaPoshtaEnabled ? <label className="field"><span>{t('Address')}</span><input required value={form.address} onChange={setField('address')} /></label> : null}
        <label className="field">
          <span>{t('Note')}</span>
          <textarea value={form.note} onChange={setField('note')} rows={3} />
        </label>
      </form>
      <aside className="checkout-summary">
        <div className="checkout-summary__head"><p className="eyebrow">02 / {t('Your order')}</p><h2>{t('Order summary')}</h2><span>{t('Items in order: {{quantity}}', { quantity: items.reduce((sum, item) => sum + item.quantity, 0) })}</span></div>
        <ul className="checkout-lines">{cartLines.map((line) => <li key={line.id}>{line.image && <img src={line.image} alt="" />}<div><strong>{line.name}</strong><span>{line.option} · {t('{{quantity}} units', { quantity: line.quantity })}</span></div><b>{formatPrice(line.total, store.currency)}</b></li>)}</ul>
        <div className="checkout-delivery"><span>{t('Delivery')}</span><strong>{novaPoshtaEnabled ? t('Nova Poshta branch or parcel locker') : t('Details at checkout')}</strong><small>{t('Shipping cost is confirmed after dispatch.')}</small></div>
        <div className="checkout-total"><span>{t('Total')}</span><strong>{formatPrice(total, store.currency)}</strong></div>
        <fieldset className="payment-methods" disabled={submitting}>
          <legend><span className="payment-methods__heading"><span>{t('Payment method')}</span>{availableMethods.length === 1 && selectedMethod?.icon && <img className="payment-method__icon" src={selectedMethod.icon} alt={t(selectedMethod.name)} />}</span></legend>
          {availableMethods.length === 1 && selectedMethod ? <div className="payment-method-notice">
            <span className="payment-method__text">
              {!selectedMethod.icon && <strong>{t(selectedMethod.name)}</strong>}
              {selectedMethod.id !== 'CASH_ON_DELIVERY' && testMode && <small>{t('Test payment')}</small>}
            </span>
          </div> : availableMethods.map(method => <label className="payment-method" key={method.id}>
            <input type="radio" form="checkout-form" name="provider" value={method.id} checked={provider === method.id} onChange={() => { setPreferredProvider(method.id); setError(null) }} />
            <span className="payment-method__radio" aria-hidden="true" />
            <span className="payment-method__text">{!method.icon && <strong>{t(method.name)}</strong>}{method.id !== 'CASH_ON_DELIVERY' && testMode && <small>{t('Test payment')}</small>}</span>
            {method.icon && <img className="payment-method__icon" src={method.icon} alt={t(method.name)} />}
          </label>)}
          {paymentSettingsFailed ? <div role="alert">
            <p className="error">{t('Could not load payment methods.')}</p>
            <button type="button" className="text-btn" onClick={refreshPaymentSettings}>{t('Try again')}</button>
          </div> : !paymentSettings ? <p className="muted" role="status">{t('Loading payment methods…')}</p>
            : !provider ? <p className="muted" role="status">{t('No payment methods are currently available. Please try again later.')}</p> : null}
        </fieldset>
        <button type="submit" form="checkout-form" className="btn checkout-submit" disabled={submitting || !provider}>
          {submitting ? t('Placing order…') : !provider || provider === 'CASH_ON_DELIVERY' ? t('Place order') : `${t('Pay')} ${formatPrice(total, store.currency)}`}
        </button>
      </aside></div>
    </section>
  )
}
