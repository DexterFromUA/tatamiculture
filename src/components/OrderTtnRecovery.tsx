import { useId, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { resolveTtnAttempt, type TtnAttempt } from '../lib/ttn'
import { ConfirmationDialog } from './ConfirmationDialog'

export function OrderTtnRecovery({ attempt, orderId, token, onResolved, onRefresh }: {
  attempt?: TtnAttempt | null
  orderId: string
  token: string
  onResolved: (ttn: string | null) => void
  onRefresh: () => void
}) {
  const { t } = useTranslation()
  const busyHintId = useId()
  const [mode, setMode] = useState<'attach' | 'not_created' | null>(null)
  const [number, setNumber] = useState('')
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')

  const resolve = async (action: 'attach' | 'not_created', ttn?: string) => {
    if (busy) return
    setBusy(true)
    setError('')
    try {
      const result = await resolveTtnAttempt(orderId, token, { action, attemptId: attempt?.id, ttn })
      onResolved(result.ttn)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not resolve the TTN.')
      onRefresh()
    } finally {
      setBusy(false)
    }
  }
  const attach = (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    const ttn = number.replace(/\s/g, '')
    if (!/^\d{14}$/.test(ttn)) {
      setError('Enter a valid 14-digit Nova Poshta tracking number.')
      return
    }
    void resolve('attach', ttn)
  }
  if (attempt?.state === 'creating') return <div>
    <h3>{t('Creating TTN…')}</h3>
    <p>{t('The previous request is still running. Check its status in a moment.')}</p>
    <button className="text-btn" type="button" onClick={onRefresh}>{t('Update status')}</button>
  </div>

  return <div>
    {attempt && <>
      <h3>{t('Verify the TTN')}</h3>
      <p>{t('Check whether this order already has a waybill in the Nova Poshta business account.')}</p>
    </>}
    {error && <p className="error" role="alert">{t(error)}</p>}
    {mode === 'attach' ? <form className="form" onSubmit={attach}>
      <label className="field">
        <span>{t('Nova Poshta tracking number')}</span>
        <input value={number} onChange={event => setNumber(event.target.value)} required inputMode="numeric"
          autoComplete="off" disabled={busy} />
      </label>
      <div className="actions">
        <button className="btn btn--ghost" type="button" disabled={busy} onClick={() => { setMode(null); setError('') }}>{t('Cancel')}</button>
        <button className="btn" type="submit" disabled={busy} aria-describedby={busy ? busyHintId : undefined}>{t('Link existing TTN')}</button>
      </div>
    </form> : <div className="actions">
      <button type="button" className="btn btn--ghost" disabled={busy} aria-describedby={busy ? busyHintId : undefined}
        onClick={() => { setMode('attach'); setError('') }}>
        {t(attempt ? 'Link existing TTN' : 'Add TTN')}
      </button>
      {attempt && <button type="button" className="btn btn--ghost" disabled={busy} aria-describedby={busy ? busyHintId : undefined}
        onClick={() => { setMode('not_created'); setError('') }}>
        {t('Confirm TTN was not created')}
      </button>}
    </div>}
    {busy && <p id={busyHintId} className="order-action__hint" role="status">{t('A TTN request is being processed.')}</p>}
    {mode === 'not_created' && <ConfirmationDialog
      title={t('Confirm TTN was not created')}
      message={t('Confirm that you checked Nova Poshta and found no TTN for this order. This will allow a new creation attempt.')}
      confirmLabel={t('Confirm')}
      onClose={confirmed => {
        setMode(null)
        if (confirmed) void resolve('not_created')
      }} />}
  </div>
}
