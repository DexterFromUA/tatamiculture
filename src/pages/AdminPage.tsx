import { useEffect, useMemo, useState } from 'react'
import { CustomerPanel, type CustomerPanelTarget } from '../components/CustomerPanel'
import { CreateTtnDrawer } from '../components/CreateTtnDrawer'
import { NovaPoshtaTrackingLink } from '../components/NovaPoshtaTrackingLink'
import { AdminTabs } from '../components/AdminTabs'
import type { AdminSection } from '../components/AdminTabs'
import { CatalogAdminPage } from './CatalogAdminPage'
import { SettingsWorkspace } from '../components/SettingsWorkspace'
import { CustomersPage } from './CustomersPage'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { useToast } from '../context/ToastContext'
import { formatDate, formatPrice } from '../lib/format'
import { supabaseConfigured, supabaseRequest } from '../lib/supabase'
import type { OrderStatus } from '../types'
import { useTranslation } from 'react-i18next'
import { downloadCsv, fetchAll, hasStoreMembership } from '../lib/crm'
import { FinancialAnalytics, OrderOperations, type OrderDetailsOrder } from '../components/OrderOperations'

type AdminOrder = OrderDetailsOrder & {
  nova_poshta_document_ref: string | null
  nova_poshta_status_code: string | null
}

type InventoryProduct = {
  id: string
  name: string
  product_variants: Array<{ id: string; name: string; stock_quantity: number; low_stock_threshold?: number; is_preorder: boolean }>
}

const statuses: OrderStatus[] = ['PENDING', 'PAID', 'IN_PROGRESS', 'READY_FOR_PICKUP', 'DELIVERED', 'CANCELLED_BY_USER', 'CANCELLED_BY_STORE']

