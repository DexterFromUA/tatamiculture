import { ItemReturns } from './ItemReturns'
import { SalesBreakdown } from './SalesBreakdown'
import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { supabaseRequest } from '../lib/supabase'
import { fetchAll } from '../lib/crm'
import { formatPrice } from '../lib/format'
import { OrderActivity } from './OrderActivity'
import { calculateAnalytics } from '../lib/analytics'

export type MetricOrder = { id: string; user_id: string | null; customer_phone: string; customer_email: string; status: string; payment_status: string; total_price: number; currency: string }
type Cost = { order_id: string; cost_amount: number }
type Return = { id: string; order_id: string; amount: number; reason: string }

export function OrderOperations({ order, token, onClose }: { order: MetricOrder & { receipt_code: string }; token: string; onClose: () => void }) {
  const { t } = useTranslation()
  const dialog = useRef<HTMLDialogElement>(null)
  useEffect(() => {
    const panel = dialog.current
    panel?.showModal()
    return () => panel?.close()
  }, [])
  const [cost, setCost] = useState('')
  const [returns, setReturns] = useState<Return[]>([])
  const [revision, setRevision] = useState(0)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  useEffect(() => {
    const abort = new AbortController()
    void Promise.all([
      supabaseRequest<Cost[]>(`/rest/v1/order_financials?order_id=eq.${order.id}&select=cost_amount`, { token, signal: abort.signal }),
      supabaseRequest<Return[]>(`/rest/v1/order_returns?order_id=eq.${order.id}&select=id,order_id,amount,reason&order=created_at.desc`, { token, signal: abort.signal }),
    ]).then(([costs, items]) => { setCost(costs[0] ? String(costs[0].cost_amount / 100) : ''); setReturns(items) }).catch(cause => { if (!abort.signal.aborted) setError(cause.message) })
    return () => abort.abort()
  }, [order.id, token, revision])
  const save = async () => {
    const raw = cost
    const minor = Math.round(Number(raw) * 100)
    if (!raw.trim() || !Number.isFinite(minor) || minor < 0) { setError(t('Invalid amount')); return }
    setBusy(true); setError('')
    try {
      await supabaseRequest('/rest/v1/rpc/set_order_cost', { method: 'POST', token, body: JSON.stringify({ p_order_id: order.id, p_amount: minor }) })
      setRevision(value => value + 1)
    } catch (cause) { setError(cause instanceof Error ? cause.message : t('Action failed')) } finally { setBusy(false) }
  }
  return <dialog ref={dialog} className="order-drawer" aria-labelledby="order-drawer-title"
    onCancel={event => { event.preventDefault(); onClose() }}
    onClick={event => { if (event.target === event.currentTarget) onClose() }}>
    <header className="order-drawer__header">
      <div className="order-drawer__identity">
        <span className="order-drawer__eyebrow">CRM / {t("Orders")}</span>
        <h2 id="order-drawer-title">{t('Order operations')}</h2>
        <div className="order-drawer__meta"><span>#{order.receipt_code}</span><span>{t(order.status)}</span></div>
      </div>
      <button type="button" className="btn btn--ghost" onClick={onClose}>{t('Close')}</button>
    </header>
    <div className="order-drawer__body">
      {error && <p className="error" role="alert">{error}</p>}
      <section className="order-drawer__card order-drawer__card--cost">
        <div className="order-drawer__section-heading"><span className="order-drawer__section-number">01</span><h3>{t('Order cost')}</h3></div>
        <form className="order-drawer__cost" onSubmit={event => { event.preventDefault(); void save() }}>
          <label className="field">{t('Order cost')} ({order.currency})
            <input required type="number" min="0" step="0.01" value={cost} onChange={event => setCost(event.target.value)} />
          </label>
          <button className="btn" disabled={busy}>{t(busy ? 'Saving…' : 'Save')}</button>
        </form>
      </section>
      {order.status === 'DELIVERED' && <ItemReturns key={order.id} orderId={order.id} token={token} currency={order.currency} onChange={() => setRevision(value => value + 1)} />}
      <section className="order-drawer__card">
        <div className="order-drawer__section-heading"><span className="order-drawer__section-number">03</span><h3>{t('Confirmed refunds')}</h3></div>
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
