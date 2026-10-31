import { useEffect, useState } from 'react'
import { Link, useNavigate } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { formatDate, formatPrice } from '../lib/format'
import { api } from '../lib/api'
import type { Order } from '../types'

export function AccountPage() {
  const { user, token, logout } = useAuth()
  const { store } = useStore()
  const navigate = useNavigate()
  const [orders, setOrders] = useState<Order[]>([])
  const [ordersLoading, setOrdersLoading] = useState(true)
  const [ordersError, setOrdersError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false
    const loadOrders = async () => {
      if (!store || !token) return
      try {
        const next = await api.getOrders(token, store.id)
        if (!cancelled) setOrders(next)
      } catch (cause) {
        if (!cancelled) setOrdersError(cause instanceof Error ? cause.message : 'Could not load orders')
      } finally {
        if (!cancelled) setOrdersLoading(false)
      }
    }
    void loadOrders()
    return () => { cancelled = true }
  }, [store, token])

  if (!store || !user) return null

  return (
    <section className="account-page">
      <header className="account-hero">
        <p className="eyebrow">Tatami account</p>
        <h1>Hi, {user.name.split(' ')[0] || 'athlete'}.</h1>
        <p className="muted">Your details and orders, kept together.</p>
      </header>
      <div className="account-layout">
        <aside className="account-card">
          <div className="account-avatar" aria-hidden="true">{(user.name || user.email).trim().charAt(0).toUpperCase()}</div>
          <h2>{user.name || 'Tatami customer'}</h2>
          <dl className="account-details">
            <div><dt>Email</dt><dd>{user.email}</dd></div>
            <div><dt>Phone</dt><dd>{user.phone || '—'}</dd></div>
            <div><dt>City</dt><dd>{user.city || '—'}</dd></div>
          </dl>
          <button type="button" className="btn btn--ghost account-signout" onClick={() => { logout(); navigate('/') }}>Sign out</button>
        </aside>
        <section className="account-orders account-card">
          <div className="account-orders__head"><div><p className="eyebrow">Your purchases</p><h2>Order history</h2></div><span className="account-orders__count">{orders.length}</span></div>
        {ordersLoading ? <p className="muted">Loading orders…</p> : ordersError ? <p className="error">{ordersError}</p> : orders.length === 0 ? <p className="muted">No orders yet.</p> : <ul className="order-list">{orders.map((order) => (
          <li key={order.id} className="order-row">
            <div>
              <Link to={`/receipt/${order.receiptCode}`}>{order.receiptCode}</Link>
              <p className="muted">{formatDate(order.createdAt)} · {order.status.replaceAll('_', ' ').toLowerCase()}</p>
            </div>
            <strong>{formatPrice(order.totalPrice, order.currency)}</strong>
          </li>
        ))}</ul>}
        </section>
      </div>
    </section>
  )
}
