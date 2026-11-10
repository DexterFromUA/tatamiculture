import { useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { formatPrice } from '../lib/format'
import { useDrawer } from '../lib/useDrawer'
import type { CustomerOrder } from './CustomerPanel'

type MergeOrder = CustomerOrder & { nova_poshta_ttn: string | null }

export function MergeOrdersDrawer({ orders, busy, error, onClose, onMerge }: {
  orders: MergeOrder[]
  busy: boolean
  error: string | null
  onClose: () => void
  onMerge: (targetId: string) => void
}) {
  const { t } = useTranslation()
  const titleId = useId()
  const { ref, close, onCancel, onClick } = useDrawer({ openOnMount: true, onClose })
  const [targetId, setTargetId] = useState(orders[0]?.id ?? '')
  const target = orders.find(order => order.id === targetId)
  const differentStatuses = new Set(orders.map(order => order.status)).size > 1
  const paidCount = orders.filter(order => order.payment_status === 'PAID').length
  const mixedPayment = paidCount > 0 && paidCount < orders.length
  const hasTtn = orders.some(order => order.nova_poshta_ttn)

  return <dialog ref={ref} className="order-drawer" aria-labelledby={titleId}
    onCancel={event => busy ? event.preventDefault() : onCancel(event)}
    onClick={event => { if (!busy) onClick(event) }}>
    <header className="order-drawer__header">
      <div className="order-drawer__identity"><span className="order-drawer__eyebrow">CRM / {t('Orders')}</span><h2 id={titleId}>{t('Merge orders')}</h2></div>
      <button type="button" className="btn btn--ghost" disabled={busy} onClick={() => close()}>{t('Close')}</button>
    </header>
    <div className="order-drawer__body">
      <form className="form order-drawer__card" onSubmit={event => { event.preventDefault(); if (target && !hasTtn && !mixedPayment && !busy) onMerge(target.id) }}>
        <label className="field"><span>{t('Keep customer and delivery details from')}</span>
          <select value={targetId} disabled={busy} onChange={event => setTargetId(event.target.value)}>
            {orders.map(order => <option key={order.id} value={order.id}>{order.customer_name} · {order.customer_phone} · #{order.receipt_code}</option>)}
          </select>
        </label>
        <ul className="order-drawer__items">{orders.map(order => <li key={order.id}>
          <div><strong>#{order.receipt_code}</strong><small>{order.customer_name} · {t(order.status)} · {t(`payment_${order.payment_status}`)}</small></div>
          <strong>{formatPrice(Number(order.total_price) / 100, order.currency)}</strong>
        </li>)}</ul>
        {differentStatuses && target && <p className="error" role="alert">{t('The orders have different statuses. The list will show the selected order status: {{status}}.', { status: t(target.status) })}</p>}
        {mixedPayment && <p className="error" role="alert">{t('Paid and unpaid orders cannot be merged together.')}</p>}
        {hasTtn && <p className="error" role="alert">{t('Orders with an existing TTN cannot be merged.')}</p>}
        {error && <p className="error" role="alert">{error}</p>}
        <button className="btn" disabled={!target || hasTtn || mixedPayment || busy}>{t(busy ? 'Merging…' : 'Merge orders')}</button>
      </form>
    </div>
  </dialog>
}
