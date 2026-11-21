import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { supabaseRequest } from '../lib/supabase'
import { formatPrice } from '../lib/format'

type Review = { receipt_code: string; provider: string; bank_reference: string | null; total_price: number; currency: string; reason: string }

export function PaymentReviewList({ storeId, token, revision }: { storeId: string; token: string; revision: number }) {
  const { t } = useTranslation()
  const [rows, setRows] = useState<Review[]>([])
  const [error, setError] = useState(false)
  useEffect(() => {
    const abort = new AbortController()
    void supabaseRequest<Review[]>('/rest/v1/rpc/payment_reviews', { method: 'POST', token,
      signal: abort.signal, body: JSON.stringify({ p_store: storeId }) })
      .then(result => { if (!abort.signal.aborted) { setRows(result); setError(false) } })
      .catch(() => { if (!abort.signal.aborted) setError(true) })
    return () => abort.abort()
  }, [storeId, token, revision])
  if (error) return <p className="error">{t('Could not load payments requiring review')}</p>
  if (!rows.length) return null
  return <section className="crm-panel">
    <h3>{t('Payments requiring bank review')}</h3>
    <ul>{rows.map(row => <li key={row.receipt_code}>
      <strong>#{row.receipt_code}</strong> · {row.provider} · {formatPrice(row.total_price / 100, row.currency)}
      {row.bank_reference && <> · {row.bank_reference}</>} · {t(row.reason)}
    </li>)}</ul>
  </section>
}
