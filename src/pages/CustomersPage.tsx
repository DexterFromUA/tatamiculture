import { useEffect, useState } from 'react'
import { formatDate, formatPrice } from '../lib/format'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { useTranslation } from 'react-i18next'
import { downloadCsv, fetchAll } from '../lib/crm'

type Customer = { user_id: string; joined_at: string; profiles: { name: string; phone: string } | null }
type Order = { id: string; user_id: string; total_price: number; currency: string; status: string }
export function CustomersPage() {
  const { store } = useStore()
  const { token } = useAuth()
  const { t } = useTranslation()
  const [customers, setCustomers] = useState<Customer[]>([])
  const [orders, setOrders] = useState<Order[]>([])
  const [error, setError] = useState('')
  const [search, setSearch] = useState('')
  const [page, setPage] = useState(1)
  const [now] = useState(() => Date.now())
  useEffect(() => {
    if (!store || !token) return
    const abort = new AbortController()
    void Promise.all([
      fetchAll<Customer>(`/rest/v1/store_customers?store_id=eq.${store.id}&select=user_id,joined_at,profiles(name,phone)&order=joined_at.desc,user_id`, token, abort.signal),
      fetchAll<Order>(`/rest/v1/orders?store_id=eq.${store.id}&select=id,user_id,total_price,currency,status&user_id=not.is.null&order=id`, token, abort.signal),
    ]).then(([nextCustomers, nextOrders]) => { setCustomers(nextCustomers); setOrders(nextOrders) }).catch(cause => { if (!abort.signal.aborted) setError(cause.message) })
    return () => abort.abort()
  }, [store, token])
  const rows = customers.filter(customer => !search || `${customer.profiles?.name ?? ''} ${customer.profiles?.phone ?? ''}`.toLowerCase().includes(search.toLowerCase())).map(customer => {
    const own = orders.filter(order => order.user_id === customer.user_id && !order.status.startsWith('CANCELLED'))
    const amounts = [...new Set(own.map(order => order.currency))].map(currency => formatPrice(own.filter(order => order.currency === currency).reduce((sum, order) => sum + Number(order.total_price), 0) / 100, currency)).join(' · ')
    return { ...customer, count: own.length, amounts }
  })
  const pages = Math.max(1, Math.ceil(rows.length / 20))
  const current = Math.min(page, pages)
  return <section className="customers-page">{error && <p className="error">{error}</p>}<div className="crm-stats"><div><span>{t('Registered')}</span><strong>{customers.length}</strong></div><div><span>{t('New, 30 days')}</span><strong>{customers.filter(item => now - new Date(item.joined_at).getTime() < 30 * 864e5).length}</strong></div><div><span>{t('No orders yet')}</span><strong>{customers.filter(customer => !orders.some(order => order.user_id === customer.user_id)).length}</strong></div></div>
    <section className="crm-panel"><h2>{t('Registered customers')}</h2><div className="customers-toolbar"><input aria-label={t('Search customers')} placeholder={t('Search customers')} value={search} onChange={event => { setSearch(event.target.value); setPage(1) }} />
      <button className="text-btn" disabled={!rows.length} onClick={() => downloadCsv('tatami-customers.csv', [[t('Name'), t('Phone'), t('joined'), t('Orders'), t('Total')], ...rows.map(row => [row.profiles?.name, row.profiles?.phone, row.joined_at, row.count, row.amounts])])}>{t('Export CSV')}</button></div>
      <ul className="customers-list">{rows.slice((current - 1) * 20, current * 20).map(customer => <li key={customer.user_id}><div><strong>{customer.profiles?.name || t('Customer')}</strong><span>{customer.profiles?.phone || '—'} · {t('joined')} {formatDate(customer.joined_at)}</span></div><span>{customer.count} {t('orders')}</span><strong>{customer.amounts || '—'}</strong></li>)}</ul>
      {!rows.length ? <p className="muted">{t('No customers match this search.')}</p> : null}
      <div className="crm-pagination"><button className="text-btn" disabled={current === 1} onClick={() => setPage(current - 1)}>{t('Previous')}</button><span>{current} / {pages}</span><button className="text-btn" disabled={current === pages} onClick={() => setPage(current + 1)}>{t('Next')}</button></div>
    </section></section>
}
