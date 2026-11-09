import { ItemReturns, type ReturnableOrderItem } from './ItemReturns'
import { NovaPoshtaTrackingLink } from './NovaPoshtaTrackingLink'
import type { CustomerOrder } from './CustomerPanel'
import { SalesBreakdown } from './SalesBreakdown'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { supabaseRequest } from '../lib/supabase'
import { fetchAll } from '../lib/crm'
import { formatDate, formatPrice } from '../lib/format'
import { OrderActivity } from './OrderActivity'
import { calculateAnalytics } from '../lib/analytics'
import { useDrawer } from '../lib/useDrawer'

export type MetricOrder = { id: string; user_id: string | null; customer_phone: string; customer_email: string; status: string; payment_status: string; total_price: number; currency: string }
export type OrderDetailsOrder = CustomerOrder & {
  note: string | null
  payment_test_mode: boolean | null
  payment_method: 'ONLINE' | 'CASH_ON_DELIVERY'
  nova_poshta_ttn: string | null
  nova_poshta_status: string | null
}

type OrderDetails = {
  delivery_city: string | null
  delivery_address: string | null
  order_items: Array<ReturnableOrderItem & { line_total: number }>
}
type Cost = { order_id: string; cost_amount: number }
type Return = { id: string; order_id: string; amount: number; reason: string }

export function OrderOperations({ order, token, onClose }: { order: OrderDetailsOrder; token: string; onClose: () => void }) {
  const { t } = useTranslation()
  const note = order.note?.trim()
  const { ref: dialogRef, close: closeDrawer, onCancel, onClick } = useDrawer({ openOnMount: true, onClose })
  const [details, setDetails] = useState<OrderDetails | null>(null)
  const [detailsFailed, setDetailsFailed] = useState(false)
  const [returns, setReturns] = useState<Return[]>([])
  const [revision, setRevision] = useState(0)
  const [error, setError] = useState('')
  useEffect(() => {
    const abort = new AbortController()
    const fields = 'delivery_city,delivery_address,order_items(id,product_id,variant_id,product_name,variant_name,quantity,unit_price,line_total)'
    void supabaseRequest<OrderDetails[]>(`/rest/v1/orders?id=eq.${encodeURIComponent(order.id)}&select=${fields}`, { token, signal: abort.signal })
      .then(([result]) => {
        if (abort.signal.aborted) return
        setDetails(result ?? null)
        setDetailsFailed(!result)
      })
      .catch(() => { if (!abort.signal.aborted) setDetailsFailed(true) })
    return () => abort.abort()
  }, [order.id, token])
  useEffect(() => {
    const abort = new AbortController()
    void supabaseRequest<Return[]>(`/rest/v1/order_returns?order_id=eq.${order.id}&select=id,order_id,amount,reason&order=created_at.desc`, { token, signal: abort.signal })
      .then(items => {
        if (!abort.signal.aborted) {
          setReturns(items)
          setError('')
        }
      }).catch(cause => { if (!abort.signal.aborted) setError(cause.message) })
    return () => abort.abort()
  }, [order.id, token, revision])
  const canManageReturns = order.status === 'DELIVERED' && details
  return <dialog ref={dialogRef} className="order-drawer" aria-labelledby="order-drawer-title"
    onCancel={onCancel} onClick={onClick}>
    <header className="order-drawer__header">
      <div className="order-drawer__identity">
        <span className="order-drawer__eyebrow">CRM / {t('Orders')}</span>
        <h2 id="order-drawer-title">{t('Order details')}</h2>
        <div className="order-drawer__meta"><span>#{order.receipt_code}</span>{order.payment_test_mode && <span>{t('Test order')}</span>}<span>{t(order.status)}</span></div>
      </div>
      <button type="button" className="btn btn--ghost" onClick={() => closeDrawer()}>{t('Close')}</button>
    </header>
    <div className="order-drawer__body">
      <section className="order-drawer__card">
        <h3>{t('Order summary')}</h3>
        <dl className="order-drawer__details">
          <div><dt>{t('Name')}</dt><dd>{order.customer_name || '—'}</dd></div>
          <div><dt>{t('Phone')}</dt><dd>{order.customer_phone ? <a href={`tel:${order.customer_phone}`}>{order.customer_phone}</a> : '—'}</dd></div>
          {order.customer_email && <div><dt>{t('Email')}</dt><dd>{order.customer_email}</dd></div>}
          <div><dt>{t('Order date')}</dt><dd><time dateTime={order.created_at}>{formatDate(order.created_at)}</time></dd></div>
          <div><dt>{t('Payment method')}</dt><dd>{t(order.payment_method === 'CASH_ON_DELIVERY' ? 'Payment on delivery' : 'Online payment')}</dd></div>
          <div><dt>{t('Payment status')}</dt><dd>{t(`payment_${order.payment_status}`)}</dd></div>
          <div><dt>{t('Total')}</dt><dd><strong>{formatPrice(order.total_price / 100, order.currency)}</strong></dd></div>
        </dl>
      </section>
      {details ? <>
        <section className="order-drawer__card">
          <h3>{t('Order items')}</h3>
          {details.order_items.length ? <ul className="order-drawer__items">
            {details.order_items.map(item => <li key={item.id}>
              <div>
                <strong>{item.product_name}</strong>
                <small>{item.variant_name} · {item.quantity} × {formatPrice(item.unit_price / 100, order.currency)}</small>
              </div>
              <strong>{formatPrice(item.line_total / 100, order.currency)}</strong>
            </li>)}
          </ul> : <p className="muted">{t('No items in this order')}</p>}
        </section>
        <section className="order-drawer__card">
          <h3>{t('Delivery')}</h3>
          <dl className="order-drawer__details">
            <div><dt>{t('City')}</dt><dd>{details.delivery_city || '—'}</dd></div>
            <div><dt>{t('Address')}</dt><dd>{details.delivery_address || '—'}</dd></div>
            {order.nova_poshta_ttn && <div><dt>{t('TTN')}</dt><dd>
              <NovaPoshtaTrackingLink ttn={order.nova_poshta_ttn}>{order.nova_poshta_ttn}</NovaPoshtaTrackingLink>
            </dd></div>}
            {order.nova_poshta_status && <div><dt>{t('Shipment status')}</dt><dd>{order.nova_poshta_status}</dd></div>}
            {note && <div className="order-drawer__note"><dt>{t('Note')}</dt><dd>{note}</dd></div>}
          </dl>
        </section>
      </> : detailsFailed ? <p className="error" role="alert">{t('Could not load order details')}</p> : <p role="status">{t('Loading…')}</p>}
      {error && <p className="error" role="alert">{error}</p>}
      {canManageReturns && <ItemReturns orderId={order.id} items={details.order_items} token={token} currency={order.currency} onChange={() => setRevision(value => value + 1)} />}
      <section className="order-drawer__card">
        <div className="order-drawer__section-heading"><span className="order-drawer__section-number">{canManageReturns ? '02' : '01'}</span><h3>{t('Confirmed refunds')}</h3></div>
        {returns.length ? <ul className="note-list">{returns.map(item => <li key={item.id}><strong>{formatPrice(item.amount / 100, order.currency)}</strong><p>{item.reason}</p></li>)}</ul> : <p className="muted">{t('No confirmed refunds yet')}</p>}
      </section>
      <OrderActivity key={revision} orderId={order.id} token={token} currency={order.currency} />
    </div>
  </dialog>
}

