import { useState, type FormEvent } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'
import { useCart } from '../context/CartContext'
import { useStore } from '../context/StoreContext'
import { useToast } from '../context/ToastContext'
import { formatPrice, optionPrice } from '../lib/format'
import { api } from '../lib/api'
import type { CheckoutInput } from '../types'

export function CheckoutPage() {
  const { store, products } = useStore()
  const { items, clear } = useCart()
  const { user, token } = useAuth()
  const { addToast } = useToast()
  const navigate = useNavigate()
  const [submitting, setSubmitting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [form, setForm] = useState<CheckoutInput>({
    name: user?.name ?? '',
    email: user?.email ?? '',
    phone: user?.phone ?? '',
    city: user?.city ?? '',
    address: '',
    note: '',
  })

  if (!store) return null

  const total = items.reduce((sum, item) => {
    const product = products.find((entry) => entry.id === item.productId)
    const option = product?.productOptions.find((entry) => entry.id === item.optionId)
    if (!option) return sum
    return sum + optionPrice(option) * item.quantity
  }, 0)

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
    <section className="split">
      <form className="form" onSubmit={(event) => void onSubmit(event)}>
        <header className="page-head">
          <h1>Checkout</h1>
          <p className="muted">Payment is mocked. No real charge is made.</p>
        </header>
        {error ? <p className="error">{error}</p> : null}
        <label className="field">
          <span>Name</span>
          <input required value={form.name} onChange={setField('name')} />
        </label>
        <label className="field">
          <span>Email</span>
          <input required type="email" value={form.email} onChange={setField('email')} />
        </label>
        <label className="field">
          <span>Phone</span>
          <input required value={form.phone} onChange={setField('phone')} />
        </label>
        <label className="field">
          <span>City</span>
          <input required value={form.city} onChange={setField('city')} />
        </label>
        <label className="field">
          <span>Address</span>
          <input required value={form.address} onChange={setField('address')} />
        </label>
        <label className="field">
          <span>Note</span>
          <textarea value={form.note} onChange={setField('note')} rows={3} />
        </label>
        <button type="submit" className="btn" disabled={submitting}>
          {submitting ? 'Placing order…' : `Pay ${formatPrice(total, store.currency)}`}
        </button>
      </form>
      <aside className="aside">
        <h2>Order</h2>
        <p>{items.reduce((sum, item) => sum + item.quantity, 0)} items</p>
        <p>
          Total <strong>{formatPrice(total, store.currency)}</strong>
        </p>
      </aside>
    </section>
  )
}
