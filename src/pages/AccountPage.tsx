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
    <section className="form-narrow">
      <header className="page-head">
        <h1>Account</h1>
      </header>
      <dl className="details">
        <div>
          <dt>Name</dt>
          <dd>{user.name}</dd>
        </div>
        <div>
          <dt>Email</dt>
          <dd>{user.email}</dd>
        </div>
        <div>
          <dt>Phone</dt>
          <dd>{user.phone}</dd>
        </div>
      </dl>
      <section className="account-orders">
        <h2>Order history</h2>
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
      <button
        type="button"
        className="btn btn--ghost"
        onClick={() => {
          logout()
          navigate('/')
        }}
      >
        Sign out
      </button>
    </section>
  )
}
