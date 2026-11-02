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
    <section className="receipt">
      <header className="page-head">
        <p className="muted">{t('Receipt')} {order.receiptCode}</p>
        <h1>{t('Thank you, {{name}}', { name: order.customerName })}</h1>
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
                {item.isPreOrder ? ` · ${t('pre-order')}` : ''}
              </p>
            </div>
            <span>{formatPrice(item.lineTotal, order.currency)}</span>
          </li>
        ))}
      </ul>
      <p className="summary">
        {t('Total')} <strong>{formatPrice(order.totalPrice, order.currency)}</strong>
      </p>
      <p className="muted">
        {t('Deliver to')} {order.deliveryAddress}, {order.deliveryCity}
      </p>
      <section className="receipt-delivery"><h2>{t('Delivery')}</h2>{order.paymentMethod === 'CASH_ON_DELIVERY' ? <p className="muted">{t('Payment on delivery')}</p> : null}{order.novaPoshtaTtn ? <><p><strong>Nova Poshta TTN: {order.novaPoshtaTtn}</strong></p>{order.novaPoshtaStatus ? <p className="muted">{order.novaPoshtaStatus}</p> : <p className="muted">{t('TTN created — status will appear after dispatch.')}</p>}<a className="text-btn" href={`https://novaposhta.ua/tracking/?cargo_number=${encodeURIComponent(order.novaPoshtaTtn)}`} target="_blank" rel="noreferrer">{t('Track shipment')}</a></> : <p className="muted">{t('TTN will be added after dispatch.')}</p>}</section>
      <OrderActivity receiptCode={order.receiptCode} currency={order.currency} />
      <Link to="/">{t('Continue shopping')}</Link>
    </section>
  )
}
