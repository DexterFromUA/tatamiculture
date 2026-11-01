import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { CustomerPanel, type CustomerOrder } from '../components/CustomerPanel'
import { AdminTabs } from '../components/AdminTabs'
import type { AdminSection } from '../components/AdminTabs'
import { CatalogAdminPage } from './CatalogAdminPage'
import { DeliverySettingsPage } from './DeliverySettingsPage'
import { CustomersPage } from './CustomersPage'
import { NovaPostModeToggle } from '../components/NovaPostModeToggle'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { formatDate, formatPrice } from '../lib/format'
import { supabaseConfigured, supabaseRequest } from '../lib/supabase'
import type { OrderStatus } from '../types'

type AdminOrder = CustomerOrder & {
  nova_poshta_ttn: string | null
  nova_poshta_document_ref: string | null
  nova_poshta_status: string | null
  nova_poshta_status_code: string | null
  payment_method: 'ONLINE' | 'CASH_ON_DELIVERY'
}

type InventoryProduct = {
  id: string
  name: string
  product_variants: Array<{ id: string; name: string; stock_quantity: number }>
}

const statuses: OrderStatus[] = ['PENDING', 'PAID', 'IN_PROGRESS', 'READY_FOR_PICKUP', 'DELIVERED', 'CANCELLED_BY_USER', 'CANCELLED_BY_STORE']

