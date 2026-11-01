import { useEffect, useMemo, useState } from 'react'
import { formatDate, formatPrice } from '../lib/format'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { supabaseRequest } from '../lib/supabase'
import { useTranslation } from 'react-i18next'

type Customer = { user_id: string; joined_at: string; profiles: { name: string; phone: string; created_at: string } | null }
type Order = { user_id: string; total_price: number; status: string }
export function CustomersPage() {
  const { store } = useStore(); const { token } = useAuth(); const [customers, setCustomers] = useState<Customer[]>([]); const [orders, setOrders] = useState<Order[]>([]); const [error, setError] = useState<string | null>(null)
  const { t } = useTranslation()
  useEffect(() => { if (!store || !token) return; void Promise.all([supabaseRequest<Customer[]>(`/rest/v1/store_customers?store_id=eq.${encodeURIComponent(store.id)}&select=user_id,joined_at,profiles(name,phone,created_at)&order=joined_at.desc`, { token }), supabaseRequest<Order[]>(`/rest/v1/orders?store_id=eq.${encodeURIComponent(store.id)}&select=user_id,total_price,status&user_id=not.is.null`, { token })]).then(([nextCustomers, nextOrders]) => { setCustomers(nextCustomers); setOrders(nextOrders) }).catch((cause) => setError(cause instanceof Error ? cause.message : 'Could not load customers')) }, [store, token])
  const stats = useMemo(() => ({ new30: customers.filter((item) => Date.now() - new Date(item.joined_at).getTime() < 30 * 864e5).length, noOrders: customers.filter((customer) => !orders.some((order) => order.user_id === customer.user_id)).length }), [customers, orders])
  if (error) return <p className="error">{error}</p>
  return <section><div className="crm-stats"><div><span>{t('Registered')}</span><strong>{customers.length}</strong></div><div><span>{t('New, 30 days')}</span><strong>{stats.new30}</strong></div><div><span>{t('No orders yet')}</span><strong>{stats.noOrders}</strong></div></div><section className="crm-panel"><h2>{t('Registered customers')}</h2><ul className="customers-list">{customers.map((customer) => { const ownOrders = orders.filter((order) => order.user_id === customer.user_id && !order.status.startsWith('CANCELLED')); const spent = ownOrders.reduce((sum, order) => sum + Number(order.total_price), 0) / 100; return <li key={customer.user_id}><div><strong>{customer.profiles?.name || t('Customer')}</strong><span>{customer.profiles?.phone || '—'} · {t('joined')} {formatDate(customer.joined_at)}</span></div><span>{ownOrders.length} {t('orders')}</span><strong>{formatPrice(spent, store?.currency ?? 'UAH')}</strong></li> })}</ul></section></section>
}
