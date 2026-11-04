import { useEffect, useRef, useState } from 'react'
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
  const dialogRef = useRef<HTMLDialogElement>(null)
  useEffect(() => {
    if (!token || !store || !supabaseConfigured) return
    const abort = new AbortController()
    const refresh = () => { void supabaseRequest<Notice[]>(`/rest/v1/customer_notifications?store_id=eq.${store.id}&select=id,receipt_code,kind,value,read_at,created_at,orders(currency)&order=created_at.desc&limit=50`, { token, signal: abort.signal }).then(setItems).catch(cause => { if (!abort.signal.aborted) setError(cause.message) }) }
    refresh()
    const timer = window.setInterval(refresh, 30000)
    return () => { abort.abort(); window.clearInterval(timer) }
  }, [store, token])
  const read = async (id: string) => {
    try {
      await supabaseRequest('/rest/v1/rpc/mark_notification_read', { method: 'POST', token, body: JSON.stringify({ p_id: id }) })
      setItems(current => current.map(item => item.id === id ? { ...item, read_at: new Date().toISOString() } : item))
    } catch (cause) { setError(cause instanceof Error ? cause.message : t('Action failed')) }
  }
  const unread = items.filter(item => !item.read_at).length

  return <>
    <button type="button" className="notification-bell" aria-label={`${t('Notifications')}: ${unread}`} title={t('Notifications')} onClick={() => dialogRef.current?.showModal()}>
      <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9ZM10 21h4" /></svg>
      {unread > 0 ? <span className="notification-bell__count">{unread > 99 ? '99+' : unread}</span> : null}
    </button>
    <dialog ref={dialogRef} className="notification-dialog" aria-labelledby="notification-dialog-title">
      <div className="notification-dialog__head"><div><h2 id="notification-dialog-title">{t('Notifications')}</h2><small>{t('Latest 50 notifications')}</small></div><button type="button" className="text-btn" onClick={() => dialogRef.current?.close()}>{t('Close')}</button></div>
      {error ? <p className="error">{error}</p> : null}
      {!items.length ? <p className="muted">{t('No notifications yet')}</p> : <ul className="notification-dialog__list">{items.map(item => <li key={item.id} className={item.read_at ? '' : 'notification-dialog__unread'}>
        <div><Link to={`/receipt/${item.receipt_code}`} onClick={() => dialogRef.current?.close()}>{item.receipt_code}</Link><small>{formatDate(item.created_at)}</small></div>
        <p>{t(`event_${item.kind}`)}: {item.kind === 'return' ? formatPrice(Number(item.value) / 100, item.orders?.currency ?? store?.currency ?? 'UAH') : t(item.value)}</p>
        {!item.read_at ? <button type="button" className="text-btn" onClick={() => void read(item.id)}>{t('Mark as read')}</button> : null}
      </li>)}</ul>}
    </dialog>
  </>
}
