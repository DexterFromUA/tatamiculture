import { useEffect, useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { formatPrice } from '../lib/format'
import { supabaseRequest } from '../lib/supabase'
import { CenteredDialog } from './CenteredDialog'
import { ConfirmationDialog } from './ConfirmationDialog'
import { OrderActionButton } from './OrderActionButton'

type Refund = {
  order_id: string
  receipt_code: string
  currency: string
  amount: number
  status: 'processing' | 'completed' | 'failed' | null
  error: string | null
  automatic_available: boolean
}
type Method = 'automatic' | 'manual' | 'check' | 'review'
type Resolution = 'record_paid' | 'not_started'
type Selection = { refund: Refund; step: 'confirm' | 'method' } |
  { refund: Refund; step: 'review'; attemptId: string; resolution: Resolution }

export function CancelledOrderRefunds({ orderIds, token, onChange, compact = false }: {
  orderIds: string[]
  token: string
  onChange: (completedOrderId?: string) => void
  compact?: boolean
}) {
  const { t } = useTranslation()
  const titleId = useId()
  const [refunds, setRefunds] = useState<Refund[]>([])
  const [selection, setSelection] = useState<Selection | null>(null)
  const [refundMethod, setRefundMethod] = useState<'automatic' | 'manual' | ''>('')
  const [reviewableAttempts, setReviewableAttempts] = useState<Record<string, string | undefined>>({})
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [revision, setRevision] = useState(0)
  const idList = orderIds.join(',')

  useEffect(() => {
    const abort = new AbortController()
    void supabaseRequest<Refund[]>('/rest/v1/rpc/get_order_cancellation_refunds', {
      method: 'POST', token, signal: abort.signal, body: JSON.stringify({ p_order_ids: idList.split(',') }),
    }).then(setRefunds).catch(cause => { if (!abort.signal.aborted) setError(cause.message) })
    return () => abort.abort()
  }, [token, idList, revision])

  const run = async (refund: Refund, method: Method, review?: { attemptId: string; resolution: Resolution }) => {
    if (busy) return
    setBusy(true)
    setError('')
    setSelection(null)
    setReviewableAttempts(current => ({ ...current, [refund.order_id]: undefined }))
    try {
      const result = await supabaseRequest<{ status: Refund['status']; reviewAttemptId?: string }>('/functions/v1/crm-refund-order', {
        method: 'POST', token, body: JSON.stringify({ orderId: refund.order_id, amount: refund.amount, method, ...review }),
      })
      setRefunds(current => current.map(row => row.order_id === refund.order_id ? { ...row, status: result.status } : row))
      if (result.reviewAttemptId) {
        setReviewableAttempts(current => ({ ...current, [refund.order_id]: result.reviewAttemptId }))
      }
      onChange(result.status === 'completed' ? refund.order_id : undefined)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not process the refund. Check its status before retrying.')
    } finally {
      setRevision(value => value + 1)
      setBusy(false)
    }
  }

  const selectedAmount = selection && formatPrice(selection.refund.amount / 100, selection.refund.currency)
  if (!refunds.length && !error) return null
  return <section className={compact ? 'crm-order__refund' : 'order-drawer__card'} onClick={event => event.stopPropagation()}>
    {!compact && <h3>{t('Payment refund')}</h3>}
    {error && <p className="error" role="alert">{t(error)}</p>}
    {refunds.map(refund => {
      const attemptId = reviewableAttempts[refund.order_id]
      const disabledReason = refund.status === 'processing' ? 'The refund is pending confirmation. Use Check refund status.'
        : refund.amount <= 0 ? 'There is no amount left to refund.'
        : busy ? 'A refund request is being processed.' : undefined

      return <div key={refund.order_id} className="order-refund">
        <div className="actions">
          {orderIds.length > 1 && <span>#{refund.receipt_code}</span>}
          {!compact && <strong>{formatPrice(refund.amount / 100, refund.currency)}</strong>}
          {refund.status === 'completed' ? <button type="button" className={compact ? 'text-btn' : 'btn btn--ghost'} disabled>{t('Refund paid')}</button> :
          <OrderActionButton type="button" className={compact ? 'text-btn' : 'btn btn--ghost'} aria-haspopup="dialog"
            disabledReason={disabledReason && t(disabledReason)}
            onClick={() => { setError(''); setRefundMethod(''); setSelection({ refund, step: 'confirm' }) }}>
            {t(refund.status === 'processing' ? 'Refund in progress' : 'Refund payment')}
          </OrderActionButton>}
          {refund.status === 'processing' && <OrderActionButton type="button" className="text-btn"
            disabledReason={busy ? t('A refund request is being processed.') : undefined}
            onClick={() => void run(refund, 'check')}>{t('Check refund status')}</OrderActionButton>}
        </div>
        {refund.status === 'processing' && (attemptId ? <>
          <p>{t('Check the refund in the bank dashboard and confirm the result.')}</p>
          <div className="actions">
            <OrderActionButton type="button" className="btn btn--ghost" aria-haspopup="dialog"
              disabledReason={busy ? t('A refund request is being processed.') : undefined}
              onClick={() => setSelection({ refund, step: 'review', attemptId, resolution: 'record_paid' })}>
              {t('Record refund as paid')}
            </OrderActionButton>
            <OrderActionButton type="button" className="btn btn--ghost" aria-haspopup="dialog"
              disabledReason={busy ? t('A refund request is being processed.') : undefined}
              onClick={() => setSelection({ refund, step: 'review', attemptId, resolution: 'not_started' })}>
              {t('Confirm refund did not start')}
            </OrderActionButton>
          </div>
        </> : <p className="muted">{t('If the bank has no refund, check its status again 15 minutes after the attempt to review it manually.')}</p>)}
        {refund.status === 'failed' && <p className="error" role="alert">{t(refund.error || 'The payment provider rejected the refund')}</p>}
      </div>
    })}
    {selection?.step === 'confirm' && <ConfirmationDialog title={t('Refund payment')}
      message={t('Start a refund of {{amount}} for this cancelled order?', { amount: selectedAmount })}
      confirmLabel={t('Continue')} onClose={confirmed => setSelection(confirmed ? { ...selection, step: 'method' } : null)} />}
    {selection?.step === 'method' && <CenteredDialog aria-labelledby={titleId} onClose={value => {
      if (value === 'automatic') void run(selection.refund, 'automatic')
      else if (value === 'manual') void run(selection.refund, 'manual')
      else setSelection(null)
    }}>
      <h2 id={titleId}>{t('Refund method')}</h2>
      <p>{t('Choose how to refund {{amount}}.', { amount: selectedAmount })}</p>
      <form method="dialog">
        <fieldset className="refund-methods">
          <legend className="sr-only">{t('Refund method')}</legend>
          {selection.refund.automatic_available && <label className="refund-method">
            <input type="radio" name="refund-method" value="automatic" checked={refundMethod === 'automatic'} onChange={() => setRefundMethod('automatic')} />
            <span><strong>{t('Automatic refund')}</strong><small>{t('Send the refund through the payment provider.')}</small></span>
          </label>}
          <label className="refund-method">
            <input type="radio" name="refund-method" value="manual" checked={refundMethod === 'manual'} onChange={() => setRefundMethod('manual')} />
            <span><strong>{t('Manual refund')}</strong><small>{t('After transferring the money yourself, continue to record the refund as paid.')}</small></span>
          </label>
        </fieldset>
        <div className="confirmation-dialog__actions">
          <button type="submit" value="cancel" className="btn btn--ghost">{t('Cancel')}</button>
          <button type="submit" value={refundMethod} className="btn" disabled={!refundMethod}>{t('Continue')}</button>
        </div>
      </form>
    </CenteredDialog>}
    {selection?.step === 'review' && <ConfirmationDialog
      title={t(selection.resolution === 'record_paid' ? 'Record refund as paid' : 'Confirm refund did not start')}
      message={selection.resolution === 'record_paid'
        ? t('Confirm that the customer has already received {{amount}}. This records the return in the store.', { amount: selectedAmount })
        : t('Confirm in the bank dashboard that the refund for {{amount}} was never started. A new attempt will become available.', { amount: selectedAmount })}
      confirmLabel={t('Confirm')} onClose={confirmed => {
        if (confirmed) void run(selection.refund, 'review', { attemptId: selection.attemptId, resolution: selection.resolution })
        else setSelection(null)
      }} />}
  </section>
}