export function FinancialAnalytics({ orders, storeId, token }: { orders: MetricOrder[]; storeId: string; token: string }) {
  const { t } = useTranslation()
  const [costs, setCosts] = useState<Cost[]>([])
  const [returns, setReturns] = useState<Return[]>([])
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  useEffect(() => {
    const abort = new AbortController()
    void Promise.all([
      fetchAll<Cost>(`/rest/v1/order_financials?select=order_id,cost_amount,orders!inner(store_id)&orders.store_id=eq.${storeId}&order=order_id`, token, abort.signal),
      fetchAll<Return>(`/rest/v1/order_returns?select=id,order_id,amount,reason,orders!inner(store_id)&orders.store_id=eq.${storeId}&order=id`, token, abort.signal),
    ]).then(([nextCosts, nextReturns]) => { setCosts(nextCosts); setReturns(nextReturns); setLoading(false) }).catch(cause => { if (!abort.signal.aborted) { setError(cause.message); setLoading(false) } })
    return () => abort.abort()
  }, [storeId, token])
  const metrics = calculateAnalytics(orders, costs, returns)
  return <><SalesBreakdown storeId={storeId} token={token} /><section className="crm-panel crm-analytics"><div className="crm-panel__heading"><div><p className="eyebrow">03 / {t('Overview')}</p><h2>{t('Financial analytics')}</h2></div></div>{error ? <p className="error">{error}</p> : loading ? <p>{t('Loading…')}</p> : <>
    <div className="crm-analytics__repeat"><span>{t('Repeat customers')}</span><strong>{metrics.repeat} / {metrics.customers}</strong><span>{metrics.customers ? Math.round(metrics.repeat / metrics.customers * 100) : 0}%</span></div>
    {metrics.currencies.map(row => <div className="crm-analytics__currency" key={row.currency}><h3>{row.currency}</h3><div className="crm-analytics__metrics">
      <div><span>{t('Net delivered revenue')}</span><strong>{formatPrice(row.netRevenue / 100, row.currency)}</strong></div>
      <div><span>{t('Returns')}</span><strong>{formatPrice(row.returned / 100, row.currency)}</strong><small>{row.delivered ? Math.round(row.returnedOrders / row.delivered * 100) : 0}%</small></div>
      <div><span>{t('Gross margin')}</span><strong>{formatPrice(row.margin / 100, row.currency)}</strong></div>
      <div><span>{t('Cost coverage')}</span><strong>{row.known} / {row.delivered}</strong></div>
    </div></div>)}<small className="crm-analytics__note">{t('Margin explanation')}</small></>}</section></>
}
