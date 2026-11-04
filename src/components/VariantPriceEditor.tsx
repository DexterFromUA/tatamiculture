import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { supabaseRequest } from '../lib/supabase'

export function VariantPriceEditor({ id, price, compareAtPrice, token, onSaved }: {
  id: string
  price: number
  compareAtPrice: number | null
  token: string
  onSaved: () => Promise<void>
}) {
  const { t } = useTranslation()
  const [amount, setAmount] = useState(String(price / 100))
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  return <form className="inline-form" onSubmit={async event => {
    event.preventDefault()
    if (busy) return
    const minor = Math.round(Number(amount) * 100)
    if (!amount.trim() || !Number.isSafeInteger(minor) || minor < 0) return
    setBusy(true)
    setError('')
    try {
      await supabaseRequest(`/rest/v1/product_variants?id=eq.${encodeURIComponent(id)}&price=eq.${price}`, {
        method: 'PATCH', token, headers: { Prefer: 'return=representation' },
        body: JSON.stringify({ price: minor, compare_at_price: compareAtPrice !== null && compareAtPrice < minor ? null : compareAtPrice }),
      }).then(result => {
        if (!Array.isArray(result) || result.length !== 1) throw new Error(t('Price changed. Refresh and try again.'))
      })
      await onSaved()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('Could not save product'))
    } finally {
      setBusy(false)
    }
  }}>
    <label className="field">{t('Price, UAH')}<input required type="number" min="0" step="0.01" value={amount} onChange={event => setAmount(event.target.value)} /></label>
    <button className="text-btn" disabled={busy || Number(amount) * 100 === price}>{t('Save')}</button>
    {error && <p className="error" role="alert">{error}</p>}
  </form>
}
