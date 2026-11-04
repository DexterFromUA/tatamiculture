import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { supabaseConfigured, supabaseRequest } from '../lib/supabase'
import { formatDate, formatPrice } from '../lib/format'

type Event = { id: string; kind: string; old_value: string | null; new_value: string | null; created_at: string; author_id?: string | null }
export function OrderActivity({ orderId, token, receiptCode, currency = 'UAH' }: { orderId?: string; token?: string; receiptCode?: string; currency?: string }) {
  const { t } = useTranslation()
  const [events, setEvents] = useState<Event[]>([])
  const [error, setError] = useState('')
  useEffect(() => {
    if (!supabaseConfigured) return
    const abort = new AbortController()
    const request = receiptCode
      ? supabaseRequest<Event[]>('/rest/v1/rpc/receipt_events', { method: 'POST', body: JSON.stringify({ p_code: receiptCode }), signal: abort.signal })
      : supabaseRequest<Event[]>(`/rest/v1/order_events?order_id=eq.${encodeURIComponent(orderId ?? '')}&select=id,kind,old_value,new_value,created_at,author_id&order=created_at.desc`, { token, signal: abort.signal })
    request.then(setEvents).catch(cause => { if (!abort.signal.aborted) setError(cause.message) })
    return () => abort.abort()
  }, [orderId, token, receiptCode])
  if (!supabaseConfigured) return null
  const value = (event: Event, raw: string) => event.kind === 'cost' || event.kind === 'return' ? formatPrice(Number(raw) / 100, currency) : event.kind === 'item_return' ? t(`return_${raw}`) : t(raw)
  return <section className="crm-panel"><h3>{t('Order activity')}</h3>{error ? <p className="error">{error}</p> : events.length === 0 ? <p>{t('No events yet')}</p> : <ul>{events.map(event => <li key={event.id}><time dateTime={event.created_at}>{formatDate(event.created_at)} {new Date(event.created_at).toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' })}</time> · {t(`event_${event.kind}`)}: {event.old_value !== null && <>{value(event, event.old_value)} → </>}{value(event, event.new_value ?? '')}{!receiptCode && <small> · {event.author_id ?? t('System')}</small>}</li>)}</ul>}</section>
}
