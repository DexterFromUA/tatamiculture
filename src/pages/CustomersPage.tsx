import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { CrmPagination } from '../components/CrmPagination'
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

export function CustomersPage({ onOpenCustomer, revision }: { onOpenCustomer: (id: string) => void; revision: number }) {
  const { store } = useStore()
  const { token } = useAuth()
  const { t } = useTranslation()
  const [exportError, setExportError] = useState('')
  const [exporting, setExporting] = useState(false)
  const [search, setSearch] = useState('')
  const [filter, setFilter] = useState<CustomerFilter>('all')
  const [page, setPage] = useState(1)
  const filters = { p_store_id: store?.id, p_search: search.trim(), p_filter: filter }
  const { data, error, loading, retry } = useCrmPage<CustomerListRow>('crm_customers_page', filters, page, token, revision)
  const rows = data?.rows ?? []
  const pages = Math.max(1, Math.ceil((data?.total ?? 0) / crmPageSize))
  const current = data?.page ?? 1
  const searchLabel = t('Search by name, phone, order or note')

  const exportCustomers = async () => {
    if (!store || !token || exporting) return
    setExporting(true)
    setExportError('')
    try {
      const customers = await fetchCrmExportRows<CrmCustomer>('crm_customers_page', filters, token)
      const orders: CustomerExportOrder[] = []
      for (let offset = 0; offset < customers.length; offset += 50) {
        const ids = customers.slice(offset, offset + 50).map(customer => customer.id).join(',')
        const fields = 'id,crm_customer_id,user_id,receipt_code,total_price,currency,status,payment_status,payment_method,created_at'
        const batch = await fetchAll<CustomerExportOrder>(`/rest/v1/orders?store_id=eq.${store.id}&crm_customer_id=in.(${ids})&select=${fields}&order=created_at.desc,id`, token)
        orders.push(...batch)
      }
      downloadCustomersCsv(customers, orders, store.currency, t)
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
        <button className="text-btn" disabled={!store || !data?.total || exporting} onClick={() => void exportCustomers()}>
          {t(exporting ? 'Preparing export…' : 'Export CSV')}
        </button>
        <CrmPagination page={current} pages={pages} loading={loading} onChange={setPage} />
      </div>
      {loading && !data && <p className="muted" role="status">{t('Loading…')}</p>}
      <ul className="customers-list" aria-busy={loading}>{rows.map(customer => <li key={customer.id}>
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
      </li>)}</ul>
      {data && !rows.length && <p>{t('No customers match this search.')}</p>}
      {rows.length > 0 && <CrmPagination page={current} pages={pages} loading={loading} onChange={setPage} />}
    </section>
  </section>
}
