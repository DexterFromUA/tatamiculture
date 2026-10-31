import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { formatDate, formatPrice } from '../lib/format'
import { api } from '../lib/api'
import type { Order } from '../types'

export function OrdersPage() {
  const { store } = useStore()
  const { token } = useAuth()
  const [orders, setOrders] = useState<Order[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState<string | null>(null)

  useEffect(() => {
    let cancelled = false

    const load = async () => {
      if (!token || !store) return
      try {
        const next = await api.getOrders(token, store.id)
        if (!cancelled) setOrders(next)
      } catch (err) {
        if (!cancelled) setError(err instanceof Error ? err.message : 'Could not load orders')
      } finally {
        if (!cancelled) setLoading(false)
      }
    }

    void load()
    return () => {
      cancelled = true
    }
  }, [token, store])

  if (!store) return null

  if (loading) return <div className="page-status">Loading orders…</div>
  if (error) return <div className="page-status error">{error}</div>

  if (orders.length === 0) {
    return (
      <section className="page-status">
        <h1>No orders yet</h1>
        <Link to={`/${store.slug}`}>Start shopping</Link>
      </section>
    )
  }

  return (
    <section>
      <header className="page-head">
        <h1>Orders</h1>
      </header>
      <ul className="order-list">
        {orders.map((order) => (
          <li key={order.id} className="order-row">
            <div>
              <Link to={`/${store.slug}/receipt/${order.receiptCode}`}>{order.receiptCode}</Link>
              <p className="muted">
                {formatDate(order.createdAt)} · {order.status.replaceAll('_', ' ').toLowerCase()}
              </p>
            </div>
            <strong>{formatPrice(order.totalPrice, order.currency)}</strong>
          </li>
        ))}
      </ul>
    </section>
  )
}
