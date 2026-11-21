import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { fetchAll } from '../lib/crm'
import { formatPrice } from '../lib/format'
import { supabaseRequest } from '../lib/supabase'
import {
  alignMergedOrderDates, dashboardCustomer, dashboardDay, dashboardMetrics, dashboardRange, dashboardTrend,
  inDashboardRange, isCancelled, shiftDay,
  type DashboardInventory, type DashboardOrder, type DashboardSale,
} from '../lib/dashboard'
import type { AnalyticsCost, AnalyticsReturn } from '../lib/analytics'

type PaymentStats = { paid: number; failed: number; pending: number; expired?: number; undated: number }
type DashboardData = {
  costs: AnalyticsCost[]; refunds: AnalyticsReturn[]; sales: DashboardSale[]
  demand: { variant_id: string }[]; returns: { id: string; order_id: string; status: string }[]
}
type Props = {
  active: boolean
  storeId: string; currency: string; token: string; orders: DashboardOrder[]; inventory: DashboardInventory[]
  mergeMembers: { order_id: string; root_id: string }[]; revision: number
  onOpenOrders: (ids: string[]) => void; onOpenOrder: (id: string) => void
  onOpenCatalog: (search?: string) => void; onOpenCustomers: () => void; onRefresh: () => void
}

function Change({ current, previous, money = false, currency }: { current: number; previous: number; money?: boolean; currency: string }) {
  const { t } = useTranslation()
  const difference = current - previous
  const text = previous === 0
    ? t(current === 0 ? 'No change' : 'Previous value is zero')
    : `${difference > 0 ? '+' : ''}${Math.round(difference / Math.abs(previous) * 100)}%`
  return <small className="dashboard-change">
    <span className={difference > 0 ? 'dashboard-change--up' : difference < 0 ? 'dashboard-change--down' : ''}>{text}</span>
    <span>{t('Previous period')} · {money ? formatPrice(previous / 100, currency) : previous}</span>
  </small>
}