export function AdminPage() {
  const { store } = useStore()
  const { token, user } = useAuth()
  const [orders, setOrders] = useState<AdminOrder[]>([])
  const [inventory, setInventory] = useState<InventoryProduct[]>([])
  const [member, setMember] = useState<boolean | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [updatingId, setUpdatingId] = useState<string | null>(null)
  const [creatingTtnId, setCreatingTtnId] = useState<string | null>(null)
  const [trackingId, setTrackingId] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [statusFilter, setStatusFilter] = useState<'ALL' | OrderStatus>('ALL')
  const [fromDate, setFromDate] = useState('')
  const [toDate, setToDate] = useState('')
  const [selectedCustomer, setSelectedCustomer] = useState<AdminOrder | null>(null)
  const [section, setSection] = useState<AdminSection>('overview')

  useEffect(() => {
    let cancelled = false
    const load = async () => {
      if (!store || !token || !user || !supabaseConfigured) return
      try {
        const memberships = await supabaseRequest<Array<{ role: string }>>(
          `/rest/v1/store_members?store_id=eq.${encodeURIComponent(store.id)}&user_id=eq.${encodeURIComponent(user.id)}&select=role`,
          { token },
        )
        if (!memberships[0]) {
          if (!cancelled) setMember(false)
          return
        }
        const [nextOrders, nextInventory] = await Promise.all([
          supabaseRequest<AdminOrder[]>(`/rest/v1/orders?store_id=eq.${encodeURIComponent(store.id)}&select=id,user_id,receipt_code,customer_name,customer_email,customer_phone,total_price,currency,status,payment_status,created_at,nova_poshta_ttn,nova_poshta_document_ref,nova_poshta_status,nova_poshta_status_code,payment_method&order=created_at.desc`, { token }),
          supabaseRequest<InventoryProduct[]>(`/rest/v1/products?store_id=eq.${encodeURIComponent(store.id)}&select=id,name,product_variants(id,name,stock_quantity)&order=position.asc`, { token }),
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

  const customerCount = useMemo(() => new Set(orders.map((order) => order.customer_email)).size, [orders])
  const revenue = useMemo(() => orders.filter((order) => order.status !== 'CANCELLED_BY_STORE' && order.status !== 'CANCELLED_BY_USER').reduce((sum, order) => sum + Number(order.total_price), 0) / 100, [orders])
  const deliveredRevenue = useMemo(() => orders.filter((order) => order.status === 'DELIVERED').reduce((sum, order) => sum + Number(order.total_price), 0) / 100, [orders])
  const codOrders = useMemo(() => orders.filter((order) => order.payment_method === 'CASH_ON_DELIVERY'), [orders])
  const visibleOrders = useMemo(() => {
    const query = search.trim().toLowerCase()
    return orders.filter((order) => {
      const matchesQuery = !query || [order.customer_name, order.customer_email, order.receipt_code].some((value) => value.toLowerCase().includes(query))
      const date = order.created_at.slice(0, 10)
      return matchesQuery && (statusFilter === 'ALL' || order.status === statusFilter) && (!fromDate || date >= fromDate) && (!toDate || date <= toDate)
    })
  }, [orders, search, statusFilter, fromDate, toDate])

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
        const nextInventory = await supabaseRequest<InventoryProduct[]>(`/rest/v1/products?store_id=eq.${encodeURIComponent(store.id)}&select=id,name,product_variants(id,name,stock_quantity)&order=position.asc`, { token })
        setInventory(nextInventory)
      }
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not cancel unpaid order')
    } finally {
      setUpdatingId(null)
    }
  }

  const createTtn = async (id: string) => {
    if (!token) return
    setCreatingTtnId(id)
    setError(null)
    try {
      const result = await supabaseRequest<{ ttn: string }>('/functions/v1/nova-poshta-create-ttn', {
        method: 'POST', token, body: JSON.stringify({ orderId: id }),
      })
      setOrders((current) => current.map((order) => order.id === id ? { ...order, nova_poshta_ttn: result.ttn } : order))
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not create TTN')
    } finally {
      setCreatingTtnId(null)
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
    return <section className="page-status"><h1>CRM needs Supabase</h1><p>Configure `.env.local` and apply the project migration first.</p></section>
  }
  if (member === false) {
    return <section className="page-status"><h1>Manager access required</h1><p>Ask the store owner to add your account to this store.</p></section>
  }
  if (error) return <section className="page-status error">{error}</section>
  if (member === null) return <div className="page-status">Loading CRM…</div>

  return (
    <section>
      <header className="page-head">
        <p className="muted">{store.name} · management</p>
        <h1>{section === 'overview' ? 'CRM' : section === 'orders' ? 'Orders' : section === 'customers' ? 'Customers' : section === 'catalogue' ? 'Catalogue' : 'Settings'}</h1>
        <AdminTabs active={section} onChange={setSection} />
      </header>
      {section === 'customers' ? <CustomersPage /> : section === 'catalogue' ? <CatalogAdminPage embedded /> : section === 'settings' ? <><NovaPostModeToggle /><DeliverySettingsPage embedded /></> : <>
      {section === 'overview' ? <><div className="crm-stats">
        <div><span>Orders</span><strong>{orders.length}</strong></div>
        <div><span>Customers</span><strong>{customerCount}</strong></div>
        <div><span>Revenue</span><strong>{formatPrice(revenue, store.currency)}</strong></div><div><span>Delivered revenue</span><strong>{formatPrice(deliveredRevenue, store.currency)}</strong></div><div><span>Payment on delivery</span><strong>{codOrders.length}</strong></div>
      </div><div className="overview-grid"><section className="crm-panel"><h2>Needs attention</h2><p><strong>{orders.filter((order) => order.status === 'PENDING').length}</strong> pending orders</p><p><strong>{orders.filter((order) => order.payment_status === 'FAILED').length}</strong> failed payments</p><button type="button" className="text-btn" onClick={() => setSection('orders')}>Open orders</button></section><section className="crm-panel"><h2>Inventory alerts</h2>{inventory.flatMap((product) => product.product_variants.map((variant) => ({ product: product.name, ...variant }))).filter((variant) => variant.stock_quantity < 3).slice(0, 5).map((variant) => <p key={variant.id}>{variant.product} · {variant.name}: <strong className="stock-low">{variant.stock_quantity}</strong></p>)}<button type="button" className="text-btn" onClick={() => setSection('catalogue')}>Manage catalogue</button></section></div></> : <>
      <div className="crm-grid">
        <section className="crm-panel">
          <h2>Orders</h2>
          <div className="order-filters"><input placeholder="Search name, email or receipt" value={search} onChange={(event) => setSearch(event.target.value)} /><select value={statusFilter} onChange={(event) => setStatusFilter(event.target.value as 'ALL' | OrderStatus)}><option value="ALL">All statuses</option>{statuses.map((status) => <option key={status} value={status}>{status.replaceAll('_', ' ').toLowerCase()}</option>)}</select><input aria-label="Orders from date" type="date" value={fromDate} onChange={(event) => setFromDate(event.target.value)} /><input aria-label="Orders to date" type="date" value={toDate} onChange={(event) => setToDate(event.target.value)} /></div>
          {orders.length === 0 ? <p className="muted">No orders yet.</p> : visibleOrders.length === 0 ? <p className="muted">No orders match these filters.</p> : <ul className="admin-list">{visibleOrders.map((order) => (
            <li key={order.id}>
              <div><strong>{order.customer_name}</strong><span>{order.customer_email} · {formatDate(order.created_at)} · {order.payment_method === 'CASH_ON_DELIVERY' ? 'payment on delivery' : 'online payment'}{order.nova_poshta_status ? ` · ${order.nova_poshta_status}` : ''}</span></div>
              <strong>{formatPrice(Number(order.total_price) / 100, order.currency)}</strong>
              <label className="sr-only" htmlFor={`status-${order.id}`}>Order status</label>
              <select id={`status-${order.id}`} value={order.status} disabled={updatingId === order.id} onChange={(event) => void changeStatus(order.id, event.target.value as OrderStatus)}>
                {statuses.map((status) => <option key={status} value={status}>{status.replaceAll('_', ' ').toLowerCase()}</option>)}
              </select>
              {order.status === 'PENDING' && order.payment_status !== 'PAID' ? <button type="button" className="text-btn" disabled={updatingId === order.id} onClick={() => void cancelAndRestoreStock(order.id)}>Cancel & restore stock</button> : <span />}
              <button type="button" className="text-btn" disabled={!order.user_id} title={order.user_id ? 'Open customer card' : 'Guest checkout has no customer account'} onClick={() => setSelectedCustomer(order)}>Customer</button>
              {order.nova_poshta_ttn ? <span className="ttn-actions"><a className="text-btn" href={`https://novaposhta.ua/tracking/?cargo_number=${encodeURIComponent(order.nova_poshta_ttn)}`} target="_blank" rel="noreferrer">TTN {order.nova_poshta_ttn}</a><button type="button" className="text-btn" disabled={trackingId === order.id} onClick={() => void refreshTracking(order.id)}>{trackingId === order.id ? 'Updating…' : 'Update status'}</button></span> : <button type="button" className="text-btn" disabled={creatingTtnId === order.id || order.status.startsWith('CANCELLED')} onClick={() => void createTtn(order.id)}>{creatingTtnId === order.id ? 'Creating TTN…' : 'Create TTN'}</button>}
            </li>
          ))}</ul>}
        </section>
        <section className="crm-panel">
          <h2>Stock</h2>
          <ul className="stock-list">{inventory.flatMap((product) => product.product_variants.map((variant) => (
            <li key={variant.id}><span>{product.name} · {variant.name}</span><strong className={variant.stock_quantity < 3 ? 'stock-low' : ''}>{variant.stock_quantity}</strong></li>
          )))}</ul>
          <Link className="text-btn" to="/">Open storefront</Link>
        </section>
      </div>
      </>}
      {selectedCustomer && token && user ? <CustomerPanel order={selectedCustomer} storeId={store.id} token={token} managerId={user.id} onClose={() => setSelectedCustomer(null)} /> : null}
      </>}
    </section>
  )
}
