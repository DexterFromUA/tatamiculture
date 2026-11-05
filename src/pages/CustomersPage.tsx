import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { downloadCsv, fetchAll, customerPhone } from '../lib/crm'
import { formatPrice } from '../lib/format'
import type { CrmCustomer, CrmOrder } from '../components/CrmCustomerCard'

export function CustomersPage({ onOpenCustomer, revision }: { onOpenCustomer: (id: string) => void; revision: number }) {
  const { store } = useStore()
  const { token } = useAuth()
  const { t } = useTranslation()
  const [customers, setCustomers] = useState<CrmCustomer[]>([])
  const [orders, setOrders] = useState<CrmOrder[]>([])
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [search, setSearch] = useState('')
  const [duplicatesOnly, setDuplicatesOnly] = useState(false)
  const [page, setPage] = useState(1)
  useEffect(() => {
    if (!store || !token) return
    const abort = new AbortController()
    Promise.all([
      fetchAll<CrmCustomer>(`/rest/v1/crm_customers?store_id=eq.${store.id}&select=*&order=created_at.desc,id`, token, abort.signal),
      fetchAll<CrmOrder>(`/rest/v1/orders?store_id=eq.${store.id}&select=id,crm_customer_id,user_id,receipt_code,total_price,currency,status,created_at&order=created_at.desc,id`, token, abort.signal),
    ]).then(([people, purchases]) => { setCustomers(people); setOrders(purchases); setError('') })
      .catch(cause => { if (!abort.signal.aborted) setError(cause.message) })
      .finally(() => { if (!abort.signal.aborted) setLoading(false) })
    return () => abort.abort()
  }, [store, token, revision])
  const phoneCounts = new Map<string, number>()
  for (const customer of customers) {
    const phone = customerPhone(customer.phone)
    if (phone.length >= 9) phoneCounts.set(phone, (phoneCounts.get(phone) ?? 0) + 1)
  }
  const rows = customers.filter(customer => `${customer.name} ${customer.phone} ${customer.email} ${customer.tags.join(' ')}`.toLowerCase().includes(search.toLowerCase()) && (!duplicatesOnly || (phoneCounts.get(customerPhone(customer.phone)) ?? 0) > 1)).map(customer => {
    const own = orders.filter(order => order.crm_customer_id === customer.id && !order.status.startsWith('CANCELLED'))
    const totals = new Map<string, number>()
    for (const order of own) totals.set(order.currency, (totals.get(order.currency) ?? 0) + Number(order.total_price))
    return { ...customer, count: own.length, total: [...totals].map(([currency, amount]) => formatPrice(amount / 100, currency)).join(' · ') }
  })
  const pages = Math.max(1, Math.ceil(rows.length / 20))
  const current = Math.min(page, pages)
  return <section className="customers-page">
    {error && <p className="error">{error}</p>}
    {loading ? <p>{t('Loading…')}</p> : <section className="crm-panel">
      <h2>{t('Customers')} · {customers.length}</h2>
      <div className="customers-toolbar">
        <input aria-label={t('Search customers')} placeholder={t('Search customers')} value={search} onChange={event => { setSearch(event.target.value); setPage(1) }} />
        <label className="check"><input type="checkbox" checked={duplicatesOnly} onChange={event => { setDuplicatesOnly(event.target.checked); setPage(1) }} />{t('Matching phone numbers')}</label>
        <button className="text-btn" onClick={() => downloadCsv('Tatami.Culture-customers.csv', [[t('Name'), t('Phone'), t('Email'), t('Orders'), t('Total')], ...rows.map(row => [row.name, row.phone, row.email, row.count, row.total])])}>{t('Export CSV')}</button>
      </div>
      <ul className="customers-list">{rows.slice((current - 1) * 20, current * 20).map(customer => <li key={customer.id}>
        <div><button type="button" className="text-btn" aria-haspopup="dialog" onClick={() => onOpenCustomer(customer.id)}>{customer.name}</button><span>{customer.phone || customer.email} · {customer.tags.join(' · ')}</span></div>
        <span>{customer.count} {t('orders')}</span><strong>{customer.total || '—'}</strong>
      </li>)}</ul>
      {!rows.length && <p>{t('No customers match this search.')}</p>}
      <div className="crm-pagination"><button className="text-btn" disabled={current === 1} onClick={() => setPage(current - 1)}>{t('Previous')}</button><span>{current} / {pages}</span><button className="text-btn" disabled={current === pages} onClick={() => setPage(current + 1)}>{t('Next')}</button></div>
    </section>}
  </section>
}
