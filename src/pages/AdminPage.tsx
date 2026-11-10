import { useEffect, useMemo, useState } from 'react'
import { CustomerPanel, type CustomerPanelTarget } from '../components/CustomerPanel'
import { CreateTtnDrawer } from '../components/CreateTtnDrawer'
import { MergeOrdersDrawer } from '../components/MergeOrdersDrawer'
import { ConfirmationDialog, type ConfirmationDialogContent } from '../components/ConfirmationDialog'
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
import { SupabaseError, supabaseConfigured, supabaseRequest } from '../lib/supabase'
import type { OrderStatus } from '../types'
import { useTranslation } from 'react-i18next'
import { fetchAll, hasStoreMembership } from '../lib/crm'
import { downloadOrdersCsv } from '../lib/crmExport'
import { FinancialAnalytics, OrderOperations, type OrderDetailsOrder } from '../components/OrderOperations'
import { normalizePhone } from '../lib/phone'
import { createTtn, defaultParcelDescription, getTtnPreview, type TtnShipment } from '../lib/ttn'
import { invalidTtnRecipientName, parseTtnRecipientName } from '../../supabase/functions/_shared/ttn-recipient.ts'

type AdminOrder = OrderDetailsOrder & {
  nova_poshta_document_ref: string | null
  nova_poshta_status_code: string | null
  delivery_city_ref: string | null
  delivery_address_ref: string | null
}

type InventoryProduct = {
  id: string
  name: string
  product_variants: Array<{ id: string; name: string; stock_quantity: number; low_stock_threshold?: number; is_preorder: boolean }>
}

const statuses: OrderStatus[] = ['PENDING', 'PAID', 'IN_PROGRESS', 'READY_FOR_PICKUP', 'DELIVERED', 'CANCELLED_BY_USER', 'CANCELLED_BY_STORE']
const canCreateTtn = (order: AdminOrder) =>
  !order.nova_poshta_ttn && !order.nova_poshta_document_ref && !order.status.startsWith('CANCELLED')

