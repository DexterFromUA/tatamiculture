import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { crmPageSize, customerPhone, fetchAll } from '../lib/crm'
import { downloadCustomersCsv, type CustomerExportOrder } from '../lib/crmExport'
import { formatPrice } from '../lib/format'
import type { CrmCustomer } from '../components/CrmCustomerCard'

type CustomerListRow = CrmCustomer & {
  phone_confirmed: boolean
  is_administrator: boolean
  has_active_discount: boolean
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
  const [customers, setCustomers] = useState<CustomerListRow[]>([])
  const [orders, setOrders] = useState<CustomerExportOrder[]>([])
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [search, setSearch] = useState('')
  const [filter, setFilter] = useState<CustomerFilter>('all')
  const [page, setPage] = useState(1)
  useEffect(() => {
    if (!store || !token) return
    const abort = new AbortController()
    Promise.all([
      fetchAll<CustomerListRow>(`/rest/v1/rpc/list_crm_customers?p_store_id=${store.id}&order=created_at.desc,id`, token, abort.signal),
      fetchAll<CustomerExportOrder>(`/rest/v1/orders?store_id=eq.${store.id}&select=id,crm_customer_id,user_id,receipt_code,total_price,currency,status,payment_status,payment_method,payment_test_mode,monobank_test_mode,created_at&order=created_at.desc,id`, token, abort.signal),
    ]).then(([people, purchases]) => {
      if (abort.signal.aborted) return
      setCustomers(people); setOrders(purchases); setError('')
    })
      .catch(cause => { if (!abort.signal.aborted) setError(cause.message) })
      .finally(() => { if (!abort.signal.aborted) setLoading(false) })
    return () => abort.abort()
  }, [store, token, revision])
  const phoneCounts = new Map<string, number>()
  for (const customer of customers) {
    const phone = customerPhone(customer.phone)
    if (phone.length >= 9) phoneCounts.set(phone, (phoneCounts.get(phone) ?? 0) + 1)
  }
  const searchQuery = search.trim().toLowerCase()
  const orderQuery = searchQuery.replace(/^#\s*/, '')
  const orderMatches = new Set<string>()
  if (orderQuery) {
    for (const order of orders) {
      if (order.crm_customer_id && order.receipt_code?.toLowerCase().includes(orderQuery)) {
        orderMatches.add(order.crm_customer_id)
      }
    }
  }
  const rows = customers.filter(customer => {
    const matchesFilter = {
      all: true,
      'confirmed-phone': customer.phone_confirmed,
      'unconfirmed-phone': !customer.phone_confirmed,
      administrators: customer.is_administrator,
      discount: customer.has_active_discount,
      duplicates: (phoneCounts.get(customerPhone(customer.phone)) ?? 0) > 1,
    }
    if (!matchesFilter[filter]) return false
    const customerText = `${customer.name} ${customer.phone} ${customer.email} ${customer.tags.join(' ')}`.toLowerCase()
    return customerText.includes(searchQuery) || customer.notes.toLowerCase().includes(searchQuery) || orderMatches.has(customer.id)
  }).map(customer => {
    const own = orders.filter(order => order.crm_customer_id === customer.id && !order.status.startsWith('CANCELLED'))
    const totals = new Map<string, number>()
    for (const order of own) totals.set(order.currency, (totals.get(order.currency) ?? 0) + Number(order.total_price))
    return { ...customer, count: own.length, total: [...totals].map(([currency, amount]) => formatPrice(amount / 100, currency)).join(' · ') }
  })
  const pages = Math.max(1, Math.ceil(rows.length / crmPageSize))
  const current = Math.min(page, pages)
  const searchLabel = t('Search by name, phone, order or note')
  return <section className="customers-page">
    {error && <p className="error">{error}</p>}
    {loading ? <p>{t('Loading…')}</p> : <section className="crm-panel">
      <div className="customers-toolbar">
        <label className="search-field"><span className="sr-only">{searchLabel}</span><input type="search" placeholder={searchLabel} value={search} onChange={event => { setSearch(event.target.value); setPage(1) }} /></label>
        <select aria-label={t('Customer filter')} value={filter} onChange={event => { setFilter(event.target.value as CustomerFilter); setPage(1) }}>
          {Object.entries(customerFilters).map(([value, label]) => <option key={value} value={value}>{t(label)}</option>)}
        </select>
      </div>
      <div className="orders-list-toolbar">
        <button className="text-btn" disabled={!store || !rows.length} onClick={() => {
          if (store) downloadCustomersCsv(rows, orders, store.currency, t)
        }}>{t('Export CSV')}</button>
        <div className="crm-pagination"><button className="text-btn" disabled={current === 1} onClick={() => setPage(current - 1)}>{t('Previous')}</button><span>{current} / {pages}</span><button className="text-btn" disabled={current === pages} onClick={() => setPage(current + 1)}>{t('Next')}</button></div>
      </div>
      <ul className="customers-list">{rows.slice((current - 1) * crmPageSize, current * crmPageSize).map(customer => <li key={customer.id}>
        <button type="button" className="customer-list-card" aria-haspopup="dialog" onClick={() => onOpenCustomer(customer.id)}>
          <span className="customer-list-card__identity"><span className="customer-list-card__name"><strong>{customer.name}</strong>{(customer.phone || customer.email) && <small>{customer.phone || customer.email}</small>}</span>{customer.tags.length > 0 && <small>{customer.tags.join(' · ')}</small>}</span>
          <span>{customer.count} {t('orders')}</span><strong>{customer.total || '—'}</strong>
        </button>
      </li>)}</ul>
      {!rows.length && <p>{t('No customers match this search.')}</p>}
      <div className="crm-pagination"><button className="text-btn" disabled={current === 1} onClick={() => setPage(current - 1)}>{t('Previous')}</button><span>{current} / {pages}</span><button className="text-btn" disabled={current === pages} onClick={() => setPage(current + 1)}>{t('Next')}</button></div>
    </section>}
  </section>
}
