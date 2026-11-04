import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { supabaseConfigured, supabaseRequest } from '../lib/supabase'

export function RestockSubscription({ variantId }: { variantId: string }) {
  const { t } = useTranslation()
  const { token, user } = useAuth()
  const [subscribed, setSubscribed] = useState(false)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  useEffect(() => {
    if (!token || !user || !supabaseConfigured) return
    const abort = new AbortController()
    supabaseRequest<unknown[]>(`/rest/v1/restock_subscriptions?user_id=eq.${user.id}&variant_id=eq.${variantId}&notified_at=is.null&select=variant_id`, { token, signal: abort.signal })
      .then(rows => setSubscribed(rows.length > 0)).catch(cause => { if (!abort.signal.aborted) setMessage(cause.message) })
    return () => abort.abort()
  }, [token, user, variantId])
  if (!supabaseConfigured) return null
  if (!token) return <Link to="/login">{t('Sign in to get a restock notification')}</Link>
  return <div className="customer-section">
    <p>{t('We will notify you in your account when this size is back in stock.')}</p>
    <button className="btn btn--ghost" disabled={busy} onClick={async () => {
      if (busy) return
      setBusy(true)
      setMessage('')
      try {
        await supabaseRequest('/rest/v1/rpc/subscribe_restock', { method: 'POST', token, body: JSON.stringify({ p_variant: variantId, p_subscribe: !subscribed }) })
        setSubscribed(!subscribed)
      } catch (cause) { setMessage(cause instanceof Error ? cause.message : t('Action failed')) } finally { setBusy(false) }
    }}>{t(subscribed ? 'Cancel restock notification' : 'Notify me when available')}</button>
    {message && <p role="status">{message}</p>}
  </div>
}