export function AdminPage() {
  const { store } = useStore()
  const { token, user } = useAuth()
  const { addToast } = useToast()
  const [orders, setOrders] = useState<AdminOrder[]>([])
  const [mergeMembers, setMergeMembers] = useState<Array<{ order_id: string; root_id: string }>>([])
  const [ordersRevision, setOrdersRevision] = useState(0)
  const [mergeOpen, setMergeOpen] = useState(false)
  const [mergeError, setMergeError] = useState<string | null>(null)
  const [inventory, setInventory] = useState<InventoryProduct[]>([])
  const [member, setMember] = useState<boolean | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [exportingOrders, setExportingOrders] = useState(false)
  const [updatingId, setUpdatingId] = useState<string | null>(null)
  const [confirmation, setConfirmation] = useState<{
    content: ConfirmationDialogContent
    resolve: (confirmed: boolean) => void
  } | null>(null)
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
  const [selectedOrderIds, setSelectedOrderIds] = useState<string[]>([])
  const [bulkAction, setBulkAction] = useState('')
  const [bulkBusy, setBulkBusy] = useState(false)
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
        const [nextOrders, nextInventory, nextMergeMembers] = await Promise.all([
          fetchAll<AdminOrder>(`/rest/v1/orders?store_id=eq.${encodeURIComponent(store.id)}&select=id,user_id,receipt_code,customer_name,customer_email,customer_phone,note,payment_test_mode,total_price,currency,status,payment_status,created_at,nova_poshta_ttn,nova_poshta_document_ref,nova_poshta_status,nova_poshta_status_code,payment_method,delivery_city_ref,delivery_address_ref&order=created_at.desc,id.desc`, token),
          supabaseRequest<InventoryProduct[]>(`/rest/v1/products?store_id=eq.${encodeURIComponent(store.id)}&select=id,name,product_variants(*)&order=position.asc`, { token }),
          fetchAll<{ order_id: string; root_id: string }>(`/rest/v1/order_merge_members?select=order_id,root_id,orders!order_merge_members_order_id_fkey!inner(store_id)&orders.store_id=eq.${encodeURIComponent(store.id)}&order=order_id`, token),
        ])
        if (!cancelled) {
          setMember(true)
          setOrders(nextOrders)
          setMergeMembers(nextMergeMembers)
          setInventory(nextInventory)
        }
      } catch (cause) {
        if (!cancelled) setError(cause instanceof Error ? cause.message : 'Could not load CRM')
      }
    }
    void load()
    return () => { cancelled = true }
  }, [store, token, user, ordersRevision])

  const liveOrders = useMemo(() => orders.filter(order => !order.payment_test_mode), [orders])
  const groupIds = (id: string) => {
    const ids = mergeMembers.filter(member => member.root_id === id).map(member => member.order_id)
    return ids.length ? ids : [id]
  }
  const groupedOrders = useMemo(() => orders.filter(order => !mergeMembers.some(member => member.order_id === order.id && member.root_id !== order.id)).map(order => {
    const ids = mergeMembers.filter(member => member.root_id === order.id).map(member => member.order_id)
    const members = ids.length ? orders.filter(item => ids.includes(item.id)) : [order]
    return { ...order, total_price: members.reduce((sum, item) => sum + Number(item.total_price), 0) }
  }), [orders, mergeMembers])
  const customerCount = useMemo(() => new Set(liveOrders.map((order) => order.customer_email)).size, [liveOrders])
  const revenue = useMemo(() => liveOrders.filter((order) => order.status !== 'CANCELLED_BY_STORE' && order.status !== 'CANCELLED_BY_USER').reduce((sum, order) => sum + Number(order.total_price), 0) / 100, [liveOrders])
  const deliveredRevenue = useMemo(() => liveOrders.filter((order) => order.status === 'DELIVERED').reduce((sum, order) => sum + Number(order.total_price), 0) / 100, [liveOrders])
  const codOrders = useMemo(() => liveOrders.filter((order) => order.payment_method === 'CASH_ON_DELIVERY'), [liveOrders])
  const visibleOrders = useMemo(() => {
    const query = search.trim().toLowerCase()
    const numberQuery = query.replace(/^#/, '')
    const phoneQuery = /^[+\d\s().-]+$/.test(query) ? query.replace(/\D/g, '') : ''
    return groupedOrders.filter((order) => {
      const phone = (order.customer_phone ?? '').replace(/\D/g, '')
      const matchesPhone = phoneQuery && (phone.includes(phoneQuery) ||
        (phoneQuery.length >= 9 && phoneQuery.length <= 12 && phone.length >= 9 && phone.endsWith(phoneQuery.slice(-9))))
      const matchesQuery = !query || Boolean(matchesPhone) ||
        Boolean(order.customer_name?.toLowerCase().includes(query)) ||
        Boolean(numberQuery && orders.filter(item => item.id === order.id || mergeMembers.some(member => member.order_id === item.id && member.root_id === order.id)).some(item => [item.receipt_code, item.nova_poshta_ttn].some(value => value?.toLowerCase().includes(numberQuery))))
      const date = order.created_at.slice(0, 10)
      return matchesQuery && (statusFilter === 'ALL' || order.status === statusFilter) && (!fromDate || date >= fromDate) && (!toDate || date <= toDate)
    })
  }, [groupedOrders, orders, mergeMembers, search, statusFilter, fromDate, toDate])
  const pages = Math.max(1, Math.ceil(visibleOrders.length / 20))
  const currentPage = Math.min(page, pages)
  const pageOrders = visibleOrders.slice((currentPage - 1) * 20, currentPage * 20)
  const pageOrderIds = new Set(pageOrders.map(order => order.id))
  const pageSelected = pageOrders.length > 0 && pageOrders.every(order => selectedOrderIds.includes(order.id))
  const selectedOutsidePage = selectedOrderIds.filter(id => !pageOrderIds.has(id)).length
  const selectedOrders = groupedOrders.filter(order => selectedOrderIds.includes(order.id))
  const ordersToExport = selectedOrders.length > 0 ? selectedOrders : visibleOrders
  const selectedTtnCandidates = selectedOrders.filter(canCreateTtn)
  const selectedOrder = groupedOrders.find(order => order.id === selectedOrderId)
  const exportOrders = async () => {
    if (!token || !ordersToExport.length || exportingOrders) return
    setExportingOrders(true)
    setError(null)
    try {
      const refs = ordersToExport.flatMap(order => {
        const ids = [order.id, ...groupIds(order.id).filter(id => id !== order.id)]
        const primaryReceipt = ids.length > 1 ? order.receipt_code : undefined
        return ids.map(id => ({ id, primaryReceipt }))
      })
      await downloadOrdersCsv(refs, token, t)
    } catch (cause) {
      setError(`${t('Could not export orders')}. ${cause instanceof Error ? cause.message : ''}`.trim())
    } finally {
      setExportingOrders(false)
    }
  }

  const copyReceiptLink = async (path: string) => {
    try {
      await navigator.clipboard.writeText(new URL(path, window.location.origin).href)
      addToast(t('Receipt link copied'))
    } catch {
      addToast(t('Could not copy the link. Open the receipt using its number.'))
    }
  }

  const confirmAction = (content: ConfirmationDialogContent) =>
    new Promise<boolean>(resolve => setConfirmation({ content, resolve }))

  const updateOrderStatus = async (ids: string[], status: OrderStatus, restoreStock = false) => {
    if (!token) return false
    const request = (confirmed: boolean) => supabaseRequest<Array<Pick<AdminOrder, 'id' | 'status' | 'payment_status'>>>(
      '/rest/v1/rpc/update_admin_orders', {
        method: 'POST', token, body: JSON.stringify({
          p_order_ids: ids, p_status: status, p_confirm_paid: confirmed, p_restore_stock: restoreStock,
        }),
      },
    )
    const updated = await request(false).catch(async cause => {
      if (!(cause instanceof SupabaseError) || cause.code !== 'PT409') throw cause
      const message = restoreStock
        ? t('There is a payment record for at least one of these orders. Cancel and restore stock anyway?')
        : t('There is a payment record for at least one of these orders. Change the status to {{status}} anyway?', { status: t(status) })
      const confirmed = await confirmAction({ title: t('Payment recorded'), message })
      return confirmed ? request(true) : null
    })
    if (!updated) return false
    const byId = new Map(updated.map(order => [order.id, order]))
    setOrders(current => current.map(order => {
      const update = byId.get(order.id)
      return update ? { ...order, ...update } : order
    }))
    if (restoreStock && store) {
      try {
        const nextInventory = await supabaseRequest<InventoryProduct[]>(`/rest/v1/products?store_id=eq.${encodeURIComponent(store.id)}&select=id,name,product_variants(*)&order=position.asc`, { token })
        setInventory(nextInventory)
      } catch (cause) {
        addToast(cause instanceof Error ? cause.message : t('Could not refresh stock'))
      }
    }
    return true
  }

  const changeStatus = async (id: string, status: OrderStatus, restoreStock = false) => {
    if (!token || updatingId || bulkBusy) return
    setUpdatingId(id)
    setError(null)
    try {
      await updateOrderStatus([id], status, restoreStock)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('Action failed'))
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

  const saveShipment = (id: string, { ttn, documentRef, existing }: TtnShipment) => {
    const ids = groupIds(id)
    if (!existing) setSelectedOrderIds(current => current.filter(selectedId => selectedId !== id))
    setOrders(current => current.map(order => ids.includes(order.id)
      ? { ...order, nova_poshta_ttn: ttn, nova_poshta_document_ref: documentRef }
      : order))
  }

  const createBulkTtns = async () => {
    if (!token) return
    setBulkBusy(true)
    setError(null)
    let skipped = selectedOrders.length - selectedTtnCandidates.length
    let refreshOrders = false
    const ready: Array<{ order: AdminOrder; weightGrams: number; declaredValueMinor: number }> = []
    const issues: string[] = []
    const skippedMessage = () => t('TTN skipped for {{count}} orders that already have a TTN or are cancelled', { count: skipped })
    const issue = (order: AdminOrder, cause: unknown) =>
      `#${order.receipt_code}: ${t(cause instanceof Error ? cause.message : 'Could not create TTN')}`
    try {
      for (let index = 0; index < selectedTtnCandidates.length; index += 6) {
        const candidates = selectedTtnCandidates.slice(index, index + 6)
        const previews = await Promise.allSettled(candidates.map(order => getTtnPreview(order.id, token)))
        previews.forEach((preview, position) => {
          const order = candidates[position]
          if (preview.status === 'rejected') {
            if (preview.reason instanceof SupabaseError && preview.reason.message === 'This order already has a TTN.') {
              skipped++
              refreshOrders = true
            } else {
              issues.push(issue(order, preview.reason))
            }
            return
          }
          const { weightGrams, declaredValueMinor } = preview.value
          const missing = [
            (weightGrams === null || !Number.isSafeInteger(weightGrams) || weightGrams <= 0) && t('Weight, g'),
            (!Number.isSafeInteger(declaredValueMinor) || declaredValueMinor < 100) && t('Declared value, UAH'),
            (!order.delivery_city_ref || !order.delivery_address_ref) && t('Nova Poshta city or branch'),
            !normalizePhone(order.customer_phone ?? '') && t('Recipient phone'),
          ].filter(Boolean)
          const problems = [
            missing.length ? t('Missing or invalid shipping data: {{fields}}', { fields: missing.join(', ') }) : '',
            !parseTtnRecipientName(order.customer_name) ? t(invalidTtnRecipientName) : '',
          ].filter(Boolean)
          if (problems.length || weightGrams === null) {
            issues.push(`#${order.receipt_code}: ${problems.join(' ')}`)
            return
          }
          ready.push({ order, weightGrams, declaredValueMinor })
        })
      }
      if (!ready.length && !issues.length) {
        if (skipped) addToast(skippedMessage())
        return
      }

      const summary = ready.length
        ? t('TTNs will be created automatically using the calculated weights and declared values. Orders to process: {{count}}.', { count: ready.length })
        : t('No orders are ready for TTN creation. Review the details below and try again.')
      const message = [
        summary,
        skipped ? skippedMessage() : '',
        ready.length && issues.length ? t('The orders listed below will be skipped.') : '',
      ].filter(Boolean).join(' ')
      const confirmed = await confirmAction({
        title: t(issues.length ? 'Orders need attention before creating TTNs' : 'Create TTNs automatically'),
        message,
        details: issues,
        confirmLabel: t(issues.length ? 'Skip and create TTNs' : 'Create TTNs'),
        confirmDisabled: !ready.length,
      })
      if (!confirmed) return

      let created = 0
      const failures: string[] = []
      for (const { order, weightGrams, declaredValueMinor } of ready) {
        try {
          const shipment = await createTtn(token, {
            orderId: order.id,
            description: defaultParcelDescription,
            internalOrderNumber: order.receipt_code,
            weightGrams,
            declaredValueMinor,
          })
          saveShipment(order.id, shipment)
          if (shipment.existing) skipped++
          else created++
        } catch (cause) {
          failures.push(issue(order, cause))
        }
      }
      if (created) addToast(t('TTNs created: {{count}}', { count: created }))
      if (skipped) addToast(skippedMessage())
      if (failures.length) setError(failures.join(' · '))
      setBulkAction('')
    } finally {
      if (refreshOrders) setOrdersRevision(value => value + 1)
      setBulkBusy(false)
    }
  }

  const applyBulkAction = async () => {
    if (!token || !bulkAction || bulkBusy || updatingId || selectedOrders.length === 0) return
    if (bulkAction === 'merge') {
      setMergeError(null)
      setMergeOpen(true)
      setBulkAction('')
      return
    }
    if (bulkAction === 'ttn') {
      if (selectedOrders.length > 1) {
        await createBulkTtns()
      } else if (selectedTtnCandidates.length) {
        setTtnOrder(selectedTtnCandidates[0])
        setBulkAction('')
      }
      return
    }
    setBulkBusy(true)
    setError(null)
    if (bulkAction.startsWith('status:') || bulkAction === 'cancel') {
      const restoreStock = bulkAction === 'cancel'
      const status = restoreStock ? 'CANCELLED_BY_STORE' : bulkAction.slice('status:'.length) as OrderStatus
      const eligible = selectedOrders.filter(order => restoreStock
        ? order.status === 'PENDING' && order.payment_status !== 'PAID'
        : !order.payment_test_mode)
      const skipped = selectedOrders.filter(order => !eligible.includes(order))
      try {
        if (eligible.length && !await updateOrderStatus(eligible.map(order => order.id), status, restoreStock)) return
        setSelectedOrderIds(skipped.map(order => order.id))
        setBulkAction('')
        if (skipped.length) {
          const message = t(restoreStock
            ? 'Only pending unpaid orders can be cancelled with stock restoration'
            : 'Test order status cannot be changed')
          setError(skipped.map(order => `#${order.receipt_code}: ${message}`).join(' · '))
        }
        if (eligible.length) addToast(t('Orders updated: {{count}}', { count: eligible.length }))
      } catch (cause) {
        setError(cause instanceof Error ? cause.message : t('Action failed'))
      } finally {
        setBulkBusy(false)
      }
      return
    }
    const updateOrder = async (order: AdminOrder) => {
      if (!order.nova_poshta_ttn) throw new Error(t('This order has no TTN'))
      const result = await supabaseRequest<{ status: string }>('/functions/v1/nova-poshta-track-ttn', {
        method: 'POST', token, body: JSON.stringify({ orderId: order.id }),
      })
      return { id: order.id, changes: { nova_poshta_status: result.status } }
    }
    const results: PromiseSettledResult<Awaited<ReturnType<typeof updateOrder>>>[] = []
    for (let index = 0; index < selectedOrders.length; index += 10) {
      results.push(...await Promise.allSettled(selectedOrders.slice(index, index + 10).map(updateOrder)))
    }
    const updated = new Map(results.flatMap(result => result.status === 'fulfilled' ? [[result.value.id, result.value.changes] as const] : []))
    const failed = results.flatMap((result, index) => result.status === 'rejected'
      ? [{ order: selectedOrders[index], message: result.reason instanceof Error ? result.reason.message : t('Action failed') }]
      : [])
    setOrders(current => current.map(order => {
      const root = [...updated.keys()].find(id => groupIds(id).includes(order.id))
      return root ? { ...order, ...updated.get(root) } : order
    }))
    setSelectedOrderIds(failed.map(item => item.order.id))
    setBulkAction('')
    if (failed.length) {
      setError(failed.map(item => `#${item.order.receipt_code}: ${item.message}`).join(' · '))
    }
    if (updated.size) addToast(t('Orders updated: {{count}}', { count: updated.size }))
    setBulkBusy(false)
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
      {section !== 'catalogue' && <div className="crm-section-head"><div><span className="crm-section-head__label"><span>{store.name}</span> / CRM</span><h2>{section === 'overview' ? t('Overview') : section === 'orders' ? t('Orders') : section === 'customers' ? t('Customers') : t('Settings')}</h2></div></div>}
      {section === 'customers' ? <CustomersPage revision={customerRevision} onOpenCustomer={id => setSelectedCustomer({ kind: 'customer', id })} /> : section === 'catalogue' ? <CatalogAdminPage key={catalogView} embedded initialView={catalogView} /> : section === 'settings' ? <SettingsWorkspace /> : <>
      {section === 'overview' ? <><div className="crm-stats crm-stats--overview">
        <div><span>{t('Orders')}</span><strong>{liveOrders.length}</strong></div>
        <div><span>{t('Customers')}</span><strong>{customerCount}</strong></div>
        <div><span>{t('Revenue')}</span><strong className="crm-stats__money">{formatPrice(revenue, store.currency)}</strong></div><div><span>{t('Delivered revenue')}</span><strong className="crm-stats__money">{formatPrice(deliveredRevenue, store.currency)}</strong></div><div><span>{t('Payment on delivery')}</span><strong>{codOrders.length}</strong></div>
      </div><div className="overview-grid"><section className="crm-panel crm-attention"><div className="crm-panel__heading"><div><p className="eyebrow">01 / {t('Overview')}</p><h2>{t('Needs attention')}</h2></div><span className="crm-panel__symbol" aria-hidden="true">↗</span></div><div className="crm-attention__row"><span>{t('pending orders')}</span><strong>{liveOrders.filter((order) => order.status === 'PENDING').length}</strong></div><div className="crm-attention__row"><span>{t('failed payments')}</span><strong>{liveOrders.filter((order) => order.payment_status === 'FAILED').length}</strong></div><button type="button" className="crm-inline-link" onClick={() => setSection('orders')}>{t('Open orders')} ↗</button></section><section className="crm-panel crm-inventory"><div className="crm-panel__heading"><div><p className="eyebrow">02 / {t('Catalogue')}</p><h2>{t('Inventory alerts')}</h2></div><span className="crm-panel__symbol" aria-hidden="true">↗</span></div>{inventory.flatMap((product) => product.product_variants.map((variant) => ({ product: product.name, ...variant }))).filter((variant) => !variant.is_preorder && variant.stock_quantity < (variant.low_stock_threshold ?? 3)).slice(0, 5).map((variant) => <div className="crm-attention__row" key={variant.id}><span>{variant.product} · {variant.name}</span><strong className="stock-low">{variant.stock_quantity}</strong></div>)}{!inventory.some(product => product.product_variants.some(variant => !variant.is_preorder && variant.stock_quantity < (variant.low_stock_threshold ?? 3))) ? <p className="muted">{t('No low stock alerts.')}</p> : null}<button type="button" className="crm-inline-link" onClick={() => { setCatalogView('stock'); setSection('catalogue') }}>{t('Manage catalogue')} ↗</button></section></div></> : <>
      <div className="crm-grid crm-grid--orders">
        <section className="crm-panel">
          <div className="order-filters"><label className="search-field"><span className="sr-only">{t('Search orders by name, order number, TTN or phone')}</span><input type="search" placeholder={t('Search orders by name, order number, TTN or phone')} value={search} onChange={(event) => setSearch(event.target.value)} /></label><select value={statusFilter} onChange={(event) => setStatusFilter(event.target.value as 'ALL' | OrderStatus)}><option value="ALL">{t('All statuses')}</option>{statuses.map((status) => <option key={status} value={status}>{t(status)}</option>)}</select><input aria-label={t('Orders from date')} type="date" value={fromDate} onChange={(event) => setFromDate(event.target.value)} /><input aria-label={t('Orders to date')} type="date" value={toDate} onChange={(event) => setToDate(event.target.value)} /></div>
          <div className="orders-list-toolbar">
            <button className="text-btn" title={t(selectedOrders.length ? 'Export selected orders' : 'Export CSV')} disabled={!ordersToExport.length || exportingOrders} onClick={() => void exportOrders()}>
              {exportingOrders ? t('Preparing CSV…') : `${t('Export CSV')} (${ordersToExport.length})`}
            </button>
            <div className="crm-pagination"><button className="text-btn" disabled={currentPage === 1} onClick={() => setPage(currentPage - 1)}>{t('Previous')}</button><span>{currentPage} / {pages}</span><button className="text-btn" disabled={currentPage === pages} onClick={() => setPage(currentPage + 1)}>{t('Next')}</button></div>
          </div>
          {(pageOrders.length > 0 || selectedOrderIds.length > 0) && <div className="order-bulk" role="group" aria-label={t('Bulk action')}>
            <label className="order-select-all">
              <input type="checkbox" checked={pageSelected} disabled={bulkBusy || !pageOrders.length}
                ref={input => { if (input) input.indeterminate = !pageSelected && selectedOrderIds.length > selectedOutsidePage }}
                onChange={event => {
                  const checked = event.target.checked
                  setSelectedOrderIds(current => checked ? [...new Set([...current, ...pageOrderIds])] : current.filter(id => !pageOrderIds.has(id)))
                  setBulkAction('')
                }} />
              {t('Select all on this page')}
            </label>
            <div className="order-bulk__actions" aria-hidden={!selectedOrderIds.length} inert={!selectedOrderIds.length}>
              <div className="catalog-bulk__selection" aria-live="polite">
                <span className="catalog-bulk__count">{selectedOrderIds.length}</span>
                <div className="catalog-bulk__selection-label">
                  <span>{t('Selected orders')}</span>
                  {selectedOutsidePage > 0 && <small>{t('Outside this page: {{count}}', { count: selectedOutsidePage })}</small>}
                </div>
              </div>
              <div className="catalog-bulk__controls">
                <select aria-label={t('Bulk action')} disabled={bulkBusy} value={bulkAction} onChange={event => setBulkAction(event.target.value)}>
                  <option value="">{t('Bulk action')}</option>
                  <optgroup label={t('Order status')}>
                    {statuses.map(status => <option key={status} value={`status:${status}`}>{t(status)}</option>)}
                  </optgroup>
                  <option value="tracking">{t('Update shipment statuses')}</option>
                  <option value="cancel">{t('Cancel unpaid & restore stock')}</option>
                  {selectedTtnCandidates.length > 0 && <option value="ttn">{t('Create TTN')}</option>}
                  {selectedOrders.length > 1 && <option value="merge">{t('Merge orders')}</option>}
                </select>
                <button type="button" className="btn" disabled={bulkBusy || Boolean(updatingId) || Boolean(trackingId) || !bulkAction} onClick={() => void applyBulkAction()}>{t(bulkBusy ? 'Updating…' : 'Apply')}</button>
                <button type="button" className="catalog-bulk__clear" disabled={bulkBusy} onClick={() => { setSelectedOrderIds([]); setBulkAction('') }}>{t('Clear selection')}</button>
              </div>
            </div>
          </div>}
          {orders.length === 0 ? <p className="muted">{t('No orders yet.')}</p> : visibleOrders.length === 0 ? <p className="muted">{t('No orders match these filters.')}</p> : <ul className="admin-list">{pageOrders.map((order) => {
            const receiptPath = `/receipt/${encodeURIComponent(order.receipt_code)}`
            const note = order.note?.trim()
            return (
              <li key={order.id} className={`crm-order${selectedOrderIds.includes(order.id) ? ' crm-order--selected' : ''}`} onClick={event => {
                if (event.target instanceof Element && event.target.closest('a, button, input, select, textarea, label')) return
                setSelectedOrderId(order.id)
              }}>
                <label className="order-select">
                  <input type="checkbox" checked={selectedOrderIds.includes(order.id)} disabled={bulkBusy}
                    onChange={event => {
                      const checked = event.target.checked
                      setSelectedOrderIds(current => checked ? [...current, order.id] : current.filter(id => id !== order.id))
                      setBulkAction('')
                    }} />
                  <span className="sr-only">{t('Select order')} #{order.receipt_code}</span>
                </label>
                <div className="crm-order__identity">
                  <span className="crm-order__reference"><button type="button" className="text-btn" aria-haspopup="dialog" onClick={() => setSelectedOrderId(order.id)}>#{order.receipt_code}</button> · {formatDate(order.created_at)}{order.payment_test_mode && ` · ${t('Test order')}`}{groupIds(order.id).length > 1 && ` · ${t('Merged orders: {{count}}', { count: groupIds(order.id).length })}`}</span>
                  {note && <p className="crm-order__note"><strong>{t('Note')}</strong> {note}</p>}
                  {order.customer_email && <span className="crm-order__email">{order.customer_email}</span>}
                </div>
                <div className="crm-order__amount"><strong>{formatPrice(Number(order.total_price) / 100, order.currency)}</strong><span>{order.payment_method === 'CASH_ON_DELIVERY' ? t('Payment on delivery') : t('Online payment')}</span></div>
                <div className="crm-order__status"><span>{t('Order status')}</span>
                <label className="sr-only" htmlFor={`status-${order.id}`}>{t('Order status')}</label>
                <select id={`status-${order.id}`} value={order.status} disabled={bulkBusy || order.payment_test_mode || Boolean(updatingId)} onChange={(event) => void changeStatus(order.id, event.target.value as OrderStatus)}>
                  {statuses.map((status) => <option key={status} value={status}>{t(status)}</option>)}
                </select></div>
                {order.nova_poshta_status ? <p className="crm-order__delivery">{order.nova_poshta_status}</p> : null}
                <div className="crm-order__actions"><button type="button" className="text-btn" onClick={() => void copyReceiptLink(receiptPath)}>{t('Copy receipt link')}</button>
                {!order.payment_test_mode && <button type="button" className="text-btn" aria-haspopup="dialog" title={t('Open customer card')} onClick={() => setSelectedCustomer({ kind: 'order', id: order.id })}>{t('Customer')}</button>}
                {order.nova_poshta_ttn ? (
                  <span className="ttn-actions">
                    <NovaPoshtaTrackingLink className="text-btn" ttn={order.nova_poshta_ttn}>TTN {order.nova_poshta_ttn}</NovaPoshtaTrackingLink>
                    <button type="button" className="text-btn" disabled={bulkBusy || trackingId === order.id} onClick={() => void refreshTracking(order.id)}>{trackingId === order.id ? t('Updating…') : t('Update status')}</button>
                  </span>
                ) : (
                  <button type="button" className="text-btn" aria-haspopup="dialog" disabled={bulkBusy || !canCreateTtn(order)} onClick={() => setTtnOrder(order)}>{t('Create TTN')}</button>
                )}
                {order.status === 'PENDING' && order.payment_status !== 'PAID' ? <button type="button" className="text-btn crm-order__cancel" disabled={bulkBusy || Boolean(updatingId)} onClick={() => void changeStatus(order.id, 'CANCELLED_BY_STORE', true)}>{t(order.payment_test_mode ? 'Cancel test order' : 'Cancel & restore stock')}</button> : null}</div>
              </li>
            )
          })}</ul>}
          {pageOrders.length > 0 && <div className="crm-pagination">
            <button className="text-btn" disabled={currentPage === 1} onClick={() => setPage(currentPage - 1)}>{t('Previous')}</button>
            <span>{currentPage} / {pages}</span>
            <button className="text-btn" disabled={currentPage === pages} onClick={() => setPage(currentPage + 1)}>{t('Next')}</button>
          </div>}
        </section>
      </div>
      </>}
      </>}
      {selectedCustomer && token && <CustomerPanel key={`${selectedCustomer.kind}:${selectedCustomer.id}`}
        target={selectedCustomer} storeId={store.id} token={token}
        onSaved={() => setCustomerRevision(value => value + 1)} onClose={() => setSelectedCustomer(null)} />}
      {section === 'overview' && token && <FinancialAnalytics orders={liveOrders} storeId={store.id} token={token} />}
      {confirmation && <ConfirmationDialog {...confirmation.content} onClose={confirmed => {
        setConfirmation(null)
        confirmation.resolve(confirmed)
      }} />}
      {selectedOrder && token && <OrderOperations key={selectedOrder.id} order={selectedOrder} orderIds={groupIds(selectedOrder.id)} token={token} onClose={() => setSelectedOrderId(null)} />}
      {mergeOpen && token && <MergeOrdersDrawer orders={selectedOrders} busy={bulkBusy} error={mergeError} onClose={() => setMergeOpen(false)} onMerge={targetId => {
        setBulkBusy(true)
        setMergeError(null)
        void supabaseRequest('/rest/v1/rpc/merge_orders', { method: 'POST', token, body: JSON.stringify({ p_order_ids: selectedOrders.map(order => order.id), p_target_id: targetId }) })
          .then(() => { setMergeOpen(false); setSelectedOrderIds([]); setOrdersRevision(value => value + 1); addToast(t('Orders merged')) })
          .catch(cause => setMergeError(cause instanceof Error ? cause.message : t('Action failed')))
          .finally(() => setBulkBusy(false))
      }} />}
      {ttnOrder && token && <CreateTtnDrawer key={ttnOrder.id} orderId={ttnOrder.id} receiptCode={ttnOrder.receipt_code} customerName={ttnOrder.customer_name}
        token={token} onClose={() => setTtnOrder(null)} onCreated={shipment => saveShipment(ttnOrder.id, shipment)} />}
    </section>
  )
}
