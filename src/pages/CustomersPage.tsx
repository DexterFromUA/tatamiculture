import { useState, type Dispatch, type SetStateAction } from 'react'
import { useTranslation } from 'react-i18next'
import { CrmPagination } from '../components/CrmPagination'
import { CustomerNotificationDrawer } from '../components/CustomerNotificationDrawer'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { useCrmPage } from '../hooks/useCrmPage'
import { crmPageSize, fetchAll, fetchCrmExportRows } from '../lib/crm'
import { downloadCustomersCsv, type CustomerExportOrder } from '../lib/crmExport'
import { formatPrice } from '../lib/format'
import type { CrmCustomer } from '../components/CrmCustomerCard'

type CustomerListRow = CrmCustomer & {
  has_active_discount: boolean
  order_count: number
  totals: Record<string, number>
}

const customerFilters = {
  all: 'All customers',
  'confirmed-phone': 'Confirmed phone',
  'unconfirmed-phone': 'Unconfirmed phone',
  administrators: 'Administrators',
  discount: 'With an active discount',
  duplicates: 'Matching phone numbers',
} as const
type CustomerFilter = keyof typeof customerFilters

export function CustomersPage({ onOpenCustomer, revision, selection, setSelection }: {
  onOpenCustomer: (id: string) => void; revision: number
  selection?: string[]; setSelection: Dispatch<SetStateAction<string[]>>
}) {
  const { store } = useStore()
  const { token } = useAuth()
  const { t } = useTranslation()
  const [exportError, setExportError] = useState('')
  const [exporting, setExporting] = useState(false)
  const [search, setSearch] = useState('')
  const [filter, setFilter] = useState<CustomerFilter>('all')
  const [page, setPage] = useState(1)
  const [notificationCustomer, setNotificationCustomer] = useState<CrmCustomer | null>(null)
  const filters = { p_store_id: store?.id, p_search: search.trim(), p_filter: filter }
  const { data, error, loading, retry } = useCrmPage<CustomerListRow>('crm_customers_page', filters, page, token, revision)
  const rows = data?.rows ?? []
  const selectedIds = new Set(selection)
  const pageIds = new Set(rows.map(customer => customer.id))
  const selectedOnPage = rows.filter(customer => selectedIds.has(customer.id)).length
  const pageSelected = rows.length > 0 && selectedOnPage === rows.length
  const selectedOutsidePage = selectedIds.size - selectedOnPage
  const pages = Math.max(1, Math.ceil((data?.total ?? 0) / crmPageSize))
  const current = data?.page ?? 1
  const searchLabel = t('Search by name, phone, order or note')
  const exportCount = selectedIds.size || data?.total || 0

  const exportCustomers = async () => {
    if (!store || !token || !exportCount || exporting) return
    setExporting(true)
    setExportError('')
    try {
      const customers = selectedIds.size ? [] : await fetchCrmExportRows<CrmCustomer>('crm_customers_page', filters, token)
      const exportIds = selectedIds.size ? [...selectedIds] : customers.map(customer => customer.id)
      const orders: CustomerExportOrder[] = []
      for (let offset = 0; offset < exportIds.length; offset += crmPageSize) {
        const ids = exportIds.slice(offset, offset + crmPageSize).join(',')
        if (selectedIds.size) {
          const customerFields = 'id,name,phone,email,notes,tags,created_at'
          const batch = await fetchAll<CrmCustomer>(`/rest/v1/crm_customers?store_id=eq.${store.id}&id=in.(${ids})&select=${customerFields}&order=created_at.desc,id`, token)
          customers.push(...batch)
        }
        const orderFields = 'id,crm_customer_id,user_id,receipt_code,total_price,currency,status,payment_status,payment_method,created_at'
        const batch = await fetchAll<CustomerExportOrder>(`/rest/v1/orders?store_id=eq.${store.id}&crm_customer_id=in.(${ids})&select=${orderFields}&order=created_at.desc,id`, token)
        orders.push(...batch)
      }
      await downloadCustomersCsv(customers, orders, store.id, store.currency, token, t)
    } catch (cause) {
      setExportError(cause instanceof Error ? cause.message : 'Could not export customers')
    } finally {
      setExporting(false)
    }
  }

  return <section className="customers-page">
    {error && <p className="error" role="alert">{t(error)} <button type="button" className="text-btn" onClick={retry}>{t('Try again')}</button></p>}
    {exportError && <p className="error" role="alert">{t(exportError)}</p>}
    <section className="crm-panel">
      <div className="customers-toolbar">
        <label className="search-field"><span className="sr-only">{searchLabel}</span><input type="search" placeholder={searchLabel} value={search} onChange={event => { setSearch(event.target.value); setPage(1) }} /></label>
        <select aria-label={t('Customer filter')} value={filter} onChange={event => { setFilter(event.target.value as CustomerFilter); setPage(1) }}>
          {Object.entries(customerFilters).map(([value, label]) => <option key={value} value={value}>{t(label)}</option>)}
        </select>
      </div>
      <div className="orders-list-toolbar">
        <button type="button" className="text-btn" title={t(selectedIds.size ? 'Export selected customers' : 'Export CSV')}
          disabled={!store || !token || !exportCount || exporting} onClick={() => void exportCustomers()}>
          {exporting ? t('Preparing export…') : `${t('Export CSV')} (${exportCount})`}
        </button>
        <CrmPagination page={current} pages={pages} loading={loading} onChange={setPage} />
      </div>
      {selection && (rows.length > 0 || selectedIds.size > 0) && <div className="order-bulk" role="group" aria-label={t('Select customers for broadcast')}>
        <label className="order-select-all">
          <input type="checkbox" checked={pageSelected} disabled={loading || !rows.length}
            ref={input => { if (input) input.indeterminate = !pageSelected && selectedOnPage > 0 }}
            onChange={event => {
              const checked = event.target.checked
              setSelection(current => [...current.filter(id => !pageIds.has(id)), ...(checked ? pageIds : [])])
            }} />
          {t('Select all on this page')}
        </label>
        <div className="order-bulk__actions" aria-hidden={!selectedIds.size} inert={!selectedIds.size}>
          <div className="catalog-bulk__selection" aria-live="polite">
            <span className="catalog-bulk__count">{selectedIds.size}</span>
            <div className="catalog-bulk__selection-label">
              <span>{t('Selected customers')}</span>
              {selectedOutsidePage > 0 && <small>{t('Outside this page: {{count}}', { count: selectedOutsidePage })}</small>}
            </div>
          </div>
          <button type="button" className="catalog-bulk__clear" onClick={() => setSelection([])}>{t('Clear selection')}</button>
        </div>
      </div>}
      {loading && !data && <p className="muted" role="status">{t('Loading…')}</p>}
      <ul className="customers-list" aria-busy={loading}>{rows.map(customer => <li key={customer.id}
        className={selectedIds.has(customer.id) ? 'customer-list-card--selected' : undefined}>
        <div className={`customer-list-card__summary${selection ? ' customer-list-card__summary--selectable' : ''}`}>
          {selection && <label className="order-select">
            <input type="checkbox" checked={selectedIds.has(customer.id)} onChange={event => {
              const checked = event.target.checked
              setSelection(current => checked ? [...current, customer.id] : current.filter(id => id !== customer.id))
            }} />
            <span className="sr-only">{t('Select customer')} {customer.name}</span>
          </label>}
          <button type="button" className="customer-list-card" aria-haspopup="dialog" onClick={() => onOpenCustomer(customer.id)}>
            <span className="customer-list-card__identity">
              <span className="customer-list-card__name">
                <strong>{customer.name}</strong>
                {customer.has_active_discount && <span className="customer-list-card__discount">{t('Personal discount')}</span>}
                {(customer.phone || customer.email) && <small>{customer.phone || customer.email}</small>}
              </span>
              {customer.tags.length > 0 && <small>{customer.tags.join(' · ')}</small>}
            </span>
            <span>{customer.order_count} {t('orders')}</span><strong>{Object.entries(customer.totals)
              .map(([currency, amount]) => formatPrice(amount / 100, currency)).join(' · ') || '—'}</strong>
          </button>
        </div>
        <div className="crm-order__actions customer-list-card__actions">
          <button type="button" className="text-btn" aria-haspopup="dialog"
            onClick={() => setNotificationCustomer(customer)}>{t('Notifications')}</button>
        </div>
      </li>)}</ul>
      {data && !rows.length && <p>{t('No customers match this search.')}</p>}
      {rows.length > 0 && <CrmPagination page={current} pages={pages} loading={loading} onChange={setPage} />}
    </section>
    {store && token && notificationCustomer && <CustomerNotificationDrawer storeId={store.id} token={token}
      customerId={notificationCustomer.id} customerName={notificationCustomer.name} onClose={() => setNotificationCustomer(null)} />}
  </section>
}
