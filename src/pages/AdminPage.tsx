import { PaymentReviewList } from '../components/PaymentReviewList'
import { CenteredDialog } from '../components/CenteredDialog'
import { useEffect, useState } from 'react'
import { useLocation } from 'react-router-dom'
import { CustomerPanel, type CustomerPanelTarget } from '../components/CustomerPanel'
import { CustomerNotificationDrawer } from '../components/CustomerNotificationDrawer'
import { CreateTtnDrawer } from '../components/CreateTtnDrawer'
import { CreateOrderDrawer } from '../components/CreateOrderDrawer'
import { CrmPagination } from '../components/CrmPagination'
import { ImportOrdersDialog } from '../components/ImportOrdersDialog'
import { LoadingIndicator } from '../components/LoadingIndicator'
import { MergeOrdersDrawer } from '../components/MergeOrdersDrawer'
import { ConfirmationDialog, type ConfirmationDialogContent } from '../components/ConfirmationDialog'
import { NovaPoshtaTrackingLink } from '../components/NovaPoshtaTrackingLink'
import { OrderActionButton } from '../components/OrderActionButton'
import { CancelledOrderRefunds } from '../components/CancelledOrderRefunds'
import { AdminDashboard } from '../components/AdminDashboard'
import type { DashboardOrder, DashboardInventory } from '../lib/dashboard'
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
import { crmPageSize, fetchAll, fetchCrmExportRows, getStoreStaffRole, type StoreStaffRole } from '../lib/crm'
import { useCrmPage } from '../hooks/useCrmPage'
import { downloadOrdersCsv } from '../lib/crmExport'
import { OrderOperations, type OrderDetailsOrder } from '../components/OrderOperations'
import { normalizePhone } from '../lib/phone'
import { createTtn, defaultParcelDescription, getTtnPreview, type TtnShipment } from '../lib/ttn'
import { invalidTtnRecipientName, parseTtnRecipientName } from '../../supabase/functions/_shared/ttn-recipient.ts'

type AdminOrder = OrderDetailsOrder & DashboardOrder & {
  nova_poshta_document_ref: string | null
  nova_poshta_status_code: string | null
  delivery_city_ref: string | null
  delivery_address_ref: string | null
}
type OrderListRow = AdminOrder & { member_ids: string[] }

type OrderFilter = 'ALL' | 'NEW' | 'NO_TTN' | OrderStatus

type InventoryProduct = DashboardInventory

const statuses: OrderStatus[] = ['IN_PROGRESS', 'WAITING_FOR_STOCK', 'PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED', 'COMPLETED', 'CANCELLED_BY_STORE']
const shipmentStages: OrderStatus[] = ['PREPARING_SHIPMENT', 'IN_TRANSIT', 'DELIVERED']
const canCreateTtn = (order: AdminOrder) =>
  !order.nova_poshta_ttn && !order.nova_poshta_document_ref &&
  shipmentStages.includes(order.status)
const canCancelWithStock = (order: AdminOrder) => !order.nova_poshta_ttn && !order.nova_poshta_document_ref &&
  order.payment_status !== 'PAID' && order.payment_status !== 'REFUNDED' &&
  ['PENDING', 'IN_PROGRESS', 'WAITING_FOR_STOCK', 'PREPARING_SHIPMENT'].includes(order.status)

