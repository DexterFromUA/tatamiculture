import { useEffect, useMemo, useState } from 'react'
import { Link } from 'react-router-dom'
import { CustomerPanel, type CustomerOrder } from '../components/CustomerPanel'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { formatDate, formatPrice } from '../lib/format'
import { supabaseConfigured, supabaseRequest } from '../lib/supabase'
import type { OrderStatus } from '../types'

type AdminOrder = CustomerOrder

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
  const [search, setSearch] = useState('')
  const [statusFilter, setStatusFilter] = useState<'ALL' | OrderStatus>('ALL')
  const [fromDate, setFromDate] = useState('')
  const [toDate, setToDate] = useState('')
  const [selectedCustomer, setSelectedCustomer] = useState<AdminOrder | null>(null)

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
          supabaseRequest<AdminOrder[]>(`/rest/v1/orders?store_id=eq.${encodeURIComponent(store.id)}&select=id,user_id,receipt_code,customer_name,customer_email,customer_phone,total_price,currency,status,payment_status,created_at&order=created_at.desc`, { token }),
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
        <h1>CRM</h1>
        <Link to="/admin/catalog">Manage catalogue</Link>
      </header>
      <div className="crm-stats">
        <div><span>Orders</span><strong>{orders.length}</strong></div>
        <div><span>Customers</span><strong>{customerCount}</strong></div>
        <div><span>Revenue</span><strong>{formatPrice(revenue, store.currency)}</strong></div>
      </div>
      <div className="crm-grid">
        <section className="crm-panel">
          <h2>Orders</h2>
          <div className="order-filters"><input placeholder="Search name, email or receipt" value={search} onChange={(event) => setSearch(event.target.value)} /><select value={statusFilter} onChange={(event) => setStatusFilter(event.target.value as 'ALL' | OrderStatus)}><option value="ALL">All statuses</option>{statuses.map((status) => <option key={status} value={status}>{status.replaceAll('_', ' ').toLowerCase()}</option>)}</select><input aria-label="Orders from date" type="date" value={fromDate} onChange={(event) => setFromDate(event.target.value)} /><input aria-label="Orders to date" type="date" value={toDate} onChange={(event) => setToDate(event.target.value)} /></div>
          {orders.length === 0 ? <p className="muted">No orders yet.</p> : visibleOrders.length === 0 ? <p className="muted">No orders match these filters.</p> : <ul className="admin-list">{visibleOrders.map((order) => (
            <li key={order.id}>
              <div><strong>{order.customer_name}</strong><span>{order.customer_email} · {formatDate(order.created_at)}</span></div>
              <strong>{formatPrice(Number(order.total_price) / 100, order.currency)}</strong>
              <label className="sr-only" htmlFor={`status-${order.id}`}>Order status</label>
              <select id={`status-${order.id}`} value={order.status} disabled={updatingId === order.id} onChange={(event) => void changeStatus(order.id, event.target.value as OrderStatus)}>
                {statuses.map((status) => <option key={status} value={status}>{status.replaceAll('_', ' ').toLowerCase()}</option>)}
              </select>
              {order.status === 'PENDING' && order.payment_status !== 'PAID' ? <button type="button" className="text-btn" disabled={updatingId === order.id} onClick={() => void cancelAndRestoreStock(order.id)}>Cancel & restore stock</button> : <span />}
              <button type="button" className="text-btn" disabled={!order.user_id} title={order.user_id ? 'Open customer card' : 'Guest checkout has no customer account'} onClick={() => setSelectedCustomer(order)}>Customer</button>
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
      {selectedCustomer && token && user ? <CustomerPanel order={selectedCustomer} storeId={store.id} token={token} managerId={user.id} onClose={() => setSelectedCustomer(null)} /> : null}
    </section>
  )
}
