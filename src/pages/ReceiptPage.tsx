import { useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useStore } from '../context/StoreContext'
import { formatDate, formatPrice } from '../lib/format'
import { api } from '../lib/api'
import type { Order } from '../types'

export function ReceiptPage() {
  const { code } = useParams()
  const { store } = useStore()
  const [order, setOrder] = useState<Order | null>(null)
  const [loading, setLoading] = useState(true)

  useEffect(() => {
    let cancelled = false

    const load = async () => {
      if (!code) return
      const next = await api.getOrderByReceipt(code)
      if (!cancelled) {
        setOrder(next)
        setLoading(false)
      }
    }

    void load()
    return () => {
      cancelled = true
    }
  }, [code])

  if (!store) return null
  if (loading) return <div className="page-status">Looking up receipt…</div>

  if (!order) {
    return (
      <section className="page-status">
        <h1>Receipt not found</h1>
        <Link to="/">Back to shop</Link>
      </section>
    )
  }

  return (
    <section className="receipt">
      <header className="page-head">
        <p className="muted">Receipt {order.receiptCode}</p>
        <h1>Thank you, {order.customerName}</h1>
        <p>
          {formatDate(order.createdAt)} · {order.paymentStatus.replaceAll('_', ' ').toLowerCase()}
        </p>
      </header>
      <ul className="line-list">
        {order.items.map((item) => (
          <li key={item.id} className="line line--plain">
            <div>
              <strong>{item.productName}</strong>
              <p className="muted">
                {item.optionName} × {item.quantity}
                {item.isPreOrder ? ' · pre-order' : ''}
              </p>
            </div>
            <span>{formatPrice(item.lineTotal, order.currency)}</span>
          </li>
        ))}
      </ul>
      <p className="summary">
        Total <strong>{formatPrice(order.totalPrice, order.currency)}</strong>
      </p>
      <p className="muted">
        Deliver to {order.deliveryAddress}, {order.deliveryCity}
      </p>
      <Link to="/">Continue shopping</Link>
    </section>
  )
}
