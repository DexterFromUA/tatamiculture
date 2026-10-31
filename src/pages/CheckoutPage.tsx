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

export function CheckoutPage() {
  const { store, products } = useStore()
  const { items, clear } = useCart()
  const { user, token } = useAuth()
  const { addToast } = useToast()
  const navigate = useNavigate()
  const [submitting, setSubmitting] = useState(false)
  const [provider, setProvider] = useState<'LIQPAY' | 'MONOBANK'>(monobankEnabled ? 'MONOBANK' : 'LIQPAY')
  const [error, setError] = useState<string | null>(null)
  const [cityRef, setCityRef] = useState<string | null>(null)
  const [cities, setCities] = useState<Array<{ ref: string; name: string; area: string }>>([])
  const [warehouses, setWarehouses] = useState<Array<{ ref: string; name: string }>>([])
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
    void supabaseRequest<Array<{ ref: string; name: string }>>('/functions/v1/nova-poshta-directory', { method: 'POST', body: JSON.stringify({ action: 'warehouses', cityRef }) })
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
    return product && option ? [{ id: `${item.productId}-${item.optionId}`, name: product.name, option: option.name, quantity: item.quantity, total: optionPrice(option) * item.quantity }] : []
  })

  if (items.length === 0) {
    return (
      <section className="page-status">
        <h1>Nothing to check out</h1>
        <Link to="/">Back to shop</Link>
      </section>
    )
  }

  const onSubmit = async (event: FormEvent) => {
    event.preventDefault()
    setError(null)
    setSubmitting(true)
    try {
      if (novaPoshtaEnabled && (!cityRef || !form.address)) throw new Error('Choose a city and Nova Poshta branch')
      if (provider === 'MONOBANK' && monobankEnabled) {
        const { pageUrl } = await startMonobankCheckout({ store, items, checkout: form, token })
        window.location.assign(pageUrl)
        return
      }
      if (provider === 'LIQPAY' && liqPayEnabled) {
        const { data, signature } = await startLiqPayCheckout({ store, items, checkout: form, token })
        redirectToLiqPay(data, signature)
        return
      }
      const order = await api.createOrder({ store, items, checkout: form, token })
      clear()
      addToast('Order placed')
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
    <section className="checkout-layout">
      <form className="form checkout-form" onSubmit={(event) => void onSubmit(event)}>
        <header className="page-head">
          <p className="eyebrow">Secure checkout</p>
          <h1>Delivery details</h1>
          <p className="muted">We will use these details only to prepare and send your order.</p>
        </header>
        {error ? <p className="error">{error}</p> : null}
        <label className="field">
          <span>Name</span>
          <input required value={form.name} onChange={setField('name')} />
        </label>
        <label className="field">
          <span>Phone</span>
          <input required value={form.phone} onChange={setField('phone')} />
        </label>
        <div className="field"><span>City</span><input required placeholder="Start typing your city" value={form.city} onChange={(event) => { setCityRef(null); setForm((current) => ({ ...current, city: event.target.value, address: '' })) }} />{novaPoshtaEnabled && cities.length > 0 ? <div className="city-results" role="listbox">{cities.map((city) => <button type="button" role="option" key={city.ref} onClick={() => { setCityRef(city.ref); setForm((current) => ({ ...current, city: city.name, address: '' })); setCities([]) }}><strong>{city.name}</strong>{city.area ? <small>{city.area}</small> : null}</button>)}</div> : null}{novaPoshtaEnabled && deliveryError ? <small className="error">Nova Poshta: {deliveryError}</small> : null}</div>
        {novaPoshtaEnabled && cityRef ? <label className="field"><span>Nova Poshta branch or parcel locker</span><select required disabled={warehouses.length === 0} value={warehouses.some((warehouse) => warehouse.name === form.address) ? form.address : ''} onChange={(event) => setForm((current) => ({ ...current, address: event.target.value }))}><option value="">{warehouses.length ? 'Choose branch' : 'Loading branches…'}</option>{warehouses.map((warehouse) => <option key={warehouse.ref} value={warehouse.name}>{warehouse.name}</option>)}</select></label> : null}
        {!novaPoshtaEnabled ? <label className="field"><span>Address</span><input required value={form.address} onChange={setField('address')} /></label> : null}
        <label className="field">
          <span>Note</span>
          <textarea value={form.note} onChange={setField('note')} rows={3} />
        </label>
        {liqPayEnabled || monobankEnabled ? <fieldset className="payment-methods"><legend>Payment method</legend>
          {monobankEnabled ? <label className="payment-method"><input type="radio" name="provider" value="MONOBANK" checked={provider === 'MONOBANK'} onChange={() => setProvider('MONOBANK')} /><span className="payment-method__radio" aria-hidden="true" /><span><strong>monobank</strong><small>Secure payment page</small></span></label> : null}
          {liqPayEnabled ? <label className="payment-method"><input type="radio" name="provider" value="LIQPAY" checked={provider === 'LIQPAY'} onChange={() => setProvider('LIQPAY')} /><span className="payment-method__radio" aria-hidden="true" /><span><strong>LiqPay</strong><small>Secure payment page</small></span></label> : null}
        </fieldset> : null}
        <button type="submit" className="btn" disabled={submitting}>
          {submitting ? 'Placing order…' : `Pay ${formatPrice(total, store.currency)}`}
        </button>
      </form>
      <aside className="checkout-summary">
        <div className="checkout-summary__head"><p className="eyebrow">Your order</p><h2>{items.reduce((sum, item) => sum + item.quantity, 0)} items</h2></div>
        <ul className="checkout-lines">{cartLines.map((line) => <li key={line.id}><div><strong>{line.name}</strong><span>{line.option} · {line.quantity} pc.</span></div><b>{formatPrice(line.total, store.currency)}</b></li>)}</ul>
        <div className="checkout-delivery"><span>Delivery</span><strong>{novaPoshtaEnabled ? 'Nova Poshta branch / parcel locker' : 'Details at checkout'}</strong><small>Shipping cost is confirmed after dispatch.</small></div>
        <div className="checkout-total"><span>Total</span><strong>{formatPrice(total, store.currency)}</strong></div>
        <p className="checkout-summary__note">Payment is processed on the secure page of {provider === 'MONOBANK' ? 'monobank' : 'LiqPay'}.</p>
      </aside>
    </section>
  )
}
