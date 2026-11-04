import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { supabaseRequest } from '../lib/supabase'

export function VariantCostEditor({ variantId, token }: { variantId: string; token: string }) {
  const { t } = useTranslation()
  const [amount, setAmount] = useState('')
  const [message, setMessage] = useState('')
  const [busy, setBusy] = useState(false)
  useEffect(() => {
    const abort = new AbortController()
    supabaseRequest<Array<{ cost_amount: number }>>(`/rest/v1/variant_costs?variant_id=eq.${variantId}&select=cost_amount`, { token, signal: abort.signal })
      .then(rows => setAmount(rows[0] ? String(rows[0].cost_amount / 100) : ''))
      .catch(cause => { if (!abort.signal.aborted) setMessage(cause.message) })
    return () => abort.abort()
  }, [variantId, token])
  return <form className="inline-form" onSubmit={async event => {
    event.preventDefault()
    if (busy) return
    const minor = Math.round(Number(amount) * 100)
    if (!amount.trim() || !Number.isSafeInteger(minor) || minor < 0) return
    setBusy(true)
    setMessage('')
    try {
      await supabaseRequest('/rest/v1/variant_costs?on_conflict=variant_id', { method: 'POST', token, headers: { Prefer: 'resolution=merge-duplicates' }, body: JSON.stringify({ variant_id: variantId, cost_amount: minor }) })
      setMessage(t('Saved'))
    } catch (cause) { setMessage(cause instanceof Error ? cause.message : t('Action failed')) } finally { setBusy(false) }
  }}>
    <label className="field">{t('Unit cost, UAH')}<input required type="number" min="0" step="0.01" value={amount} onChange={event => setAmount(event.target.value)} /></label>
    <button className="text-btn" disabled={busy}>{t('Save')}</button>
    {message && <p role="status">{message}</p>}
  </form>
}
