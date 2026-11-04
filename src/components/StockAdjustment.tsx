import { useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { supabaseRequest } from '../lib/supabase'

type Movement = {
  id: number
  kind: string
  reason: string | null
  previous_quantity: number
  quantity: number
  author_id: string | null
  created_at: string
}

export function StockAdjustment({ variantId, token, reload }: {
  variantId: string
  token: string
  reload: () => Promise<void>
}) {
  const { t, i18n } = useTranslation()
  const requestId = useRef(crypto.randomUUID())
  const [kind, setKind] = useState('receipt')
  const [history, setHistory] = useState<Movement[] | null>(null)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const loadHistory = async () => {
    setHistory(await supabaseRequest<Movement[]>(
      `/rest/v1/stock_movements?variant_id=eq.${encodeURIComponent(variantId)}&order=id.desc&limit=30`,
      { token },
    ))
  }
  return <details className="stock-adjustment">
    <summary>{t('Stock operations')}</summary>
    <form className="form" onSubmit={async event => {
      event.preventDefault()
      if (busy) return
      const form = event.currentTarget
      const fields = new FormData(form)
      setBusy(true)
      setMessage('')
      try {
        await supabaseRequest('/rest/v1/rpc/adjust_catalog_stock', {
          method: 'POST', token, body: JSON.stringify({
            p_variant: variantId, p_kind: kind, p_request: requestId.current,
            p_quantity: Number(fields.get('quantity')), p_reason: fields.get('reason'),
          }),
        })
        requestId.current = crypto.randomUUID()
        form.reset()
        setMessage(t('Stock updated'))
        await reload()
        await loadHistory()
      } catch (cause) {
        setMessage(cause instanceof Error ? cause.message : t('Stock update failed'))
      } finally {
        setBusy(false)
      }
    }}>
      <label className="field">{t('Operation')}<select value={kind} onChange={event => setKind(event.target.value)}>
        <option value="receipt">{t('Stock receipt')}</option>
        <option value="writeoff">{t('Stock write-off')}</option>
        <option value="correction">{t('Stock correction')}</option>
      </select></label>
      <label className="field">{t(kind === 'correction' ? 'New stock quantity' : 'Quantity')}<input required name="quantity" type="number" min={kind === 'correction' ? 0 : 1} step={1} /></label>
      <label className="field">{t('Reason')}<input required name="reason" maxLength={500} /></label>
      <button type="submit" className="btn" disabled={busy}>{t('Save')}</button>
    </form>
    <button type="button" className="text-btn" onClick={() => void loadHistory().catch(cause => setMessage(cause.message))}>{t('Stock history')}</button>
    <p role="status">{message}</p>
    {history && (history.length ? <ol>{history.map(row => <li key={row.id}>
      {new Date(row.created_at).toLocaleString(i18n.language)} · {row.previous_quantity} → {row.quantity}
      {row.reason && ` · ${row.reason}`}{row.author_id && ` · ${row.author_id}`}
    </li>)}</ol> : <p>{t('No stock movements yet')}</p>)}
  </details>
}