export function AdminPage() {
  const { hash, key: locationKey } = useLocation()
  const { store, refreshProducts } = useStore()
  const { token, user } = useAuth()
  const { addToast } = useToast()
  const storeId = store?.id
  const userId = user?.id
  const [dashboardOrders, setDashboardOrders] = useState<DashboardOrder[]>([])
  const [mergeMembers, setMergeMembers] = useState<Array<{ order_id: string; root_id: string }>>([])
  const [ordersRevision, setOrdersRevision] = useState(0)
  const [createOrderOpen, setCreateOrderOpen] = useState(false)
  const [importOrdersOpen, setImportOrdersOpen] = useState(false)
  const [mergeOpen, setMergeOpen] = useState(false)
  const [mergeError, setMergeError] = useState<string | null>(null)
  const [inventory, setInventory] = useState<InventoryProduct[]>([])
  const [member, setMember] = useState<StoreStaffRole | false | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [exportingOrders, setExportingOrders] = useState(false)
  const [updatingId, setUpdatingId] = useState<string | null>(null)
  const [orderChoice, setOrderChoice] = useState<{
    question: string; options: [string, string][]; resolve: (choice: string) => void
  } | null>(null)
  const choose = (question: string, options: [string, string][]) =>
    new Promise<string>(resolve => setOrderChoice({ question, options, resolve }))
  const [confirmation, setConfirmation] = useState<{
    content: ConfirmationDialogContent
    resolve: (confirmed: boolean) => void
  } | null>(null)
  const [ttnOrder, setTtnOrder] = useState<AdminOrder | null>(null)
  const [trackingId, setTrackingId] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [orderFilter, setOrderFilter] = useState<OrderFilter>('ALL')
  const [fromDate, setFromDate] = useState('')
  const [toDate, setToDate] = useState('')
  const [selectedCustomer, setSelectedCustomer] = useState<CustomerPanelTarget | null>(null)
  const [broadcastOpen, setBroadcastOpen] = useState(false)
  const [customerRevision, setCustomerRevision] = useState(0)
  const [section, setSection] = useState<AdminSection>('overview')
  const [dashboardOrderIds, setDashboardOrderIds] = useState<string[] | null>(null)
  const [customerOrderFilter, setCustomerOrderFilter] = useState<{ id: string; name: string } | null>(null)
  const [catalogSearch, setCatalogSearch] = useState('')
  const [catalogFilter, setCatalogFilter] = useState<'all' | 'stock'>('all')
  const [page, setPage] = useState(1)
  const [selectedOrderId, setSelectedOrderId] = useState<string | null>(null)
  const [orderSelection, setOrderSelection] = useState<OrderListRow[]>([])
  const [bulkAction, setBulkAction] = useState('')
  const [bulkBusy, setBulkBusy] = useState(false)
  const { t } = useTranslation()

  useEffect(() => {
    const orderId = /^#order-([a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12})$/i.exec(hash)?.[1]
    if (!orderId) return
    setSection('orders')
    setSelectedOrderId(orderId)
  }, [hash, locationKey])

  useEffect(() => {
    if (!storeId || !token || !userId || !supabaseConfigured) return
    const abort = new AbortController()
    void getStoreStaffRole(storeId, userId, token, abort.signal).then(role => {
      if (!abort.signal.aborted) setMember(role ?? false)
    }).catch(cause => {
      if (!abort.signal.aborted) setError(cause instanceof Error ? cause.message : 'Could not load CRM')
    })
    return () => abort.abort()
  }, [storeId, token, userId])

  useEffect(() => {
    if (!storeId || !token || !member || section !== 'overview') return
    const abort = new AbortController()
    const fields = 'id,user_id,crm_customer_id,customer_discount_amount,receipt_code,customer_name,customer_email,customer_phone,total_price,currency,status,payment_status,created_at,nova_poshta_ttn,nova_poshta_document_ref,payment_method'
    void Promise.all([
      fetchAll<DashboardOrder>(`/rest/v1/orders?store_id=eq.${storeId}&select=${fields}&order=created_at.desc,id.desc`, token, abort.signal),
      fetchAll<InventoryProduct>(`/rest/v1/products?store_id=eq.${storeId}&select=id,name,is_active,created_at,product_variants(*)&order=position.asc,id.asc`, token, abort.signal),
      fetchAll<{ order_id: string; root_id: string }>(`/rest/v1/order_merge_members?select=order_id,root_id,orders!order_merge_members_order_id_fkey!inner(store_id)&orders.store_id=eq.${storeId}&order=order_id`, token, abort.signal),
    ]).then(([orders, stock, members]) => {
      if (abort.signal.aborted) return
      setDashboardOrders(orders); setInventory(stock); setMergeMembers(members)
    }).catch(cause => {
      if (!abort.signal.aborted) setError(cause instanceof Error ? cause.message : 'Could not load CRM')
    })
    return () => abort.abort()
  }, [storeId, token, member, section, ordersRevision])

  useEffect(() => {
    if (!store || !token || !user || !supabaseConfigured) return
    const abort = new AbortController()
    const checkAccess = () => {
      void getStoreStaffRole(store.id, user.id, token, abort.signal)
        .then(role => { if (!abort.signal.aborted) setMember(role ?? false) })
        .catch(() => {})
    }
    window.addEventListener('focus', checkAccess)
    const timer = window.setInterval(checkAccess, 30000)
    return () => { abort.abort(); window.removeEventListener('focus', checkAccess); window.clearInterval(timer) }
  }, [store, token, user])

  const orderFilters = {
    p_store_id: storeId, p_search: search.trim(), p_status: orderFilter,
    p_from: fromDate || null, p_to: toDate || null,
    p_order_ids: dashboardOrderIds, p_customer_id: customerOrderFilter?.id ?? null,
  }
  const ordersList = useCrmPage<OrderListRow>('crm_orders_page', orderFilters, page,
    member && section === 'orders' ? token : null, ordersRevision)
  const pageOrders = ordersList.data?.rows ?? []
  const matchingOrderCount = ordersList.data?.total ?? 0
  const pages = Math.max(1, Math.ceil(matchingOrderCount / crmPageSize))
  const currentPage = ordersList.data?.page ?? 1
  const pageById = new Map(pageOrders.map(order => [order.id, order]))
  const selectedOrders = orderSelection.map(order => pageById.get(order.id) ?? order)
  const selectedOrderIds = new Set(selectedOrders.map(order => order.id))
  const pageSelected = pageOrders.length > 0 && pageOrders.every(order => selectedOrderIds.has(order.id))
  const selectedOutsidePage = selectedOrders.filter(order => !pageById.has(order.id)).length
  const selectedTtnCandidates = selectedOrders.filter(canCreateTtn)
  const pageOrder = selectedOrderId ? pageById.get(selectedOrderId) : undefined
  const orderDetails = useCrmPage<OrderListRow>('crm_orders_page', {
    p_store_id: storeId, p_order_ids: selectedOrderId ? [selectedOrderId] : null,
  }, 1, member && selectedOrderId && !pageOrder ? token : null, ordersRevision)
  const selectedOrder = pageOrder ?? orderDetails.data?.rows[0]
  const exportOrders = async () => {
    if (!token || (!selectedOrders.length && !matchingOrderCount) || exportingOrders) return
    setExportingOrders(true)
    setError(null)
    try {
      const orders = selectedOrders.length ? selectedOrders : await fetchCrmExportRows<OrderListRow>('crm_orders_page', orderFilters, token)
      const refs = orders.flatMap(order => {
        const ids = [order.id, ...order.member_ids.filter(id => id !== order.id)]
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
    if (status === 'CANCELLED_BY_STORE' && !await confirmAction({
      title: t('Cancel order'), message: t('Are you sure you want to cancel the selected orders?'), confirmLabel: t('Cancel order'),
    })) return false
    let source: string | null = null
    let received: string | null = null
    const request = () => supabaseRequest<{ orders: Array<Pick<AdminOrder, 'id' | 'status' | 'payment_status'>>; stock_added: number }>(
      '/rest/v1/rpc/correct_admin_order_status', {
        method: 'POST', token, body: JSON.stringify({
          p_order_ids: ids, p_status: status, p_confirm_paid: true, p_restore_stock: restoreStock, p_source: source, p_received: received,
        }),
      },
    )
    let updated
    while (!updated) {
      try {
        updated = await request()
      } catch (cause) {
        if (!(cause instanceof SupabaseError)) throw cause
        if (cause.message === 'Confirm COD collection' && !received) {
          received = await choose('Was the COD payment received for the selected completed orders?', [['yes','Payment received'],['no','Still awaiting payment']])
          if (!received) return false
        } else if (cause.message === 'Choose stock for reopened orders' && !source) {
          source = await choose('Where will the unallocated items for the reopened orders come from?', [['stock','Use available stock'],['supplier','Order from supplier']])
          if (!source) return false
        } else throw cause
      }
    }
    if (updated.stock_added > 0) addToast(t('Added to stock after cancellation: {{quantity}} units.', { quantity: updated.stock_added }))
    const byId = new Map(updated.orders.map(order => [order.id, order]))
    setOrderSelection(current => current.map(order => {
      const update = byId.get(order.id)
      return update ? { ...order, ...update, is_new: order.is_new && update.status === order.status } : order
    }))
    setOrdersRevision(value => value + 1)
    refreshProducts()
    return true
  }

  const changeStatus = async (id: string, status: OrderStatus, restoreStock = false) => {
    if (!token || updatingId || bulkBusy) return
    setUpdatingId(id)
    setError(null)
    try {
      await updateOrderStatus([id], status, restoreStock)
    } catch (cause) {
      setError(cause instanceof Error ? t(cause.message) : t('Action failed'))
    } finally {
      setUpdatingId(null)
    }
  }

  const refreshTracking = async (id: string) => {
    if (!token) return
    setTrackingId(id); setError(null)
    try {
      const result = await supabaseRequest<{ status: string }>('/functions/v1/nova-poshta-track-ttn', { method: 'POST', token, body: JSON.stringify({ orderId: id }) })
      setOrderSelection(current => current.map(order => order.id === id ? { ...order, nova_poshta_status: result.status } : order))
      setOrdersRevision(value => value + 1)
    } catch (cause) { setError(cause instanceof Error ? cause.message : 'Could not update shipment status') } finally { setTrackingId(null) }
  }

  const saveShipment = (id: string, { ttn, documentRef, existing }: TtnShipment, refresh = true) => {
    setOrderSelection(current => current.flatMap(order => {
      if (order.id !== id) return [order]
      return existing ? [{ ...order, nova_poshta_ttn: ttn, nova_poshta_document_ref: documentRef }] : []
    }))
    if (refresh) setOrdersRevision(value => value + 1)
  }

  const createBulkTtns = async () => {
    if (!token) return
    setBulkBusy(true)
    setError(null)
    let skipped = selectedOrders.length - selectedTtnCandidates.length
    let refreshOrders = false
    const ready: Array<{ order: AdminOrder; weightGrams: number; declaredValueMinor: number; codMinor: number }> = []
    const issues: string[] = []
    const skippedMessage = () => t('TTN creation skipped for {{count}} orders', { count: skipped })
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
            !Number.isSafeInteger(preview.value.codMinor) && t('Cash on delivery amount'),
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
          ready.push({ order, weightGrams, declaredValueMinor, codMinor: preview.value.codMinor })
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
        details: [...issues, ...ready.map(({ order, codMinor }) => `#${order.receipt_code} · ${t('Cash on delivery amount')} ${formatPrice(codMinor / 100, order.currency)}`)],
        confirmLabel: t(issues.length ? 'Skip and create TTNs' : 'Create TTNs'),
        confirmDisabled: !ready.length,
      })
      if (!confirmed) return

      let created = 0
      const failures: string[] = []
      for (const { order, weightGrams, declaredValueMinor, codMinor } of ready) {
        try {
          const shipment = await createTtn(token, {
            orderId: order.id,
            description: defaultParcelDescription,
            internalOrderNumber: order.receipt_code,
            weightGrams,
            declaredValueMinor, expectedCodMinor: codMinor,
          })
          saveShipment(order.id, shipment, false)
          refreshOrders = true
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
      const eligible = restoreStock ? selectedOrders.filter(canCancelWithStock) : selectedOrders
      const skipped = selectedOrders.filter(order => !eligible.includes(order))
      try {
        if (eligible.length && !await updateOrderStatus(eligible.map(order => order.id), status, restoreStock)) return
        setOrderSelection(skipped)
        setBulkAction('')
        if (skipped.length) {
          const message = t('Only pending unpaid orders can be cancelled with stock restoration')
          setError(skipped.map(order => `#${order.receipt_code}: ${message}`).join(' · '))
        }
        if (eligible.length) addToast(t('Orders updated: {{count}}', { count: eligible.length }))
      } catch (cause) {
        setError(cause instanceof Error ? t(cause.message) : t('Action failed'))
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
    setOrderSelection(selectedOrders.filter(order => failed.some(item => item.order.id === order.id)))
    if (updated.size) setOrdersRevision(value => value + 1)
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
  if (member === null) return <LoadingIndicator label={t('Loading CRM…')} />
  const canBroadcast = member === 'OWNER' || member === 'MANAGER'

  return (
    <section className="crm-page">
      <header className="crm-header">
        <div className="crm-masthead"><div><p className="eyebrow">{store.name} / {t('management')}</p><h1>{t('CRM')}</h1><p>{t('Your store, in one place.')}</p></div><span className="crm-masthead__mark" aria-hidden="true">T.</span></div>
        <AdminTabs active={section} onChange={next => {
          if (next === 'catalogue') { setCatalogFilter('all'); setCatalogSearch('') }
          if (next === 'orders') setDashboardOrderIds(null)
          if (next === 'overview') setOrdersRevision(value => value + 1)
          setSection(next)
        }} />
      </header>
      {error ? <div className="crm-error" role="alert"><span>{error}</span><button type="button" className="text-btn" onClick={() => setError(null)}>{t('Close')}</button></div> : null}
      {orderDetails.loading && !selectedOrder && <p className="muted" role="status">{t('Loading…')}</p>}
      {orderDetails.error && <div className="crm-error" role="alert"><span>{t(orderDetails.error)}</span><button type="button" className="text-btn" onClick={() => setSelectedOrderId(null)}>{t('Close')}</button></div>}
      {section !== 'catalogue' && <div className="crm-section-head">
        <div><span className="crm-section-head__label"><span>{store.name}</span> / CRM</span><h2>{section === 'overview' ? t('Overview') : section === 'orders' ? t('Orders') : section === 'customers' ? t('Customers') : t('Settings')}</h2></div>
        {section === 'orders' && token && <div className="crm-section-actions">
          <button type="button" className="btn btn--ghost" aria-haspopup="dialog"
            onClick={() => setImportOrdersOpen(true)}>{t('Import')}</button>
          <button type="button" className="btn" aria-haspopup="dialog"
            onClick={() => setCreateOrderOpen(true)}>{t('Create order')}</button>
        </div>}
        {section === 'customers' && token && canBroadcast && <div className="crm-section-actions">
          <button type="button" className="btn" aria-haspopup="dialog" onClick={() => setBroadcastOpen(true)}>{t('Push broadcast')}</button>
        </div>}
      </div>}
      {token && <div hidden={section !== 'overview'}><AdminDashboard active={section === 'overview'}
        storeId={store.id} currency={store.currency} token={token} orders={dashboardOrders} inventory={inventory}
        mergeMembers={mergeMembers} revision={ordersRevision} onRefresh={() => setOrdersRevision(value => value + 1)}
        onOpenOrders={ids => {
          setDashboardOrderIds([...new Set(ids)])
          setCustomerOrderFilter(null)
          setSearch(''); setOrderFilter('ALL'); setFromDate(''); setToDate(''); setPage(1); setSection('orders')
        }}
        onOpenOrder={id => setSelectedOrderId(id)}
        onOpenCatalog={query => { setCatalogSearch(query ?? ''); setCatalogFilter('stock'); setSection('catalogue') }}
        onOpenCustomers={() => setSection('customers')}
      /></div>}
      {section === 'customers' ? <CustomersPage revision={customerRevision} onOpenCustomer={id => setSelectedCustomer({ kind: 'customer', id })} /> : section === 'catalogue' ? <CatalogAdminPage key={`${catalogFilter}:${catalogSearch}`} embedded initialFilter={catalogFilter} initialSearch={catalogSearch} /> : section === 'settings' ? <SettingsWorkspace canManageStaffNotifications={canBroadcast} /> : section === 'orders' ? <>
      {store && token && <PaymentReviewList storeId={store.id} token={token} revision={ordersRevision} />}
      <div className="crm-grid crm-grid--orders">
        <section className="crm-panel">
          <div className="order-filters">
            <label className="search-field">
              <span className="sr-only">{t('Search orders by name, order number, TTN or phone')}</span>
              <input type="search" placeholder={t('Search orders by name, order number, TTN or phone')} value={search} onChange={(event) => { setSearch(event.target.value); setPage(1) }} />
            </label>
            <select value={orderFilter} onChange={(event) => { setOrderFilter(event.target.value as OrderFilter); setPage(1) }}>
              <option value="ALL">{t('All statuses')}</option>
              <option value="NEW">{t('New orders')}</option>
              <option value="NO_TTN">{t('Without TTN')}</option>
              {statuses.map((status) => <option key={status} value={status}>{t(status)}</option>)}
            </select>
            <div className="order-date-filter">
              <input aria-label={t('Orders from date')} type="date" value={fromDate} onChange={event => { setFromDate(event.target.value); setPage(1) }} />
              {!fromDate && <span className="order-date-filter__placeholder" aria-hidden="true">{t('From date')}</span>}
            </div>
            <div className="order-date-filter">
              <input aria-label={t('Orders to date')} type="date" value={toDate} onChange={event => { setToDate(event.target.value); setPage(1) }} />
              {!toDate && <span className="order-date-filter__placeholder" aria-hidden="true">{t('To date')}</span>}
            </div>
          </div>
          {(dashboardOrderIds !== null || customerOrderFilter !== null) && <div className="dashboard-order-filter" role="status">
            <span>{customerOrderFilter ? t('Orders for {{name}}', { name: customerOrderFilter.name }) : t('Dashboard selection')} · {matchingOrderCount}</span>
            <button type="button" className="text-btn" onClick={() => { setDashboardOrderIds(null); setCustomerOrderFilter(null); setPage(1) }}>{t('Show all orders')}</button>
          </div>}
          <div className="orders-list-toolbar">
            <button className="text-btn" title={t(selectedOrders.length ? 'Export selected orders' : 'Export CSV')} disabled={(!selectedOrders.length && !matchingOrderCount) || exportingOrders} onClick={() => void exportOrders()}>
              {exportingOrders ? t('Preparing CSV…') : `${t('Export CSV')} (${selectedOrders.length || matchingOrderCount})`}
            </button>
            <CrmPagination page={currentPage} pages={pages} loading={ordersList.loading} onChange={setPage} />
          </div>
          {(pageOrders.length > 0 || selectedOrderIds.size > 0) && <div className="order-bulk order-bulk--orders" role="group" aria-label={t('Bulk action')}>
            <label className="order-select-all">
              <input type="checkbox" checked={pageSelected} disabled={bulkBusy || !pageOrders.length}
                ref={input => { if (input) input.indeterminate = !pageSelected && selectedOrderIds.size > selectedOutsidePage }}
                onChange={event => {
                  const checked = event.target.checked
                  setOrderSelection(current => [...current.filter(order => !pageById.has(order.id)), ...(checked ? pageOrders : [])])
                  setBulkAction('')
                }} />
              {t('Select all on this page')}
            </label>
            <div className="order-bulk__actions" aria-hidden={!selectedOrderIds.size} inert={!selectedOrderIds.size}>
              <div className="catalog-bulk__selection" aria-live="polite">
                <span className="catalog-bulk__count">{selectedOrderIds.size}</span>
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
                <button type="button" className="catalog-bulk__clear" disabled={bulkBusy} onClick={() => { setOrderSelection([]); setBulkAction('') }}>{t('Clear selection')}</button>
              </div>
            </div>
          </div>}
          {ordersList.loading && !ordersList.data ? <p className="muted" role="status">{t('Loading…')}</p>
            : ordersList.error ? <p className="error" role="alert">{t(ordersList.error)} <button type="button" className="text-btn" onClick={ordersList.retry}>{t('Try again')}</button></p>
            : !pageOrders.length ? <p className="muted">{t('No orders match these filters.')}</p> : <ul className="admin-list" aria-busy={ordersList.loading}>{pageOrders.map((order) => {
            const receiptPath = `/receipt/${encodeURIComponent(order.receipt_code)}`
            const note = order.note?.trim()
            return (
              <li key={order.id} className={`crm-order${selectedOrderIds.has(order.id) ? ' crm-order--selected' : ''}`}>
                <div className="crm-order__summary" onClick={event => {
                  if (event.target instanceof Element && event.target.closest('a, button, input, select, textarea, label')) return
                  setSelectedOrderId(order.id)
                }}>
                  <label className="order-select">
                    <input type="checkbox" checked={selectedOrderIds.has(order.id)} disabled={bulkBusy}
                      onChange={event => {
                        const checked = event.target.checked
                        setOrderSelection(current => checked ? [...current, order] : current.filter(selected => selected.id !== order.id))
                        setBulkAction('')
                      }} />
                    <span className="sr-only">{t('Select order')} #{order.receipt_code}</span>
                  </label>
                  <div className="crm-order__identity">
                    <span className="crm-order__reference"><button type="button" className="text-btn" aria-haspopup="dialog" onClick={() => setSelectedOrderId(order.id)}>#{order.receipt_code}</button>{order.is_new && <span className="crm-order__new">{t('New order label')}</span>}<span className="crm-order__date"><time dateTime={order.created_at}>{formatDate(order.created_at)} · {new Intl.DateTimeFormat('en-GB', { hour: '2-digit', minute: '2-digit' }).format(new Date(order.created_at))}</time>{order.member_ids.length > 1 && ` · ${t('Merged orders: {{count}}', { count: order.member_ids.length })}`}</span></span>
                    {note && <p className="crm-order__note"><strong>{t('Note')}</strong> {note}</p>}
                    {order.customer_email && <span className="crm-order__email">{order.customer_email}</span>}
                  </div>
                  <div className="crm-order__amount"><strong>{formatPrice(Number(order.total_price) / 100, order.currency)}</strong><span>{order.payment_method === 'CASH_ON_DELIVERY' ? t('Payment on delivery') : t('Online payment')}</span></div>
                  <div className="crm-order__status">
                    <span>{t('Order status')}</span>
                    <label className="sr-only" htmlFor={`status-${order.id}`}>{t('Order status')}</label>
                    <select id={`status-${order.id}`} value={order.status} disabled={bulkBusy || Boolean(updatingId)} onChange={(event) => void changeStatus(order.id, event.target.value as OrderStatus)}>
                      {!statuses.includes(order.status) && <option value={order.status}>{t(order.status)}</option>}
                      {statuses.filter(status => order.status !== 'CANCELLED_BY_USER' || status !== 'CANCELLED_BY_STORE').map(status => <option key={status} value={status}>{t(status)}</option>)}
                    </select>
                  </div>
                  {order.nova_poshta_status && <p className="crm-order__delivery">{order.nova_poshta_status}</p>}
                </div>
                <div className="crm-order__actions"><button type="button" className="text-btn" onClick={() => void copyReceiptLink(receiptPath)}>{t('Copy receipt link')}</button>
                <button type="button" className="text-btn" aria-haspopup="dialog" title={t('Open customer card')} onClick={() => setSelectedCustomer({ kind: 'order', id: order.id })}>{t('Customer')}</button>
                {order.status === 'COMPLETED' && order.nova_poshta_ttn &&
                  <span className="crm-order__ttn">{t('TTN')} {order.nova_poshta_ttn}</span>}
                {order.status !== 'COMPLETED' && order.nova_poshta_ttn && (
                  <span className="ttn-actions">
                    <NovaPoshtaTrackingLink className="text-btn" ttn={order.nova_poshta_ttn}>TTN {order.nova_poshta_ttn}</NovaPoshtaTrackingLink>
                    <OrderActionButton type="button" className="text-btn"
                      disabledReason={trackingId === order.id ? t('Tracking status is being updated.') : bulkBusy ? t('A bulk order action is running.') : undefined}
                      onClick={() => void refreshTracking(order.id)}>{trackingId === order.id ? t('Updating…') : t('Update status')}</OrderActionButton>
                  </span>
                )}
                {canCreateTtn(order) && (
                  <OrderActionButton type="button" className="text-btn" aria-haspopup="dialog"
                    disabledReason={bulkBusy ? t('A bulk order action is running.') : undefined}
                    onClick={() => setTtnOrder(order)}>{t('Create TTN')}</OrderActionButton>
                )}
                {order.status.startsWith('CANCELLED') && token && <CancelledOrderRefunds orderIds={order.member_ids} token={token} compact onChange={() => setOrdersRevision(value => value + 1)} />}
                {canCancelWithStock(order) && <button type="button" className="text-btn crm-order__cancel" disabled={bulkBusy || Boolean(updatingId)} onClick={() => void changeStatus(order.id, 'CANCELLED_BY_STORE', true)}>{t('Cancel & restore stock')}</button>}</div>
              </li>
            )
          })}</ul>}
          {pageOrders.length > 0 && <CrmPagination page={currentPage} pages={pages} loading={ordersList.loading} onChange={setPage} />}
        </section>
      </div>
      </> : null}
      {createOrderOpen && token && <CreateOrderDrawer store={store} token={token} onClose={() => setCreateOrderOpen(false)}
        onCreated={id => {
          setOrdersRevision(value => value + 1)
          setCustomerRevision(value => value + 1)
          setSelectedOrderId(id)
          addToast(t('Order created'))
        }} />}
      {importOrdersOpen && token && <ImportOrdersDialog store={store} token={token} onClose={() => setImportOrdersOpen(false)}
        onImported={() => {
          setOrdersRevision(value => value + 1)
          setCustomerRevision(value => value + 1)
          refreshProducts()
        }} />}
      {broadcastOpen && token && canBroadcast && <CustomerNotificationDrawer storeId={store.id} token={token}
        onClose={() => setBroadcastOpen(false)} />}
      {selectedCustomer && token && <CustomerPanel key={`${selectedCustomer.kind}:${selectedCustomer.id}`}
        target={selectedCustomer} storeId={store.id} token={token}
        onSaved={() => setCustomerRevision(value => value + 1)} onClose={() => setSelectedCustomer(null)}
        onViewOrders={(id, name) => {
          setCustomerOrderFilter({ id, name }); setDashboardOrderIds(null)
          setSearch(''); setOrderFilter('ALL'); setFromDate(''); setToDate(''); setPage(1)
          setOrderSelection([]); setBulkAction(''); setOrdersRevision(value => value + 1); setSection('orders')
        }} />}
      {orderChoice && <CenteredDialog aria-label={t(orderChoice.question)} onClose={value => {
        orderChoice.resolve(orderChoice.options.some(([key]) => key === value) ? value : '')
        setOrderChoice(null)
      }}>
        <h2>{t(orderChoice.question)}</h2>
        {orderChoice.options.some(([key]) => key === 'yes') && <p>{t('For an existing waybill, verify the collection amount in Nova Poshta.')}</p>}
        <form method="dialog" className="confirmation-dialog__actions">
          <button className="btn btn--ghost" value="cancel" autoFocus>{t('Cancel')}</button>
          {orderChoice.options.map(([key, label]) => <button className="btn" key={key} value={key}>{t(label)}</button>)}
        </form>
      </CenteredDialog>}
      {confirmation && <ConfirmationDialog {...confirmation.content} onClose={confirmed => {
        setConfirmation(null)
        confirmation.resolve(confirmed)
      }} />}
      {selectedOrder && token && <OrderOperations key={selectedOrder.id} order={selectedOrder} orderIds={selectedOrder.member_ids} token={token}
        onOpenOrder={setSelectedOrderId}
        onChanged={() => setOrdersRevision(value => value + 1)}
        onClose={() => { setSelectedOrderId(null); setOrdersRevision(value => value + 1) }} />}
      {mergeOpen && token && <MergeOrdersDrawer orders={selectedOrders} busy={bulkBusy} error={mergeError} onClose={() => setMergeOpen(false)} onMerge={targetId => {
        setBulkBusy(true)
        setMergeError(null)
        void supabaseRequest('/rest/v1/rpc/merge_orders', { method: 'POST', token, body: JSON.stringify({ p_order_ids: selectedOrders.map(order => order.id), p_target_id: targetId }) })
          .then(() => { setMergeOpen(false); setOrderSelection([]); setOrdersRevision(value => value + 1); addToast(t('Orders merged')) })
          .catch(cause => setMergeError(cause instanceof Error ? cause.message : t('Action failed')))
          .finally(() => setBulkBusy(false))
      }} />}
      {ttnOrder && token && <CreateTtnDrawer key={ttnOrder.id} orderId={ttnOrder.id} receiptCode={ttnOrder.receipt_code} customerName={ttnOrder.customer_name}
        token={token} onClose={() => setTtnOrder(null)} onCreated={shipment => saveShipment(ttnOrder.id, shipment)} />}
    </section>
  )
}
