import { useEffect, useRef, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { supabaseConfigured, supabaseRequest } from '../lib/supabase'
import { formatDate, formatPrice } from '../lib/format'

type Notice = { id: string; receipt_code: string; kind: string; value: string; read_at: string | null; created_at: string; orders: { currency: string } | null }
type RestockNotice = { variant_id: string; notified_at: string; product_variants: { name: string; product_id: string; products: { name: string } } }

export function Notifications() {
  const { t } = useTranslation()
  const { token, user } = useAuth()
  const { store } = useStore()
  const [items, setItems] = useState<Notice[]>([])
  const [restocks, setRestocks] = useState<RestockNotice[]>([])
  const [pending, setPending] = useState(false)
  const [error, setError] = useState('')
  const dialogRef = useRef<HTMLDialogElement>(null)
  const storeId = store?.id
  const userId = user?.id

  useEffect(() => {
    if (!token || !storeId || !userId || !supabaseConfigured || pending) return
    const abort = new AbortController()
    const refresh = () => {
      const options = { token, signal: abort.signal }
      void supabaseRequest<Notice[]>(`/rest/v1/customer_notifications?store_id=eq.${storeId}&select=id,receipt_code,kind,value,read_at,created_at,orders(currency)&order=created_at.desc&limit=50`, options)
        .then(rows => { if (!abort.signal.aborted) setItems(rows) })
        .catch(cause => { if (!abort.signal.aborted) setError(cause.message) })
      void supabaseRequest<RestockNotice[]>(`/rest/v1/restock_subscriptions?user_id=eq.${userId}&notified_at=not.is.null&select=variant_id,notified_at,product_variants!inner(name,product_id,products!inner(name,store_id))&product_variants.products.store_id=eq.${storeId}&order=notified_at.desc&limit=50`, options)
        .then(rows => { if (!abort.signal.aborted) setRestocks(rows) })
        .catch(cause => { if (!abort.signal.aborted) setError(cause.message) })
    }
    refresh()
    const timer = window.setInterval(refresh, 30000)
    return () => { abort.abort(); window.clearInterval(timer) }
  }, [storeId, userId, token, pending])

  const updateRead = async (rpc: string, body: Record<string, unknown>, onSuccess: () => void) => {
    if (!token || pending) return
    setPending(true)
    setError('')
    try {
      await supabaseRequest(`/rest/v1/rpc/${rpc}`, { method: 'POST', token, body: JSON.stringify(body) })
      onSuccess()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('Action failed'))
    } finally {
      setPending(false)
    }
  }

  const read = (id?: string) => updateRead(
    id ? 'mark_notification_read' : 'mark_all_notifications_read',
    id ? { p_id: id } : { p_store_id: storeId },
    () => {
      const readAt = new Date().toISOString()
      setItems(current => current.map(item => !item.read_at && (!id || item.id === id) ? { ...item, read_at: readAt } : item))
      if (!id) setRestocks([])
    },
  )

  const unread = items.filter(item => !item.read_at).length + restocks.length
  const close = () => dialogRef.current?.close()

  return <>
    <button type="button" className="notification-bell" aria-haspopup="dialog" aria-label={`${t('Notifications')}: ${unread}`} title={t('Notifications')} onClick={() => dialogRef.current?.showModal()}>
      <svg viewBox="0 0 24 24" width="22" height="22" fill="none" stroke="currentColor" strokeWidth="1.8" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d="M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9ZM10 21h4" /></svg>
      {unread > 0 && <span className="notification-bell__count">{unread > 99 ? '99+' : unread}</span>}
    </button>
    <dialog ref={dialogRef} className="order-drawer notifications-drawer" aria-labelledby="notification-dialog-title"
      onClick={event => { if (event.target === event.currentTarget) close() }}>
      <header className="order-drawer__header">
        <div className="order-drawer__identity">
          <span className="order-drawer__eyebrow">{store?.name}</span>
          <h2 id="notification-dialog-title">{t('Notifications')}</h2>
        </div>
        <button type="button" className="btn btn--ghost" onClick={close} autoFocus>{t('Close')}</button>
        <button type="button" className="btn btn--ghost notifications-drawer__read-all" disabled={pending || !storeId || !token || (!items.length && !restocks.length)} onClick={() => void read()}>
          {t('Mark all as read')}
        </button>
      </header>
      <div className="order-drawer__body" aria-busy={pending}>
        {error && <p className="error" role="alert">{error}</p>}
        {!items.length && !restocks.length && !error && <p className="order-drawer__card muted">{t('No notifications yet')}</p>}
        <ul className="notifications-drawer__list">
          {restocks.map(notice => <li key={notice.variant_id} className="order-drawer__card notifications-drawer__unread">
            <div className="notifications-drawer__meta">
              <Link onClick={close} to={`/product/${notice.product_variants.product_id}`}>{notice.product_variants.products.name} · {notice.product_variants.name}</Link>
              <small>{formatDate(notice.notified_at)}</small>
            </div>
            <p>{t('Back in stock')}</p>
            <button type="button" className="text-btn" disabled={pending} onClick={() => void updateRead('subscribe_restock', { p_variant: notice.variant_id, p_subscribe: false }, () => setRestocks(current => current.filter(row => row.variant_id !== notice.variant_id)))}>{t('Mark as read')}</button>
          </li>)}
          {items.map(item => <li key={item.id} className={`order-drawer__card${item.read_at ? '' : ' notifications-drawer__unread'}`}>
            <div className="notifications-drawer__meta">
              <Link to={`/receipt/${item.receipt_code}`} onClick={close}>{item.receipt_code}</Link>
              <small>{formatDate(item.created_at)}</small>
            </div>
            <p>{t(`event_${item.kind}`)}: {item.kind === 'return' ? formatPrice(Number(item.value) / 100, item.orders?.currency ?? store?.currency ?? 'UAH') : t(item.value)}</p>
            {!item.read_at && <button type="button" className="text-btn" disabled={pending} onClick={() => void read(item.id)}>{t('Mark as read')}</button>}
          </li>)}
        </ul>
      </div>
    </dialog>
  </>
}
