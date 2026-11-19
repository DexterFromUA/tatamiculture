import { useEffect, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { supabaseRequest } from '../lib/supabase'

type Account = { user_id: string; email: string | null }
type Discount = {
  id: string; user_id: string; percent: number; mode: 'unlimited' | 'orders' | 'period'
  order_limit: number | null; starts_on: string | null; ends_on: string | null
}

export function CustomerDiscountEditor({ storeId, customerId, token, onSaved }: {
  storeId: string; customerId: string; token: string; onSaved: () => void
}) {
  const { t } = useTranslation()
  const [accounts, setAccounts] = useState<Account[]>([])
  const [discounts, setDiscounts] = useState<Discount[]>([])
  const [selected, setSelected] = useState('')
  const [percent, setPercent] = useState('')
  const [mode, setMode] = useState<Discount['mode']>('unlimited')
  const [limit, setLimit] = useState('1')
  const [start, setStart] = useState('')
  const [end, setEnd] = useState('')
  const [loading, setLoading] = useState(true)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [saved, setSaved] = useState(false)
  const [used, setUsed] = useState<number | null>(null)
  const [revision, setRevision] = useState(0)
  const accountId = selected || accounts[0]?.user_id
  const discount = discounts.find(item => item.user_id === accountId)

  useEffect(() => {
    const abort = new AbortController()
    setLoading(true)
    void supabaseRequest<Account[]>('/rest/v1/rpc/crm_customer_accounts', {
      method: 'POST', token, signal: abort.signal,
      body: JSON.stringify({ p_store_id: storeId, p_customer_id: customerId }),
    }).then(async rows => {
      const values = rows.length ? await supabaseRequest<Discount[]>(
        `/rest/v1/customer_discounts?store_id=eq.${storeId}&user_id=in.(${rows.map(row => row.user_id).join(',')})&enabled=eq.true&select=*`,
        { token, signal: abort.signal },
      ) : []
      if (!abort.signal.aborted) { setAccounts(rows); setDiscounts(values) }
    }).catch(cause => { if (!abort.signal.aborted) setError(cause.message) })
      .finally(() => { if (!abort.signal.aborted) setLoading(false) })
    return () => abort.abort()
  }, [storeId, customerId, token, revision])

  useEffect(() => {
    setPercent(discount ? String(discount.percent) : '')
    setMode(discount?.mode ?? 'unlimited')
    setLimit(String(discount?.order_limit ?? 1))
    setStart(discount?.starts_on ?? '')
    setEnd(discount?.ends_on ?? '')
  }, [discount])

  useEffect(() => {
    setUsed(null)
    if (!discount) return
    const abort = new AbortController()
    void supabaseRequest<number>('/rest/v1/rpc/crm_customer_discount_usage', {
      method: 'POST', token, signal: abort.signal, body: JSON.stringify({ p_discount_id: discount.id }),
    }).then(value => { if (!abort.signal.aborted) setUsed(value) })
      .catch(cause => { if (!abort.signal.aborted) setError(cause.message) })
    return () => abort.abort()
  }, [discount, token])

  const save = async (event?: FormEvent, remove = false) => {
    event?.preventDefault()
    if (busy || !accountId) return
    setBusy(true)
    setError('')
    setSaved(false)
    try {
      await supabaseRequest('/rest/v1/rpc/set_customer_discount', {
        method: 'POST', token, body: JSON.stringify({
          p_store_id: storeId, p_customer_id: customerId, p_user_id: accountId,
          p_percent: remove ? null : Number(percent), p_mode: mode,
          p_order_limit: mode === 'orders' ? Number(limit) : null,
          p_starts_on: mode === 'period' ? start : null, p_ends_on: mode === 'period' ? end : null,
        }),
      })
      setSaved(true)
      setRevision(value => value + 1)
      onSaved()
    } catch (cause) { setError(cause instanceof Error ? cause.message : t('Action failed')) }
    finally { setBusy(false) }
  }

  return <section className="customer-discount">
    <div className="customer-discount__heading"><h3>{t('Personal discount')}</h3>{discount && <strong>{discount.percent}%</strong>}</div>
    {error && <p className="error" role="alert">{t(error)}</p>}
    {loading ? <p className="muted">{t('Loading…')}</p> : !accounts.length
      ? <p className="muted">{t('Personal discounts are available to registered customers.')}</p>
      : <form onSubmit={event => void save(event)}>
        <fieldset disabled={busy}>
          {accounts.length > 1 && <label className="field">{t('Customer account')}<select value={accountId} onChange={event => { setSelected(event.target.value); setSaved(false) }}>
            {accounts.map(account => <option key={account.user_id} value={account.user_id}>{account.email || account.user_id}</option>)}
          </select></label>}
          <label className="field">{t('Discount, %')}<input type="number" min="0.01" max="100" step="0.01" required value={percent} placeholder="10" onChange={event => { setPercent(event.target.value); setSaved(false) }} /></label>
          <div className="customer-discount__modes" role="group" aria-label={t('Discount duration')}>
            {(['unlimited', 'orders', 'period'] as const).map(value => <button type="button" key={value} aria-pressed={mode === value}
              className={mode === value ? 'active' : ''} onClick={() => { setMode(value); setSaved(false) }}>
              {t({ unlimited: 'Indefinitely', orders: 'Number of orders', period: 'Date range' }[value])}
            </button>)}
          </div>
          {mode === 'orders' && <label className="field">{t('Discounted orders')}<input type="number" min="1" max="2147483647" step="1" required value={limit} onChange={event => { setLimit(event.target.value); setSaved(false) }} /></label>}
          {mode === 'period' && <div className="customer-discount__dates">
            <label className="field">{t('Valid from')}<input type="date" required value={start} max={end || undefined} onChange={event => { setStart(event.target.value); setSaved(false) }} /></label>
            <label className="field">{t('Valid through')}<input type="date" required value={end} min={start || undefined} onChange={event => { setEnd(event.target.value); setSaved(false) }} /></label>
          </div>}
          <p className="customer-discount__hint">{t('Applied automatically to current product prices. Cancelled orders restore a use. Dates follow Kyiv time.')}</p>
          {discount?.mode === 'orders' && used !== null && <p className="customer-discount__hint">{t('Used or awaiting payment: {{used}} of {{limit}}', { used, limit: discount.order_limit })}</p>}
          {discount && mode === 'orders' && <p className="customer-discount__hint">{t('Saving starts a new order allowance.')}</p>}
          <div className="actions"><button className="btn" type="submit">{t(busy ? 'Saving…' : 'Save discount')}</button>
            {discount && <button className="text-btn" type="button" onClick={() => void save(undefined, true)}>{t('Remove discount')}</button>}
          </div>
        </fieldset>
        {saved && <p role="status">{t('Discount saved')}</p>}
      </form>}
  </section>
}
