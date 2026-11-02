import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { supabaseConfigured, supabaseRequest } from '../lib/supabase'
import { formatDate, formatPrice } from '../lib/format'

type Notice = { id: string; receipt_code: string; kind: string; value: string; read_at: string | null; created_at: string; orders: { currency: string } | null }
export function Notifications() {
  const { t } = useTranslation()
  const { token } = useAuth()
  const { store } = useStore()
  const [items, setItems] = useState<Notice[]>([])
  const [error, setError] = useState('')
  useEffect(() => {
    if (!token || !store || !supabaseConfigured) return
    const abort = new AbortController()
    const refresh = () => { void supabaseRequest<Notice[]>(`/rest/v1/customer_notifications?store_id=eq.${store.id}&select=id,receipt_code,kind,value,read_at,created_at,orders(currency)&order=created_at.desc&limit=50`, { token, signal: abort.signal }).then(setItems).catch(cause => { if (!abort.signal.aborted) setError(cause.message) }) }
    refresh()
    const timer = window.setInterval(refresh, 30000)
    return () => { abort.abort(); window.clearInterval(timer) }
  }, [store, token])
  if (!supabaseConfigured) return null
  const read = async (id: string) => {
    try {
      await supabaseRequest('/rest/v1/rpc/mark_notification_read', { method: 'POST', token, body: JSON.stringify({ p_id: id }) })
      setItems(current => current.map(item => item.id === id ? { ...item, read_at: new Date().toISOString() } : item))
    } catch (cause) { setError(cause instanceof Error ? cause.message : t('Action failed')) }
  }
  return <section className="account-card"><h2>{t('Notifications')} ({items.filter(item => !item.read_at).length})</h2><small>{t('Latest 50 notifications')}</small>{error && <p className="error">{error}</p>}{!items.length && <p>{t('No notifications yet')}</p>}<ul>{items.map(item => <li key={item.id}><Link to={`/receipt/${item.receipt_code}`}>{item.receipt_code}</Link> · {t(`event_${item.kind}`)}: {item.kind === 'return' ? formatPrice(Number(item.value) / 100, item.orders?.currency ?? store?.currency ?? 'UAH') : t(item.value)} <small>{formatDate(item.created_at)}</small> {!item.read_at && <button className="text-btn" onClick={() => void read(item.id)}>{t('Mark as read')}</button>}</li>)}</ul></section>
}