export function AdminPage() {
  const { store } = useStore()
  const { token, user } = useAuth()
  const { addToast } = useToast()
  const [orders, setOrders] = useState<AdminOrder[]>([])
  const [inventory, setInventory] = useState<InventoryProduct[]>([])
  const [member, setMember] = useState<boolean | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [updatingId, setUpdatingId] = useState<string | null>(null)
  const [ttnOrder, setTtnOrder] = useState<AdminOrder | null>(null)
  const [trackingId, setTrackingId] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [statusFilter, setStatusFilter] = useState<'ALL' | OrderStatus>('ALL')
  const [fromDate, setFromDate] = useState('')
  const [toDate, setToDate] = useState('')
  const [selectedCustomer, setSelectedCustomer] = useState<CustomerPanelTarget | null>(null)
  const [customerRevision, setCustomerRevision] = useState(0)
  const [section, setSection] = useState<AdminSection>('overview')
  const [catalogView, setCatalogView] = useState<'products' | 'stock'>('products')
  const [page, setPage] = useState(1)
  const [selectedOrderId, setSelectedOrderId] = useState<string | null>(null)
  const { t } = useTranslation()

  useEffect(() => {
    let cancelled = false
    const load = async () => {
      if (!store || !token || !user || !supabaseConfigured) return
      try {
        if (!(await hasStoreMembership(store.id, user.id, token))) {
          if (!cancelled) setMember(false)
          return
        }
        const [nextOrders, nextInventory] = await Promise.all([
          fetchAll<AdminOrder>(`/rest/v1/orders?store_id=eq.${encodeURIComponent(store.id)}&select=id,user_id,receipt_code,customer_name,customer_email,customer_phone,note,payment_test_mode,total_price,currency,status,payment_status,created_at,nova_poshta_ttn,nova_poshta_document_ref,nova_poshta_status,nova_poshta_status_code,payment_method&order=created_at.desc,id.desc`, token),
          supabaseRequest<InventoryProduct[]>(`/rest/v1/products?store_id=eq.${encodeURIComponent(store.id)}&select=id,name,product_variants(*)&order=position.asc`, { token }),
        ])
        if (!cancelled) {
          setMember(true)
          setOrders(nextOrders)
          setInventory(nextInventory)
        }
      } catch (cause) {
        if (!cancelled) setError(cause instanceof Error ? cause.message : 'Could not load CRM')
      }
    }
    void load()
    return () => { cancelled = true }
  }, [store, token, user])

  const liveOrders = useMemo(() => orders.filter(order => !order.payment_test_mode), [orders])
  const customerCount = useMemo(() => new Set(liveOrders.map((order) => order.customer_email)).size, [liveOrders])
  const revenue = useMemo(() => liveOrders.filter((order) => order.status !== 'CANCELLED_BY_STORE' && order.status !== 'CANCELLED_BY_USER').reduce((sum, order) => sum + Number(order.total_price), 0) / 100, [liveOrders])
  const deliveredRevenue = useMemo(() => liveOrders.filter((order) => order.status === 'DELIVERED').reduce((sum, order) => sum + Number(order.total_price), 0) / 100, [liveOrders])
  const codOrders = useMemo(() => liveOrders.filter((order) => order.payment_method === 'CASH_ON_DELIVERY'), [liveOrders])
  const visibleOrders = useMemo(() => {
    const query = search.trim().toLowerCase()
    return orders.filter((order) => {
      const matchesQuery = !query || [order.customer_name, order.customer_email, order.receipt_code].some((value) => value.toLowerCase().includes(query))
      const date = order.created_at.slice(0, 10)
      return matchesQuery && (statusFilter === 'ALL' || order.status === statusFilter) && (!fromDate || date >= fromDate) && (!toDate || date <= toDate)
    })
  }, [orders, search, statusFilter, fromDate, toDate])
  const pages = Math.max(1, Math.ceil(visibleOrders.length / 20))
  const currentPage = Math.min(page, pages)
  const pageOrders = visibleOrders.slice((currentPage - 1) * 20, currentPage * 20)
  const selectedOrder = orders.find(order => order.id === selectedOrderId)
  const exportOrders = () => downloadCsv('tatami.culture-orders.csv', [
    [t('Receipt'), t('Name'), t('Email'), t('Phone'), t('Order status'), t('Total'), 'Currency', 'Created'],
    ...visibleOrders.map(order => [order.receipt_code, order.customer_name, order.customer_email, order.customer_phone, t(order.status), Number(order.total_price) / 100, order.currency, order.created_at]),
  ])

  const copyReceiptLink = async (path: string) => {
    try {
      await navigator.clipboard.writeText(new URL(path, window.location.origin).href)
      addToast(t('Receipt link copied'))
    } catch {
      addToast(t('Could not copy the link. Open the receipt using its number.'))
    }
  }

  const changeStatus = async (id: string, status: OrderStatus) => {
    if (!token) return
    setUpdatingId(id)
    setError(null)
    try {
      const updated = await supabaseRequest<AdminOrder>('/rest/v1/rpc/change_order_status', {
        method: 'POST', token, body: JSON.stringify({ p_order_id: id, p_status: status }),
      })
      setOrders((current) => current.map((order) => order.id === id ? { ...order, status: updated.status } : order))
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not update order')
    } finally {
      setUpdatingId(null)
    }
  }

  const cancelAndRestoreStock = async (id: string) => {
    if (!token) return
    setUpdatingId(id)
    setError(null)
    try {
      const updated = await supabaseRequest<AdminOrder>('/rest/v1/rpc/cancel_unpaid_order', {
        method: 'POST', token, body: JSON.stringify({ p_order_id: id }),
      })
      setOrders((current) => current.map((order) => order.id === id ? { ...order, status: updated.status, payment_status: updated.payment_status } : order))
      if (store) {
        const nextInventory = await supabaseRequest<InventoryProduct[]>(`/rest/v1/products?store_id=eq.${encodeURIComponent(store.id)}&select=id,name,product_variants(*)&order=position.asc`, { token })
        setInventory(nextInventory)
      }
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not cancel unpaid order')
    } finally {
      setUpdatingId(null)
    }
  }

  const refreshTracking = async (id: string) => {
    if (!token) return
    setTrackingId(id); setError(null)
    try {
      const result = await supabaseRequest<{ status: string }>('/functions/v1/nova-poshta-track-ttn', { method: 'POST', token, body: JSON.stringify({ orderId: id }) })
      setOrders((current) => current.map((order) => order.id === id ? { ...order, nova_poshta_status: result.status } : order))
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Could not update shipment status') } finally { setTrackingId(null) }
  }

  if (!store) return null
  if (!supabaseConfigured) {
    return <section className="page-status"><h1>{t('CRM needs Supabase')}</h1><p>{t('Configure `.env.local` and apply the project migration first.')}</p></section>
  }
  if (member === false) {
    return <section className="page-status"><h1>{t('Manager access required')}</h1><p>{t('Ask the store owner to add your account to this store.')}</p></section>
  }
  if (error && member === null) return <section className="page-status error">{error}</section>
  if (member === null) return <div className="page-status">{t('Loading CRM…')}</div>

  return (
    <section className="crm-page">
      <header className="crm-header">
        <div className="crm-masthead"><div><p className="eyebrow">{store.name} / {t('management')}</p><h1>{t('CRM')}</h1><p>{t('Your store, in one place.')}</p></div><span className="crm-masthead__mark" aria-hidden="true">T.</span></div>
        <AdminTabs active={section} onChange={(next) => { if (next === 'catalogue') setCatalogView('products'); setSection(next) }} />
      </header>
      {error ? <div className="crm-error" role="alert"><span>{error}</span><button type="button" className="text-btn" onClick={() => setError(null)}>{t('Close')}</button></div> : null}
      <div className="crm-section-head"><div><span className="crm-section-head__label"><span>{store.name}</span> / CRM</span><h2>{section === 'overview' ? t('Overview') : section === 'orders' ? t('Orders') : section === 'customers' ? t('Customers') : section === 'catalogue' ? t('Catalogue') : t('Settings')}</h2></div></div>
      {section === 'customers' ? <CustomersPage revision={customerRevision} onOpenCustomer={id => setSelectedCustomer({ kind: 'customer', id })} /> : section === 'catalogue' ? <CatalogAdminPage key={catalogView} embedded initialView={catalogView} /> : section === 'settings' ? <SettingsWorkspace /> : <>
      {section === 'overview' ? <><div className="crm-stats crm-stats--overview">
        <div><span>{t('Orders')}</span><strong>{liveOrders.length}</strong></div>
        <div><span>{t('Customers')}</span><strong>{customerCount}</strong></div>
        <div><span>{t('Revenue')}</span><strong className="crm-stats__money">{formatPrice(revenue, store.currency)}</strong></div><div><span>{t('Delivered revenue')}</span><strong className="crm-stats__money">{formatPrice(deliveredRevenue, store.currency)}</strong></div><div><span>{t('Payment on delivery')}</span><strong>{codOrders.length}</strong></div>
      </div><div className="overview-grid"><section className="crm-panel crm-attention"><div className="crm-panel__heading"><div><p className="eyebrow">01 / {t('Overview')}</p><h2>{t('Needs attention')}</h2></div><span className="crm-panel__symbol" aria-hidden="true">↗</span></div><div className="crm-attention__row"><span>{t('pending orders')}</span><strong>{liveOrders.filter((order) => order.status === 'PENDING').length}</strong></div><div className="crm-attention__row"><span>{t('failed payments')}</span><strong>{liveOrders.filter((order) => order.payment_status === 'FAILED').length}</strong></div><button type="button" className="crm-inline-link" onClick={() => setSection('orders')}>{t('Open orders')} ↗</button></section><section className="crm-panel crm-inventory"><div className="crm-panel__heading"><div><p className="eyebrow">02 / {t('Catalogue')}</p><h2>{t('Inventory alerts')}</h2></div><span className="crm-panel__symbol" aria-hidden="true">↗</span></div>{inventory.flatMap((product) => product.product_variants.map((variant) => ({ product: product.name, ...variant }))).filter((variant) => !variant.is_preorder && variant.stock_quantity < (variant.low_stock_threshold ?? 3)).slice(0, 5).map((variant) => <div className="crm-attention__row" key={variant.id}><span>{variant.product} · {variant.name}</span><strong className="stock-low">{variant.stock_quantity}</strong></div>)}{!inventory.some(product => product.product_variants.some(variant => !variant.is_preorder && variant.stock_quantity < (variant.low_stock_threshold ?? 3))) ? <p className="muted">{t('No low stock alerts.')}</p> : null}<button type="button" className="crm-inline-link" onClick={() => { setCatalogView('stock'); setSection('catalogue') }}>{t('Manage catalogue')} ↗</button></section></div></> : <>
      <div className="crm-grid crm-grid--orders">
        <section className="crm-panel">
          <div className="order-filters"><label className="search-field"><span>{t('Search name, email or receipt')}</span><input type="search" value={search} onChange={(event) => setSearch(event.target.value)} /></label><select value={statusFilter} onChange={(event) => setStatusFilter(event.target.value as 'ALL' | OrderStatus)}><option value="ALL">{t('All statuses')}</option>{statuses.map((status) => <option key={status} value={status}>{t(status)}</option>)}</select><input aria-label={t('Orders from date')} type="date" value={fromDate} onChange={(event) => setFromDate(event.target.value)} /><input aria-label={t('Orders to date')} type="date" value={toDate} onChange={(event) => setToDate(event.target.value)} /></div>
          <button className="text-btn" disabled={!visibleOrders.length} onClick={exportOrders}>{t('Export CSV')} ({visibleOrders.length})</button>
          <div className="crm-pagination"><button className="text-btn" disabled={currentPage === 1} onClick={() => setPage(currentPage - 1)}>{t('Previous')}</button><span>{currentPage} / {pages}</span><button className="text-btn" disabled={currentPage === pages} onClick={() => setPage(currentPage + 1)}>{t('Next')}</button></div>
          {orders.length === 0 ? <p className="muted">{t('No orders yet.')}</p> : visibleOrders.length === 0 ? <p className="muted">{t('No orders match these filters.')}</p> : <ul className="admin-list">{pageOrders.map((order) => {
            const receiptPath = `/receipt/${encodeURIComponent(order.receipt_code)}`
            const note = order.note?.trim()
            return (
              <li key={order.id} className="crm-order" onClick={event => {
                if (event.target instanceof Element && event.target.closest('a, button, input, select, textarea, label')) return
                setSelectedOrderId(order.id)
              }}>
                <div className="crm-order__identity">
                  <span className="crm-order__reference"><button type="button" className="text-btn" aria-haspopup="dialog" onClick={() => setSelectedOrderId(order.id)}>#{order.receipt_code}</button> · {formatDate(order.created_at)}{order.payment_test_mode && ` · ${t('Test order')}`}</span>
                  {note && <p className="crm-order__note"><strong>{t('Note')}</strong> {note}</p>}
                  {order.customer_email && <span className="crm-order__email">{order.customer_email}</span>}
                </div>
                <div className="crm-order__amount"><strong>{formatPrice(Number(order.total_price) / 100, order.currency)}</strong><span>{order.payment_method === 'CASH_ON_DELIVERY' ? t('Payment on delivery') : t('Online payment')}</span></div>
                <div className="crm-order__status"><span>{t('Order status')}</span>
                <label className="sr-only" htmlFor={`status-${order.id}`}>{t('Order status')}</label>
                <select id={`status-${order.id}`} value={order.status} disabled={order.payment_test_mode || updatingId === order.id} onChange={(event) => void changeStatus(order.id, event.target.value as OrderStatus)}>
                  {statuses.map((status) => <option key={status} value={status}>{t(status)}</option>)}
                </select></div>
                {order.nova_poshta_status ? <p className="crm-order__delivery">{order.nova_poshta_status}</p> : null}
                <div className="crm-order__actions"><button type="button" className="text-btn" onClick={() => void copyReceiptLink(receiptPath)}>{t('Copy receipt link')}</button>
                {!order.payment_test_mode && <button type="button" className="text-btn" aria-haspopup="dialog" title={t('Open customer card')} onClick={() => setSelectedCustomer({ kind: 'order', id: order.id })}>{t('Customer')}</button>}
                {order.nova_poshta_ttn ? (
                  <span className="ttn-actions">
                    <NovaPoshtaTrackingLink className="text-btn" ttn={order.nova_poshta_ttn}>TTN {order.nova_poshta_ttn}</NovaPoshtaTrackingLink>
                    <button type="button" className="text-btn" disabled={trackingId === order.id} onClick={() => void refreshTracking(order.id)}>{trackingId === order.id ? t('Updating…') : t('Update status')}</button>
                  </span>
                ) : (
                  <button type="button" className="text-btn" aria-haspopup="dialog" disabled={order.status.startsWith('CANCELLED')} onClick={() => setTtnOrder(order)}>{t('Create TTN')}</button>
                )}
                {order.status === 'PENDING' && order.payment_status !== 'PAID' ? <button type="button" className="text-btn crm-order__cancel" disabled={updatingId === order.id} onClick={() => void cancelAndRestoreStock(order.id)}>{t(order.payment_test_mode ? 'Cancel test order' : 'Cancel & restore stock')}</button> : null}</div>
              </li>
            )
          })}</ul>}
        </section>
      </div>
      </>}
      </>}
      {selectedCustomer && token && <CustomerPanel key={`${selectedCustomer.kind}:${selectedCustomer.id}`}
        target={selectedCustomer} storeId={store.id} token={token}
        onSaved={() => setCustomerRevision(value => value + 1)} onClose={() => setSelectedCustomer(null)} />}
      {section === 'overview' && token && <FinancialAnalytics orders={liveOrders} storeId={store.id} token={token} />}
      {selectedOrder && token && <OrderOperations key={selectedOrder.id} order={selectedOrder} token={token} onClose={() => setSelectedOrderId(null)} />}
      {ttnOrder && token && <CreateTtnDrawer key={ttnOrder.id} orderId={ttnOrder.id} receiptCode={ttnOrder.receipt_code}
        token={token} onClose={() => setTtnOrder(null)} onCreated={({ ttn, documentRef }) => {
          setOrders(current => current.map(order => order.id === ttnOrder.id
            ? { ...order, nova_poshta_ttn: ttn, nova_poshta_document_ref: documentRef }
            : order))
        }} />}
    </section>
  )
}
