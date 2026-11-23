import { useEffect, useId, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { supabaseRequest } from '../lib/supabase'
import { useDrawer } from '../lib/useDrawer'

type Recipient = { user_id: string; email: string | null; phone_suffix: string | null; push_available: boolean }
const messageLimit = 500
const emptyRecipients: Recipient[] = []

export function CustomerNotificationDrawer({ storeId, customerId, customerName, token, onClose }: {
  storeId: string; token: string; onClose: () => void
} & ({ customerId: string; customerName: string } | { customerId?: never; customerName?: never })) {
  const { t } = useTranslation()
  const titleId = useId()
  const hintId = useId()
  const { ref, close, onCancel, onClick } = useDrawer({ openOnMount: true, onClose })
  const [audience, setAudience] = useState<Recipient[] | number>()
  const [recipientId, setRecipientId] = useState('')
  const [message, setMessage] = useState('')
  const [sending, setSending] = useState(false)
  const [queued, setQueued] = useState(0)
  const [error, setError] = useState('')
  const [revision, setRevision] = useState(0)
  const inFlight = useRef(false)
  const lastRequest = useRef<{ id: string; userId: string; message: string }>(null)
  const broadcast = customerId === undefined
  const recipients = Array.isArray(audience) ? audience : emptyRecipients
  const recipient = recipients.find(account => account.user_id === recipientId)
  const broadcastSize = typeof audience === 'number' ? audience : 0
  const available = broadcast ? broadcastSize > 0 : recipients.some(account => account.push_available)
  const canSend = Boolean((broadcast ? available : recipient?.push_available) && message.trim() && !sending)

  useEffect(() => {
    const abort = new AbortController()
    const lookup = customerId === undefined
      ? supabaseRequest<number>('/rest/v1/rpc/crm_push_broadcast_size', {
        method: 'POST', token, signal: abort.signal, body: JSON.stringify({ p_store_id: storeId }),
      })
      : supabaseRequest<Recipient[]>('/rest/v1/rpc/crm_customer_push_recipients', {
        method: 'POST', token, signal: abort.signal, body: JSON.stringify({ p_store_id: storeId, p_customer_id: customerId }),
      })
    void lookup.then(result => {
      if (abort.signal.aborted) return
      setAudience(result)
      setRecipientId(Array.isArray(result) && result.length === 1 ? result[0].user_id : '')
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
      const rpc = broadcast ? 'queue_crm_push_broadcast' : 'queue_crm_customer_push'
      const count = Number(await supabaseRequest<number | boolean>(`/rest/v1/rpc/${rpc}`, {
        method: 'POST', token, signal: AbortSignal.timeout(15000), body: JSON.stringify({
          p_store_id: storeId, p_request_id: request.id, p_message: request.message,
          ...(!broadcast && { p_customer_id: customerId, p_user_id: request.userId }),
        }),
      }))
      lastRequest.current = null
      if (count === 0) {
        if (broadcast) setAudience(0)
        else setAudience(recipients.map(account => account.user_id === request.userId ? { ...account, push_available: false } : account))
        return
      }
      setMessage('')
      setQueued(count)
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
        <p className="order-drawer__eyebrow">{broadcast ? t('Customers') : customerName}</p>
        <h2 id={titleId}>{t(broadcast ? 'Push broadcast' : 'Notifications')}</h2>
      </div>
    </header>
    <div className="order-drawer__body">
      <form className="form" onSubmit={event => { event.preventDefault(); void send() }}>
        {recipients.length > 1 && <label className="field">
          {t('Recipient')}
          <select value={recipientId} disabled={!available || sending} onChange={event => { setRecipientId(event.target.value); setQueued(0) }}>
            <option value="">{t('Select an account')}</option>
            {recipients.map((account, index) => <option key={account.user_id} value={account.user_id} disabled={!account.push_available}>
              {account.email || (account.phone_suffix ? `•••• ${account.phone_suffix}` : `${t('Account')} ${index + 1}`)}
            </option>)}
          </select>
        </label>}
        <label className="field">
          {t('Notification text')}
          <textarea rows={5} maxLength={messageLimit} required value={message} disabled={sending} aria-describedby={hintId}
            onChange={event => { setMessage(event.target.value); setQueued(0) }} />
        </label>
        <div id={hintId} role="status">
          {queued > 0 && <p className="customer-save-status">{t(broadcast ? 'Broadcast queued. Recipients: {{count}}.' : 'Notification queued.', { count: queued })}</p>}
          {audience === undefined && !error && <p className="muted">{t('Checking…')}</p>}
          {broadcast && broadcastSize > 0 && queued === 0 && <p className="muted">{t('Customers with active push subscriptions: {{count}}', { count: broadcastSize })}</p>}
          {audience !== undefined && !available && <p className="muted">{t(broadcast ? 'No customers have active push subscriptions.' : 'This customer has no active push subscriptions.')}</p>}
        </div>
        {error && <p className="error" role="alert">{t(error)}{audience === undefined && <> <button type="button" className="text-btn" onClick={() => {
          setError('')
          setRevision(value => value + 1)
        }}>{t('Try again')}</button></>}</p>}
        <div className="actions">
          <button type="button" className="btn btn--ghost" disabled={sending} onClick={() => close()}>{t(queued ? 'Close' : 'Cancel')}</button>
          <button type="submit" className="btn" disabled={!canSend}>{t(sending ? 'Sending…' : broadcast ? 'Send to all' : 'Send notification')}</button>
        </div>
      </form>
    </div>
  </dialog>
}