export function AdminDashboard({ active, storeId, currency: storeCurrency, token, orders, inventory, mergeMembers, revision,
  onOpenOrders, onOpenOrder, onOpenCatalog, onOpenCustomers, onRefresh }: Props) {
  const { t, i18n } = useTranslation()
  const [today, setToday] = useState(() => dashboardDay(Date.now()))
  const [preset, setPreset] = useState('30')
  const [from, setFrom] = useState(() => shiftDay(dashboardDay(Date.now()), -29))
  const [to, setTo] = useState(() => dashboardDay(Date.now()))
  const [currency, setCurrency] = useState(storeCurrency)
  const [data, setData] = useState<Partial<DashboardData>>({})
  const [errors, setErrors] = useState<Partial<Record<keyof DashboardData, string>>>({})
  const [payments, setPayments] = useState<PaymentStats | null>(null)
  const [paymentError, setPaymentError] = useState('')
  const [activeBar, setActiveBar] = useState<number | null>(null)
  const [rankBy, setRankBy] = useState('revenue')
  const [stockTab, setStockTab] = useState<'low' | 'idle' | 'demand'>('low')
  const range = dashboardRange(from, to)
  const rootById = new Map(mergeMembers.map(row => [row.order_id, row.root_id]))
  const rootId = (id: string) => rootById.get(id) ?? id
  const currencies = [...new Set([storeCurrency, ...orders.map(order => order.currency)])]
  const alignedOrders = alignMergedOrderDates(orders, rootById)
  const live = alignedOrders.filter(order => !order.payment_test_mode && order.currency === currency)
  const current = range ? live.filter(order => inDashboardRange(order, range.from, range.to)) : []
  const previous = range ? live.filter(order => inDashboardRange(order, range.previousFrom, range.previousTo)) : []
  const costs = data.costs ?? []
  const refunds = data.refunds ?? []
  const metrics = dashboardMetrics(current, costs, refunds, rootById)
  const previousMetrics = dashboardMetrics(previous, costs, refunds, rootById)
  const money = (minor: number) => formatPrice(minor / 100, currency)
  const date = (day: string) => new Intl.DateTimeFormat(i18n.resolvedLanguage === 'en' ? 'en-GB' : 'uk-UA', {
    day: 'numeric', month: 'short', timeZone: 'UTC',
  }).format(new Date(day + 'T12:00:00Z'))

  useEffect(() => {
    const timer = window.setInterval(() => {
      const next = dashboardDay(Date.now())
      setToday(next)
      if (preset !== 'custom') { setFrom(shiftDay(next, 1 - Number(preset))); setTo(next) }
    }, 60000)
    return () => window.clearInterval(timer)
  }, [preset])

  useEffect(() => {
    if (!active) return
    const abort = new AbortController()
    setData({})
    setErrors({})
    const encoded = encodeURIComponent(storeId)
    const requests = {
      costs: fetchAll<AnalyticsCost>(`/rest/v1/order_financials?select=order_id,cost_amount,orders!inner(store_id)&orders.store_id=eq.${encoded}&order=order_id`, token, abort.signal),
      refunds: fetchAll<AnalyticsReturn>(`/rest/v1/order_returns?select=id,order_id,amount,orders!inner(store_id)&orders.store_id=eq.${encoded}&order=id`, token, abort.signal),
      sales: fetchAll<DashboardSale>(`/rest/v1/order_items?select=id,order_id,product_id,variant_id,product_name,variant_name,quantity,line_total,order_item_costs(unit_cost),orders!inner(store_id)&orders.store_id=eq.${encoded}&order=id`, token, abort.signal),
      demand: fetchAll<{ variant_id: string }>(`/rest/v1/restock_subscriptions?notified_at=is.null&select=variant_id,user_id,product_variants!inner(products!inner(store_id))&product_variants.products.store_id=eq.${encoded}&order=variant_id,user_id`, token, abort.signal),
      returns: fetchAll<{ id: string; order_id: string; status: string }>(`/rest/v1/item_returns?status=in.(requested,received)&select=id,order_id,status,orders!inner(store_id)&orders.store_id=eq.${encoded}&order=id`, token, abort.signal),
    }
    for (const key of Object.keys(requests) as (keyof DashboardData)[]) {
      void requests[key].then(rows => {
        if (!abort.signal.aborted) setData(current => ({ ...current, [key]: rows }))
      }).catch(cause => {
        if (!abort.signal.aborted) setErrors(current => ({ ...current, [key]: cause instanceof Error ? cause.message : 'Action failed' }))
      })
    }
    return () => abort.abort()
  }, [active, storeId, token, revision])

  useEffect(() => {
    if (!active || !range) return
    const abort = new AbortController()
    setPayments(null)
    setPaymentError('')
    void supabaseRequest<PaymentStats>('/rest/v1/rpc/crm_dashboard_payment_stats', {
      method: 'POST', token, signal: abort.signal,
      body: JSON.stringify({ p_store_id: storeId, p_from: from, p_to: to, p_currency: currency }),
    }).then(result => { if (!abort.signal.aborted) setPayments(result) })
      .catch(cause => { if (!abort.signal.aborted) setPaymentError(cause.message) })
    return () => abort.abort()
  }, [active, storeId, token, from, to, currency, revision, Boolean(range)])

  const financeReady = Boolean(data.costs && data.refunds)
  const periodIds = new Set(current.filter(order => !isCancelled(order)).map(order => order.id))
  const deliveredIds = new Set(current.filter(order => order.status === 'COMPLETED').map(order => order.id))
  const trend = range ? dashboardTrend(live, range) : []
  const max = Math.max(1, ...trend.flatMap(bar => [bar.current, bar.previous]))
  const highlighted = trend[Math.min(activeBar ?? trend.length - 1, trend.length - 1)]
  const currentWork = live.filter(order => !isCancelled(order) && order.status !== 'COMPLETED')
  const awaitingShipment = currentWork.filter(order => ['PENDING', 'PAID', 'IN_PROGRESS', 'WAITING_FOR_STOCK', 'PREPARING_SHIPMENT'].includes(order.status))
  const overdue = awaitingShipment.filter(order => order.payment_status === 'PAID' && Date.now() - Date.parse(order.created_at) >= 86400000)
  const cod = currentWork.filter(order => order.payment_method === 'CASH_ON_DELIVERY' && order.payment_status !== 'PAID' && order.payment_status !== 'REFUNDED')
  const openReturns = (data.returns ?? []).filter(row => live.some(order => order.id === row.order_id))
  const countRoots = (rows: { id: string }[]) => new Set(rows.map(row => rootId(row.id))).size
  const alerts = [
    { label: 'Paid orders over 24 hours old', rows: overdue },
    { label: 'Awaiting shipment', rows: awaitingShipment },
    { label: 'Ready for pickup', rows: currentWork.filter(order => order.status === 'DELIVERED') },
  ]
  const attention = [...new Set([...overdue, ...awaitingShipment].map(order => rootId(order.id)))].slice(0, 4)
    .flatMap(id => { const order = live.find(order => order.id === id); return order ? [order] : [] })
  const allDeliveredIds = new Set(alignedOrders.filter(order => !order.payment_test_mode && order.status === 'COMPLETED' && range && inDashboardRange(order, range.from, range.to)).map(order => order.id))
  const soldVariants = new Set((data.sales ?? []).filter(row => allDeliveredIds.has(row.order_id)).map(row => row.variant_id))
  const demandCounts = new Map<string, number>()
  for (const row of data.demand ?? []) demandCounts.set(row.variant_id, (demandCounts.get(row.variant_id) ?? 0) + 1)
  const variants = inventory.filter(product => product.is_active).flatMap(product => product.product_variants
    .map(variant => ({ ...variant, product })))
  const lowStock = variants.filter(variant => variant.stock_quantity < (variant.low_stock_threshold ?? 3))
    .sort((a, b) => a.stock_quantity - b.stock_quantity)
  const idleStock = variants.filter(variant => variant.stock_quantity > 0 && !soldVariants.has(variant.id) && range && dashboardDay(variant.product.created_at) < range.from)
  const wantedStock = variants.filter(variant => demandCounts.has(variant.id))
    .sort((a, b) => (demandCounts.get(b.id) ?? 0) - (demandCounts.get(a.id) ?? 0))
  const stockRows = stockTab === 'low' ? lowStock : stockTab === 'idle' ? idleStock : wantedStock
  const productTotals = new Map<string, { name: string; units: number; revenue: number; cost: number; known: boolean; productId: string | null }>()
  for (const sale of data.sales ?? []) {
    if (!deliveredIds.has(sale.order_id)) continue
    const key = sale.product_id ?? sale.product_name
    const row = productTotals.get(key) ?? { name: inventory.find(product => product.id === sale.product_id)?.name ?? sale.product_name, units: 0, revenue: 0, cost: 0, known: true, productId: sale.product_id }
    row.units += sale.quantity
    row.revenue += Number(sale.line_total)
    row.known &&= sale.order_item_costs?.unit_cost != null
    row.cost += Number(sale.order_item_costs?.unit_cost ?? 0) * sale.quantity
    productTotals.set(key, row)
  }
  const rankedProducts = [...productTotals.values()].sort((a, b) => {
    if (rankBy === 'profit') return Number(b.known) - Number(a.known) || (b.revenue - b.cost) - (a.revenue - a.cost)
    return rankBy === 'units' ? b.units - a.units : b.revenue - a.revenue
  }).slice(0, 5)
  const customerOrders = new Map<string, Set<string>>()
  for (const order of live.filter(order => !isCancelled(order))) {
    const key = dashboardCustomer(order)
    if (key) customerOrders.set(key, new Set([...(customerOrders.get(key) ?? []), rootId(order.id)]))
  }
  const buyers = new Set(current.filter(order => !isCancelled(order)).map(dashboardCustomer).filter((key): key is string => Boolean(key)))
  const repeat = [...buyers].filter(key => (customerOrders.get(key)?.size ?? 0) > 1).length
  const discounted = current.filter(order => periodIds.has(order.id) && order.customer_discount_amount > 0)
  const dataError = (key: keyof DashboardData) => errors[key]
    ? <p className="error" role="alert">{t('Could not load this block.')} <button className="text-btn" type="button" onClick={onRefresh}>{t('Try again')}</button></p>
    : <p className="muted" role="status">{t('Loading…')}</p>
  const pickPeriod = (value: string) => {
    setPreset(value)
    setActiveBar(null)
    if (value !== 'custom') { setFrom(shiftDay(today, 1 - Number(value))); setTo(today) }
  }

  return <div className="admin-dashboard">
    <div className="dashboard-toolbar">
      <div className="dashboard-periods" role="group" aria-label={t('Period')}>
        {['7', '30', '90', 'custom'].map(value => <button key={value} type="button" className={preset === value ? 'active' : ''} aria-pressed={preset === value} onClick={() => pickPeriod(value)}>{value === 'custom' ? t('Custom period') : t('{{count}} days', { count: Number(value) })}</button>)}
      </div>
      <div className="dashboard-toolbar__fields">
        <label><span>{t('From date')}</span><input type="date" value={from} max={to || today} onChange={event => { setFrom(event.target.value); setPreset('custom'); setActiveBar(null) }} /></label>
        <label><span>{t('To date')}</span><input type="date" value={to} min={from} max={today} onChange={event => { setTo(event.target.value); setPreset('custom'); setActiveBar(null) }} /></label>
        {currencies.length > 1 && <label><span>{t('Currency')}</span><select value={currency} onChange={event => { setCurrency(event.target.value); setRankBy('revenue') }}>{currencies.map(code => <option key={code}>{code}</option>)}</select></label>}
        <button type="button" className="btn btn--ghost" onClick={onRefresh}>{t('Refresh')}</button>
      </div>
    </div>
    {!range ? <p className="error" role="alert">{t('Choose a valid date range.')}</p> : <>
      <div className="dashboard-comparison">{t('Compared with {{from}} — {{to}}', { from: date(range.previousFrom), to: date(range.previousTo) })}</div>
      <div className="dashboard-kpis">
        <button type="button" onClick={() => onOpenOrders(current.filter(order => !isCancelled(order)).map(order => rootId(order.id)))}>
          <span>{t('Order value')}</span><strong>{money(metrics.revenue)}</strong><Change current={metrics.revenue} previous={previousMetrics.revenue} money currency={currency} />
        </button>
        <button type="button" onClick={() => onOpenOrders(current.filter(order => !isCancelled(order)).map(order => rootId(order.id)))}>
          <span>{t('Orders')}</span><strong>{metrics.count}</strong><Change current={metrics.count} previous={previousMetrics.count} currency={currency} />
        </button>
        <div><span>{t('Average order value')}</span><strong>{money(metrics.average)}</strong><Change current={metrics.average} previous={previousMetrics.average} money currency={currency} /></div>
        <div><span>{t('Gross profit')}</span><strong>{financeReady && currency === 'UAH' && metrics.known ? money(metrics.margin) : '—'}</strong>
          {financeReady && currency === 'UAH' && metrics.known > 0 && previousMetrics.known > 0 && <Change current={metrics.margin} previous={previousMetrics.margin} money currency={currency} />}
          {financeReady ? <small>{currency === 'UAH' ? t('Cost known for {{known}} of {{total}} delivered orders', { known: metrics.known, total: metrics.delivered }) : t('Cost accounting is in UAH.')}</small> : dataError(errors.costs ? 'costs' : 'refunds')}
        </div>
      </div>
      <div className="dashboard-primary-grid">
        <section className="crm-panel dashboard-chart">
          <div className="dashboard-panel-head"><div><h3>{t('Sales trend')}</h3><p>{t('Order value by creation date, excluding cancellations.')}</p></div>
            <div className="dashboard-chart__legend"><span><i />{t('Selected period')}</span><span><i />{t('Previous period')}</span></div>
          </div>
          <div className="dashboard-chart__value" aria-live="polite"><span>{highlighted ? `${date(highlighted.from)}${highlighted.from !== highlighted.to ? ` — ${date(highlighted.to)}` : ''}` : ''}</span>
            <strong>{money(highlighted?.current ?? 0)}</strong><small>{t('Previous period')} · {money(highlighted?.previous ?? 0)}</small>
          </div>
          <div className="dashboard-chart__plot">
            <div className="dashboard-chart__axis"><span>{money(max)}</span><span>{money(Math.round(max / 2))}</span><span>{money(0)}</span></div>
            <div className="dashboard-chart__bars" role="group" aria-label={t('Sales trend')}>
              {trend.map((bar, index) => <button type="button" className={highlighted === bar ? 'active' : ''} key={bar.from}
                aria-label={`${date(bar.from)} · ${money(bar.current)} · ${t('Previous period')} ${money(bar.previous)}`}
                onMouseEnter={() => setActiveBar(index)} onFocus={() => setActiveBar(index)} onClick={() => setActiveBar(index)}>
                <span className="dashboard-chart__bar dashboard-chart__bar--previous" style={{ height: `${bar.previous / max * 100}%` }} />
                <span className="dashboard-chart__bar" style={{ height: `${bar.current / max * 100}%` }} />
              </button>)}
            </div>
          </div>
          <div className="dashboard-chart__dates"><span>{date(range.from)}</span><span>{date(range.to)}</span></div>
        </section>
        <section className="crm-panel dashboard-attention">
          <div className="dashboard-panel-head"><div><h3>{t('Needs attention')}</h3><p>{t('Current workload across all dates.')}</p></div></div>
          <div className="dashboard-alerts">{alerts.map(alert => <button type="button" key={alert.label} onClick={() => onOpenOrders(alert.rows.map(order => rootId(order.id)))}>
            <span>{t(alert.label)}</span><strong className={alert.rows.length && alert.label === 'Paid orders over 24 hours old' ? 'dashboard-warning' : ''}>{countRoots(alert.rows)}</strong><span aria-hidden="true">↗</span>
          </button>)}</div>
          {data.returns ? <button className="dashboard-return-link" type="button" onClick={() => onOpenOrders(openReturns.map(row => rootId(row.order_id)))}>{t('Open returns')}<strong>{openReturns.length}</strong><span aria-hidden="true">↗</span></button> : dataError('returns')}
          <div className="dashboard-order-list">{attention.map(order => <button type="button" key={rootId(order.id)} onClick={() => onOpenOrder(rootId(order.id))}>
            <span><strong>#{order.receipt_code}</strong><small>{order.customer_name}</small></span><span>{date(dashboardDay(order.created_at))}<small>{t(order.status)}</small></span>
          </button>)}</div>
          {!awaitingShipment.length && <p className="muted">{t('No orders awaiting shipment.')}</p>}
        </section>
      </div>
      <div className="dashboard-secondary-grid">
        <section className="crm-panel">
          <div className="dashboard-panel-head"><h3>{t('Payments')}</h3></div>
          {payments ? <>
            <div className="dashboard-payment-counts"><div><span>{t('Successful')}</span><strong>{payments.paid}</strong></div><div><span>{t('Unsuccessful')}</span><strong>{payments.failed}</strong></div><div><span>{t('Awaiting payment')}</span><strong>{payments.pending}</strong></div></div>
            <div className="dashboard-payment-bar" aria-label={t('Successful payments: {{percent}}%', { percent: payments.paid + payments.failed ? Math.round(payments.paid / (payments.paid + payments.failed) * 100) : 0 })}><span style={{ width: `${payments.paid / Math.max(1, payments.paid + payments.failed + payments.pending) * 100}%` }} /></div>
            <p className="dashboard-note">{t('Online payment attempts in the selected period.')}</p>
            {!!payments.expired && <p className="dashboard-note">{t('Expired payment attempts: {{count}}.', { count: payments.expired })}</p>}
            {payments.undated > 0 && <p className="dashboard-note">{t('{{count}} earlier payment attempts have no date and are excluded.', { count: payments.undated })}</p>}
          </> : <p className={paymentError ? 'error' : 'muted'} role={paymentError ? 'alert' : 'status'}>{t(paymentError ? 'Could not load this block.' : 'Loading…')}{paymentError && <button type="button" className="text-btn" onClick={onRefresh}>{t('Try again')}</button>}</p>}
          <button type="button" className="dashboard-cod" onClick={() => onOpenOrders(cod.map(order => rootId(order.id)))}><span>{t('Outstanding cash on delivery')}<small>{t('All open orders')}</small></span><strong>{money(cod.reduce((sum, order) => sum + Number(order.total_price), 0))}</strong><span aria-hidden="true">↗</span></button>
        </section>
        <section className="crm-panel">
          <div className="dashboard-panel-head"><h3>{t('Delivered orders')}</h3><button type="button" className="text-btn" onClick={() => onOpenOrders([...deliveredIds].map(rootId))}>{t('View orders')} ↗</button></div>
          {financeReady ? <>
            <div className="dashboard-finance-row"><span>{t('After confirmed refunds')}</span><strong>{money(metrics.netDelivered)}</strong></div>
            <div className="dashboard-finance-row"><span>{t('Confirmed refunds')}</span><strong>{money(metrics.refunded)}</strong></div>
            <div className="dashboard-finance-row"><span>{t('Gross margin, %')}</span><strong>{currency === 'UAH' && metrics.knownRevenue > 0 ? `${Math.round(metrics.margin / metrics.knownRevenue * 100)}%` : '—'}</strong></div>
            <div className="dashboard-coverage"><span>{t('Cost coverage')}</span><strong>{metrics.known} / {metrics.delivered}</strong><progress max={Math.max(1, metrics.delivered)} value={metrics.known} /></div>
          </> : dataError(errors.costs ? 'costs' : 'refunds')}
          <p className="dashboard-note">{t('Delivered orders created in the selected period. Refunds are included as of today. Profit uses known historical costs, before fees, advertising and operating expenses.')}</p>
        </section>
        <section className="crm-panel">
          <div className="dashboard-panel-head"><h3>{t('Customers and discounts')}</h3><button type="button" className="text-btn" onClick={onOpenCustomers}>{t('View customers')} ↗</button></div>
          <div className="dashboard-finance-row"><span>{t('Customers with orders')}</span><strong>{buyers.size}</strong></div>
          <div className="dashboard-finance-row"><span>{t('With multiple orders in their history')}</span><strong>{repeat}<small> / {buyers.size}</small></strong></div>
          <div className="dashboard-finance-row"><span>{t('Personal discounts granted')}</span><strong>{money(metrics.discounts)}</strong></div>
          <button type="button" className="dashboard-return-link" onClick={() => onOpenOrders(discounted.map(order => rootId(order.id)))}>{t('Orders with a personal discount')}<strong>{countRoots(discounted)}</strong><span aria-hidden="true">↗</span></button>
          <button type="button" className="dashboard-return-link" onClick={() => onOpenOrders(current.filter(isCancelled).map(order => rootId(order.id)))}>{t('Cancelled orders')}<strong>{metrics.cancelled}</strong><span aria-hidden="true">↗</span></button>
        </section>
      </div>
      <div className="dashboard-bottom-grid">
        <section className="crm-panel">
          <div className="dashboard-panel-head"><div><h3>{t('Top products')}</h3><p>{t('Delivered orders in the selected period.')}</p></div>
            <select aria-label={t('Rank products by')} value={rankBy} onChange={event => setRankBy(event.target.value)}><option value="revenue">{t('Revenue')}</option><option value="units">{t('Units sold')}</option>{currency === 'UAH' && <option value="profit">{t('Product profit')}</option>}</select>
          </div>
          {!data.sales ? dataError('sales') : <div className="dashboard-table-wrap"><table className="dashboard-table"><thead><tr><th>{t('Product')}</th><th>{t('Units sold')}</th><th>{t('Revenue')}</th><th>{t('Product profit')}</th></tr></thead><tbody>
            {rankedProducts.map(product => <tr key={product.productId ?? product.name}><td>{product.productId ? <button type="button" className="text-btn" onClick={() => onOpenCatalog(product.name)}>{product.name}</button> : product.name}</td><td data-label={t('Units sold')}>{product.units}</td><td data-label={t('Revenue')}>{money(product.revenue)}</td><td data-label={t('Product profit')}>{currency === 'UAH' && product.known ? money(product.revenue - product.cost) : '—'}</td></tr>)}
            {!rankedProducts.length && <tr><td colSpan={4}>{t('No delivered sales in this period.')}</td></tr>}
          </tbody></table></div>}
          <p className="dashboard-note">{t('Product profit uses item cost snapshots before refunds. Missing costs are shown as a dash.')}</p>
        </section>
        <section className="crm-panel">
          <div className="dashboard-panel-head"><h3>{t('Inventory')}</h3><button type="button" className="text-btn" onClick={() => onOpenCatalog()}>{t('View inventory')} ↗</button></div>
          <div className="dashboard-stock-tabs" role="group" aria-label={t('Inventory')}>
            <button type="button" className={stockTab === 'low' ? 'active' : ''} aria-pressed={stockTab === 'low'} onClick={() => setStockTab('low')}>{t('Low stock')} <strong>{lowStock.length}</strong></button>
            <button type="button" className={stockTab === 'idle' ? 'active' : ''} aria-pressed={stockTab === 'idle'} onClick={() => setStockTab('idle')}>{t('Without sales')}</button>
            <button type="button" className={stockTab === 'demand' ? 'active' : ''} aria-pressed={stockTab === 'demand'} onClick={() => setStockTab('demand')}>{t('Restock demand')}</button>
          </div>
          {stockTab === 'idle' && <p className="dashboard-note">{t('In stock before the selected period, with no delivered sales during it.')}</p>}
          {(stockTab === 'idle' && !data.sales) || (stockTab === 'demand' && !data.demand) ? dataError(stockTab === 'idle' ? 'sales' : 'demand') : <div className="dashboard-stock-list">{stockRows.slice(0, 6).map(variant => <button key={variant.id} type="button" onClick={() => onOpenCatalog(variant.product.name)}>
            <span><strong>{variant.product.name}</strong><small>{variant.name}</small></span><span className={variant.stock_quantity === 0 ? 'dashboard-warning' : ''}>{stockTab === 'demand' ? t('{{count}} waiting', { count: demandCounts.get(variant.id) }) : t('{{count}} in stock', { count: variant.stock_quantity })}<span aria-hidden="true"> ↗</span></span>
          </button>)}{!stockRows.length && <p className="muted">{t('No items in this list.')}</p>}</div>}
        </section>
      </div>
    </>}
  </div>
}
