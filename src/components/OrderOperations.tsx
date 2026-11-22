import { ItemReturns, type ReturnableOrderItem } from './ItemReturns'
import { ConfirmationDialog } from './ConfirmationDialog'
import { NovaPoshtaTrackingLink } from './NovaPoshtaTrackingLink'
import { OrderActionButton } from './OrderActionButton'
import { OrderTtnRecovery } from './OrderTtnRecovery'
import { SplitOrderDialog, type SplitOrderResult } from './SplitOrderDialog'
import type { CustomerOrder } from './CustomerPanel'
import { SalesBreakdown } from './SalesBreakdown'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { supabaseRequest } from '../lib/supabase'
import { fetchAll, orderPaymentStatusKey } from '../lib/crm'
import { formatDate, formatPrice } from '../lib/format'
import { OrderActivity } from './OrderActivity'
import { calculateAnalytics } from '../lib/analytics'
import { paymentMethods } from '../lib/paymentMethods'
import { useDrawer } from '../lib/useDrawer'
import { useStore } from '../context/StoreContext'
import { getOrderDeliveryActions, type OrderDeliveryActions } from '../lib/ttn'

export type MetricOrder = { id: string; user_id: string | null; customer_phone: string; customer_email: string; status: string; payment_status: string; total_price: number; currency: string }
export type OrderDetailsOrder = CustomerOrder & {
  note: string | null
  payment_method: 'ONLINE' | 'CASH_ON_DELIVERY'
  is_new?: boolean
  nova_poshta_ttn: string | null
  nova_poshta_status: string | null
}

type OrderDetails = {
  delivery_city: string | null
  delivery_address: string | null
  order_items: Array<ReturnableOrderItem & { line_total: number }>
  paymentMethodLabels: string[]
  shipment_was_dispatched: boolean
  nova_poshta_document_ref: string | null
  splitOrigin: OrderPaymentRecord | null
}
type OrderPaymentRecord = {
  id: string
  receipt_code: string
  payments: { provider: string; status: string } | null
}
type OrderDetailsRow = Omit<OrderDetails, 'paymentMethodLabels' | 'splitOrigin'> & OrderPaymentRecord & {
  payment_method: OrderDetailsOrder['payment_method']
  split_origin_id: string | null
}
type Cost = { order_id: string; cost_amount: number }
type Return = { id: string; order_id: string; amount: number; reason: string }

