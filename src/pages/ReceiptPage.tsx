import { useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useStore } from '../context/StoreContext'
import { formatDate, formatPrice } from '../lib/format'
import { api } from '../lib/api'
import type { Order } from '../types'
import { useTranslation } from 'react-i18next'
import { OrderActivity } from '../components/OrderActivity'

export function ReceiptPage() {
  const { code } = useParams()
  const { store } = useStore()
  const [order, setOrder] = useState<Order | null>(null)
  const [loading, setLoading] = useState(true)
  const { t } = useTranslation()

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
  if (loading) return <div className="page-status">{t('Looking up receipt…')}</div>

  if (!order) {
    return (
      <section className="page-status">
        <h1>{t('Receipt not found')}</h1>
        <Link to="/">{t('Back to shop')}</Link>
      </section>
    )
  }

  return (
    <section className="receipt-page">
      <header className="receipt-hero">
        <p className="eyebrow">{t('Receipt')} · {order.receiptCode}</p>
        <h1>{t('Thank you, {{name}}', { name: order.customerName })}</h1>
        <p>{formatDate(order.createdAt)}</p>
      </header>
      <div className="receipt-layout"><div className="receipt-content">
      <section className="receipt-card"><div className="receipt-card__head"><div><p className="eyebrow">{t('Your order')}</p><h2>{t('Order items')}</h2></div><span className="receipt-count">{order.items.reduce((sum, item) => sum + item.quantity, 0)}</span></div>
      <ul className="receipt-items">
        {order.items.map((item) => (
          <li key={item.id}>
            <div>
              <strong>{item.productName}</strong>
              <p className="muted">
                {item.optionName} × {item.quantity}
                {item.isPreOrder ? ` · ${t('pre-order')}` : ''}
              </p>
            </div>
            <span>{formatPrice(item.lineTotal, order.currency)}</span>
          </li>
        ))}
      </ul>
      <div className="receipt-total"><span>{t('Total')}</span><strong>{formatPrice(order.totalPrice, order.currency)}</strong></div></section>
      <section className="receipt-card receipt-delivery"><p className="eyebrow">{t('Deliver to')}</p><h2>{t('Delivery')}</h2><p>{[order.deliveryCity, order.deliveryAddress].filter(Boolean).join(', ')}</p>{order.novaPoshtaTtn ? <><p><strong>ТТН: {order.novaPoshtaTtn}</strong></p>{order.novaPoshtaStatus ? <p className="muted">{order.novaPoshtaStatus}</p> : <p className="muted">{t('TTN created — status will appear after dispatch.')}</p>}<a className="receipt-link" href={`https://novaposhta.ua/tracking/?cargo_number=${encodeURIComponent(order.novaPoshtaTtn)}`} target="_blank" rel="noreferrer">{t('Track shipment')} ↗</a></> : <p className="muted">{t('TTN will be added after dispatch.')}</p>}</section>
      <OrderActivity receiptCode={order.receiptCode} currency={order.currency} />
      </div><aside className="receipt-card receipt-summary"><p className="eyebrow">{t('Receipt')} · {order.receiptCode}</p><h2>{t('Order details')}</h2><dl><div><dt>{t('Order status')}</dt><dd>{t(order.status)}</dd></div><div><dt>{t('Payment status')}</dt><dd>{t(`payment_${order.paymentStatus}`)}</dd></div>{order.paymentMethod ? <div><dt>{t('Payment method')}</dt><dd>{t(order.paymentMethod === 'CASH_ON_DELIVERY' ? 'Payment on delivery' : 'Online payment')}</dd></div> : null}</dl><Link to="/" className="btn">{t('Continue shopping')} ↗</Link></aside></div>
    </section>
  )
}
