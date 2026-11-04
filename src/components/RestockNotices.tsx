import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { supabaseRequest } from '../lib/supabase'

type Notice = { variant_id: string; product_variants: { name: string; product_id: string; products: { name: string } } }
export function RestockNotices({ token, userId, storeId, onCount, onOpen }: { token: string; userId: string; storeId: string; onCount: (count: number) => void; onOpen: () => void }) {
  const { t } = useTranslation()
  const [notices, setNotices] = useState<Notice[]>([])
  const [error, setError] = useState('')
  useEffect(() => {
    const abort = new AbortController()
    const refresh = () => supabaseRequest<Notice[]>(`/rest/v1/restock_subscriptions?user_id=eq.${userId}&notified_at=not.is.null&select=variant_id,product_variants!inner(name,product_id,products!inner(name,store_id))&product_variants.products.store_id=eq.${storeId}&order=notified_at.desc&limit=50`, { token, signal: abort.signal }).then(rows => { setNotices(rows); onCount(rows.length) }).catch(cause => { if (!abort.signal.aborted) setError(cause.message) })
    void refresh()
    const timer = window.setInterval(() => void refresh(), 30000)
    return () => { abort.abort(); window.clearInterval(timer) }
  }, [token, userId, storeId, onCount])
  return <section>
    {error && <p className="error">{error}</p>}
    {notices.length > 0 && <h3>{t('Back in stock')}</h3>}
    {notices.map(notice => <p key={notice.variant_id}>
      <Link onClick={onOpen} to={`/product/${notice.product_variants.product_id}`}>{notice.product_variants.products.name} · {notice.product_variants.name}</Link>
      <button className="text-btn" onClick={async () => {
        try {
          await supabaseRequest('/rest/v1/rpc/subscribe_restock', { method: 'POST', token, body: JSON.stringify({ p_variant: notice.variant_id, p_subscribe: false }) })
          const remaining = notices.filter(row => row.variant_id !== notice.variant_id)
          setNotices(remaining)
          onCount(remaining.length)
        } catch (cause) { setError(cause instanceof Error ? cause.message : t('Action failed')) }
      }}>{t('Mark as read')}</button>
    </p>)}
  </section>
}