export function OrderOperations({ order, orderIds = [order.id], token, onClose, onChanged, onOpenOrder }: {
  order: OrderDetailsOrder
  orderIds?: string[]
  token: string
  onClose: () => void
  onChanged: () => void
  onOpenOrder: (id: string) => void
}) {
  const { t } = useTranslation()
  const { refreshProducts } = useStore()
  const note = order.note?.trim()
  const { ref: dialogRef, close: closeDrawer, onCancel, onClick } = useDrawer({ openOnMount: true, onClose })
  const [details, setDetails] = useState<OrderDetails | null>(null)
  const [detailsFailed, setDetailsFailed] = useState(false)
  const [returns, setReturns] = useState<Return[]>([])
  const [revision, setRevision] = useState(0)
  const [error, setError] = useState('')
  const [confirmRestock, setConfirmRestock] = useState(false)
  const [restocking, setRestocking] = useState(false)
  const [restockError, setRestockError] = useState('')
  const [deliveryActions, setDeliveryActions] = useState<OrderDeliveryActions | null>(null)
  const [detailsRevision, setDetailsRevision] = useState(0)
  const [recoveryMessage, setRecoveryMessage] = useState('')
  const [confirmUnlink, setConfirmUnlink] = useState(false)
  const [unlinking, setUnlinking] = useState(false)
  const [unlinkError, setUnlinkError] = useState('')
  const [splitOpen, setSplitOpen] = useState(false)
  const [splitResult, setSplitResult] = useState<SplitOrderResult | null>(null)
  const idList = [...new Set([order.id, ...orderIds])].join(',')
  const completed = order.status === 'COMPLETED'
  const trackingNumber = deliveryActions ? deliveryActions.ttn : order.nova_poshta_ttn
  const itemCount = details?.order_items.reduce((sum, item) => sum + item.quantity, 0) ?? 0
  const splitBlocked = itemCount < 2 ? 'At least two items are needed to split an order.'
    : orderIds.length > 1 ? 'Combined shipments cannot be split into separate orders here.'
    : details?.shipment_was_dispatched || !['IN_PROGRESS', 'WAITING_FOR_STOCK', 'PREPARING_SHIPMENT'].includes(order.status) ? 'Only orders that have not been shipped can be split.'
    : trackingNumber || details?.nova_poshta_document_ref ? 'Unlink the TTN before splitting the order.'
    : deliveryActions?.ttnAttempt ? 'Resolve the TTN attempt before splitting the order.'
    : order.payment_status !== 'PAID' && (order.payment_method !== 'CASH_ON_DELIVERY' || order.payment_status !== 'PENDING') ? 'Only paid orders and unpaid cash-on-delivery orders can be split.'
    : returns.length ? 'An order with a return or refund cannot be split.' : undefined
  const splitOrigin = details?.splitOrigin
  const paymentMethodLabels = details?.paymentMethodLabels ?? [order.payment_method === 'CASH_ON_DELIVERY' ? 'Payment on delivery' : 'Online payment']
  const refreshDetails = () => {
    setDetailsFailed(false)
    setDetailsRevision(current => current + 1)
  }
  const onWaybillChanged = (ttn: string | null, message: string) => {
    setDeliveryActions(current => ({ cancelStockPending: current?.cancelStockPending ?? false, ttn, ttnAttempt: null }))
    setRecoveryMessage(message)
    setUnlinkError('')
    setRevision(value => value + 1)
    refreshDetails()
    onChanged()
  }
  const unlinkWaybill = async (ttn: string) => {
    setUnlinking(true)
    setRecoveryMessage('')
    setUnlinkError('')
    try {
      await supabaseRequest('/rest/v1/rpc/unlink_order_ttn', {
        method: 'POST', token, body: JSON.stringify({ p_order_id: order.id, p_ttn: ttn }),
      })
      onWaybillChanged(null, 'TTN unlinked from the order.')
    } catch (cause) {
      setUnlinkError(cause instanceof Error ? cause.message : 'Could not unlink the TTN')
    } finally {
      setUnlinking(false)
    }
  }
  useEffect(() => {
    const abort = new AbortController()
    const paymentFields = 'id,receipt_code,payments(provider,status)'
    const fields = `${paymentFields},delivery_city,delivery_address,payment_method,nova_poshta_document_ref,shipment_was_dispatched,split_origin_id,order_items(id,product_id,variant_id,product_name,variant_name,quantity,unit_price,line_total)`
    void supabaseRequest<OrderDetailsRow[]>(`/rest/v1/orders?id=in.(${idList})&select=${fields}`, { token, signal: abort.signal })
      .then(async results => {
        const paymentByOrder = new Map<string, OrderPaymentRecord>(results.map(result => [result.id, result]))
        const missingOrigins = [...new Set(results.flatMap(result =>
          result.split_origin_id && !paymentByOrder.has(result.split_origin_id) ? [result.split_origin_id] : []))]
        if (missingOrigins.length) {
          const origins = await supabaseRequest<OrderPaymentRecord[]>(
            `/rest/v1/orders?id=in.(${missingOrigins.join(',')})&select=${paymentFields}`, { token, signal: abort.signal },
          ).catch(() => [])
          for (const origin of origins) paymentByOrder.set(origin.id, origin)
        }
        if (abort.signal.aborted) return
        const main = results.find(result => result.id === order.id)
        const methods = results.map(({ payment_method, payments, split_origin_id }) => {
          if (payment_method === 'CASH_ON_DELIVERY') return 'Payment on delivery'
          const payment = payments ?? (split_origin_id ? paymentByOrder.get(split_origin_id)?.payments : null)
          if (payment?.status === 'PAID' || payment?.status === 'REFUNDED') {
            return paymentMethods.find(method => method.id === payment.provider)?.name ?? 'Online payment'
          }
          return 'Online payment'
        })
        setDetails(main ? {
          ...main,
          order_items: results.flatMap(result => result.order_items),
          paymentMethodLabels: [...new Set(methods)],
          splitOrigin: main.split_origin_id ? paymentByOrder.get(main.split_origin_id) ?? null : null,
        } : null)
        setDetailsFailed(!main)
      })
      .catch(() => { if (!abort.signal.aborted) setDetailsFailed(true) })
    // New delivery actions are optional while a database migration rolls out.
    void getOrderDeliveryActions(order.id, token, abort.signal).then(actions => {
      if (!abort.signal.aborted) setDeliveryActions(actions)
    }).catch(() => {
      // Keep the last confirmed TTN while a refresh is unavailable.
    })
    return () => abort.abort()
  }, [order.id, token, idList, detailsRevision])
  useEffect(() => {
    const abort = new AbortController()
    void supabaseRequest<Return[]>(`/rest/v1/order_returns?order_id=in.(${idList})&select=id,order_id,amount,reason&order=created_at.desc`, { token, signal: abort.signal })
      .then(items => {
        if (!abort.signal.aborted) {
          setReturns(items)
          setError('')
        }
      }).catch(cause => { if (!abort.signal.aborted) setError(cause.message) })
    return () => abort.abort()
  }, [idList, token, revision])
  const canManageReturns = completed && details
  const restoreStock = async () => {
    setRestocking(true)
    setRestockError('')
    try {
      await supabaseRequest('/rest/v1/rpc/confirm_cancelled_order_stock_return', {
        method: 'POST', token, body: JSON.stringify({ p_order_id: order.id }),
      })
      setDeliveryActions(current => current && { ...current, cancelStockPending: false })
      setRevision(current => current + 1)
      refreshProducts()
    } catch (cause) {
      setRestockError(cause instanceof Error ? cause.message : 'Could not return items to stock.')
    } finally {
      setRestocking(false)
    }
  }
  return <><dialog ref={dialogRef} className="order-drawer" aria-labelledby="order-drawer-title"
    onCancel={onCancel} onClick={onClick}>
    <header className="order-drawer__header">
      <div className="order-drawer__identity">
        <span className="order-drawer__eyebrow">CRM / {t('Orders')}</span>
        <h2 id="order-drawer-title">{t('Order details')}</h2>
        <div className="order-drawer__meta"><span>#{order.receipt_code}</span>{order.is_new && <span className="crm-order__new">{t('New order label')}</span>}<span>{t(order.status)}</span></div>
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
          <div><dt>{t('Payment method')}</dt><dd>{paymentMethodLabels.map(label => t(label)).join(', ')}</dd></div>
          <div><dt>{t('Payment status')}</dt><dd>{t(orderPaymentStatusKey(order))}</dd></div>
          <div><dt>{t('Total')}</dt><dd><strong>{formatPrice(order.total_price / 100, order.currency)}</strong></dd></div>
          {splitOrigin && splitOrigin.id !== order.id && <div>
            <dt>{t('Original order')}</dt>
            <dd><button type="button" className="text-btn" onClick={() => onOpenOrder(splitOrigin.id)}>#{splitOrigin.receipt_code}</button></dd>
          </div>}
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
          <div className="order-drawer__split-actions">
            <OrderActionButton type="button" className="order-drawer__compact-button" aria-haspopup="dialog"
              disabledReason={splitBlocked && t(splitBlocked)} onClick={() => setSplitOpen(true)}>
              <svg viewBox="0 0 20 20" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="1.5" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true">
                <path d="M3 10h5m0 0 3-3m-3 3 3 3M13 3h4v5h-4zM13 12h4v5h-4z" />
              </svg>
              {t('Split order')}
            </OrderActionButton>
          </div>
          {splitResult && <div className="order-drawer__split-result">
            <span role="status">{t('Separate order #{{code}} created.', { code: splitResult.receipt_code })}</span>
            <button type="button" className="text-btn" onClick={() => onOpenOrder(splitResult.order_id)}>{t('Open separate order')}</button>
          </div>}
        </section>
        <section className="order-drawer__card">
          <h3>{t('Delivery')}</h3>
          <dl className="order-drawer__details">
            <div><dt>{t('City')}</dt><dd>{details.delivery_city || '—'}</dd></div>
            <div><dt>{t('Address')}</dt><dd>{details.delivery_address || '—'}</dd></div>
            {trackingNumber && !completed && <div><dt>{t('TTN')}</dt><dd>
              <NovaPoshtaTrackingLink ttn={trackingNumber}>{trackingNumber}</NovaPoshtaTrackingLink>
            </dd></div>}
            {trackingNumber && trackingNumber === order.nova_poshta_ttn && order.nova_poshta_status &&
              <div><dt>{t('Shipment status')}</dt><dd>{order.nova_poshta_status}</dd></div>}
            {note && <div className="order-drawer__note"><dt>{t('Note')}</dt><dd>{note}</dd></div>}
          </dl>
          {trackingNumber && !completed && <>
            <OrderActionButton type="button" className="btn btn--ghost" aria-haspopup="dialog"
              disabledReason={unlinking ? t('The TTN is being unlinked.') : undefined}
              onClick={() => setConfirmUnlink(true)}>{t('Unlink TTN')}</OrderActionButton>
            {confirmUnlink && <ConfirmationDialog title={t('Unlink TTN')}
              message={t('Unlink {{ttn}} from this shipment and stop tracking it here? Manage the shipping document in Nova Poshta.', { ttn: trackingNumber })}
              confirmLabel={t('Unlink TTN')} onClose={confirmed => {
                setConfirmUnlink(false)
                if (confirmed) void unlinkWaybill(trackingNumber)
              }} />}
          </>}
          {!trackingNumber && <OrderTtnRecovery
            key={deliveryActions?.ttnAttempt?.id ?? 'manual'} attempt={deliveryActions?.ttnAttempt} orderId={order.id}
            token={token} canCreateNewTtn={!completed} onRefresh={refreshDetails}
            onResolved={ttn => onWaybillChanged(ttn, ttn ? 'TTN linked to the order.'
              : completed ? 'The TTN attempt was closed.' : 'You can now create a new TTN for this order.')} />}
          {unlinkError && <p className="error" role="alert">{t(unlinkError)}</p>}
          {recoveryMessage && <p role="status">{t(recoveryMessage)}</p>}
        </section>
      </> : detailsFailed ? <section className="order-drawer__card">
        <p className="error" role="alert">{t('Could not load order details')}</p>
        <button type="button" className="text-btn" onClick={refreshDetails}>{t('Try again')}</button>
      </section> : <p role="status">{t('Loading…')}</p>}
      {error && <p className="error" role="alert">{error}</p>}
      {order.status.startsWith('CANCELLED') && deliveryActions?.cancelStockPending && <section className="order-drawer__card">
        <h3>{t('Return cancelled items to stock')}</h3>
        <p>{t('Use this after the parcel is back and the items can be sold again.')}</p>
        {restockError && <p className="error" role="alert">{t(restockError)}</p>}
        <OrderActionButton type="button" className="btn btn--ghost"
          disabledReason={restocking ? t('Stock return is being recorded.') : undefined} onClick={() => setConfirmRestock(true)}>
          {t('Confirm stock return')}
        </OrderActionButton>
        {confirmRestock && <ConfirmationDialog
          title={t('Return cancelled items to stock')}
          message={t('Confirm that the items from this shipment are physically available for sale.')}
          confirmLabel={t('Confirm stock return')}
          onClose={confirmed => {
            setConfirmRestock(false)
            if (confirmed) void restoreStock()
          }} />}
      </section>}
      {canManageReturns && <ItemReturns orderIds={orderIds} items={details.order_items} token={token} currency={order.currency} onChange={() => setRevision(value => value + 1)} />}
      <section className="order-drawer__card">
        <h3>{t('Confirmed refunds')}</h3>
        {returns.length ? <ul className="note-list">{returns.map(item => <li key={item.id}><strong>{formatPrice(item.amount / 100, order.currency)}</strong><p>{item.reason}</p></li>)}</ul> : <p className="muted">{t('No confirmed refunds yet')}</p>}
      </section>
      <OrderActivity key={revision} orderId={order.id} token={token} currency={order.currency} />
      {completed && trackingNumber && <section className="order-drawer__card">
        <dl className="order-drawer__details">
          <div><dt>{t('TTN')}</dt><dd>{trackingNumber}</dd></div>
        </dl>
      </section>}
    </div>
  </dialog>
  {splitOpen && details && <SplitOrderDialog orderId={order.id} items={details.order_items} total={order.total_price}
    currency={order.currency} paid={order.payment_status === 'PAID'} token={token} onClose={() => setSplitOpen(false)}
    onSplit={result => {
      setSplitResult(result)
      setSplitOpen(false)
      setRevision(value => value + 1)
      refreshDetails()
      onChanged()
    }} />}
  </>
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
