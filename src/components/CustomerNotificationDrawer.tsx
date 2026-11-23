import { useEffect, useId, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { supabaseRequest } from '../lib/supabase'
import { useDrawer } from '../lib/useDrawer'

type Recipient = { user_id: string; email: string | null; phone_suffix: string | null; push_available: boolean }
const messageLimit = 500

export function CustomerNotificationDrawer({ storeId, customerId, customerName, token, onClose }: {
  storeId: string; customerId: string; customerName: string; token: string; onClose: () => void
}) {
  const { t } = useTranslation()
  const titleId = useId()
  const hintId = useId()
  const { ref, close, onCancel, onClick } = useDrawer({ openOnMount: true, onClose })
  const [recipients, setRecipients] = useState<Recipient[]>()
  const [recipientId, setRecipientId] = useState('')
  const [message, setMessage] = useState('')
  const [sending, setSending] = useState(false)
  const [queued, setQueued] = useState(false)
  const [error, setError] = useState('')
  const [revision, setRevision] = useState(0)
  const inFlight = useRef(false)
  const lastRequest = useRef<{ id: string; userId: string; message: string }>(null)
  const recipient = recipients?.find(account => account.user_id === recipientId)
  const available = recipients?.some(account => account.push_available)
  const canSend = Boolean(recipient?.push_available && message.trim() && !sending)

  useEffect(() => {
    const abort = new AbortController()
    void supabaseRequest<Recipient[]>('/rest/v1/rpc/crm_customer_push_recipients', {
      method: 'POST', token, signal: abort.signal,
      body: JSON.stringify({ p_store_id: storeId, p_customer_id: customerId }),
    }).then(accounts => {
      if (abort.signal.aborted) return
      setRecipients(accounts)
      setRecipientId(accounts.length === 1 ? accounts[0].user_id : '')
    }).catch(() => {
      if (!abort.signal.aborted) setError('Could not check push availability.')
    })
    return () => abort.abort()
  }, [storeId, customerId, token, revision])

  const send = async () => {
    if (!canSend || inFlight.current) return
    const body = message.trim()
    if (!lastRequest.current || lastRequest.current.userId !== recipientId || lastRequest.current.message !== body) {
      lastRequest.current = { id: crypto.randomUUID(), userId: recipientId, message: body }
    }
    const request = lastRequest.current
    inFlight.current = true
    setSending(true)
    setError('')
    try {
      const accepted = await supabaseRequest<boolean>('/rest/v1/rpc/queue_crm_customer_push', {
        method: 'POST', token, signal: AbortSignal.timeout(15000), body: JSON.stringify({
          p_store_id: storeId, p_customer_id: customerId, p_user_id: request.userId,
          p_request_id: request.id, p_message: request.message,
        }),
      })
      lastRequest.current = null
      if (!accepted) {
        setRecipients(accounts => accounts?.map(account => account.user_id === request.userId
          ? { ...account, push_available: false } : account))
        return
      }
      setMessage('')
      setQueued(true)
    } catch {
      setError('Could not confirm that the notification was queued. Try again.')
    } finally {
      inFlight.current = false
      setSending(false)
    }
  }

  return <dialog ref={ref} className="order-drawer" aria-labelledby={titleId}
    onCancel={event => { if (inFlight.current) event.preventDefault(); else onCancel(event) }}
    onClick={event => { if (!inFlight.current) onClick(event) }}>
    <header className="order-drawer__header">
      <div className="order-drawer__identity">
        <p className="order-drawer__eyebrow">{customerName}</p>
        <h2 id={titleId}>{t('Notifications')}</h2>
      </div>
    </header>
    <div className="order-drawer__body">
      <form className="form" onSubmit={event => { event.preventDefault(); void send() }}>
        {(recipients?.length ?? 0) > 1 && <label className="field">
          {t('Recipient')}
          <select value={recipientId} disabled={!available || sending} onChange={event => { setRecipientId(event.target.value); setQueued(false) }}>
            <option value="">{t('Select an account')}</option>
            {recipients?.map((account, index) => <option key={account.user_id} value={account.user_id} disabled={!account.push_available}>
              {account.email || (account.phone_suffix ? `•••• ${account.phone_suffix}` : `${t('Account')} ${index + 1}`)}
            </option>)}
          </select>
        </label>}
        <label className="field">
          {t('Notification text')}
          <textarea rows={5} maxLength={messageLimit} required value={message} disabled={sending} aria-describedby={hintId}
            onChange={event => { setMessage(event.target.value); setQueued(false) }} />
        </label>
        <div id={hintId} role="status">
          {queued && <p className="customer-save-status">{t('Notification queued.')}</p>}
          {!recipients && !error && <p className="muted">{t('Checking…')}</p>}
          {recipients && !available && <p className="muted">{t('This customer has no active push subscriptions.')}</p>}
        </div>
        {error && <p className="error" role="alert">{t(error)}{!recipients && <> <button type="button" className="text-btn" onClick={() => {
          setError('')
          setRevision(value => value + 1)
        }}>{t('Try again')}</button></>}</p>}
        <div className="actions">
          <button type="button" className="btn btn--ghost" disabled={sending} onClick={() => close()}>{t(queued ? 'Close' : 'Cancel')}</button>
          <button type="submit" className="btn" disabled={!canSend}>{t(sending ? 'Sending…' : 'Send notification')}</button>
        </div>
      </form>
    </div>
  </dialog>
}
