import { useEffect, useId, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { SupabaseError, supabaseRequest } from '../lib/supabase'
import { useDrawer } from '../lib/useDrawer'
import type { NotificationChannel } from '../types'
import { ConfirmationDialog } from './ConfirmationDialog'

type Recipient = { user_id: string; email: string | null; phone_suffix: string | null; push_available: boolean }
type SmsAudience = { count: number; phone: string | null; confirmed: boolean }
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
  const [smsAudience, setSmsAudience] = useState<SmsAudience>()
  const [smsLookupFailed, setSmsLookupFailed] = useState(false)
  const [confirmSms, setConfirmSms] = useState(false)
  const [recipientId, setRecipientId] = useState('')
  const [message, setMessage] = useState('')
  const [sending, setSending] = useState(false)
  const [queued, setQueued] = useState(0)
  const [error, setError] = useState('')
  const [revision, setRevision] = useState(0)
  const inFlight = useRef(false)
  const lastRequests = useRef<Partial<Record<NotificationChannel, { id: string; destination: string; message: string }>>>({})
  const broadcast = customerId === undefined
  const recipients = Array.isArray(audience) ? audience : emptyRecipients
  const recipient = recipients.find(account => account.user_id === recipientId)
  const broadcastSize = typeof audience === 'number' ? audience : 0
  const available = broadcast ? broadcastSize > 0 : recipients.some(account => account.push_available)
  const canSend = Boolean((broadcast ? available : recipient?.push_available) && message.trim() && !sending)
  const canSendSms = Boolean(smsAudience?.count && message.trim() && !sending)

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
      setRecipientId(current => Array.isArray(result) && result.some(account => account.user_id === current)
        ? current : Array.isArray(result) && result.length === 1 ? result[0].user_id : '')
    }).catch(() => {
      if (!abort.signal.aborted) setError('Could not check push availability.')
    })
    void supabaseRequest<SmsAudience>('/rest/v1/rpc/crm_sms_audience', {
      method: 'POST', token, signal: abort.signal,
      body: JSON.stringify({ p_store_id: storeId, p_customer_id: customerId ?? null }),
    }).then(result => {
      if (abort.signal.aborted) return
      setSmsAudience(result)
      setSmsLookupFailed(false)
    }).catch(() => { if (!abort.signal.aborted) setSmsLookupFailed(true) })
    return () => abort.abort()
  }, [storeId, customerId, token, revision])

  const send = async (channel: NotificationChannel) => {
    const sms = channel === 'sms'
    if (!(sms ? canSendSms : canSend) || inFlight.current) return
    const body = message.trim()
    const destination = sms ? smsAudience?.phone ?? '' : recipientId
    let request = lastRequests.current[channel]
    if (!request || request.destination !== destination || request.message !== body) {
      request = { id: crypto.randomUUID(), destination, message: body }
      lastRequests.current[channel] = request
    }
    inFlight.current = true
    setSending(true)
    setError('')
    try {
      const rpc = sms ? 'queue_crm_sms' : broadcast ? 'queue_crm_push_broadcast' : 'queue_crm_customer_push'
      const recipientParams = sms
        ? { p_customer_id: customerId ?? null, p_expected_count: smsAudience?.count, p_expected_phone: smsAudience?.phone }
        : broadcast ? {} : { p_customer_id: customerId, p_user_id: destination }
      const count = Number(await supabaseRequest<number | boolean>(`/rest/v1/rpc/${rpc}`, {
        method: 'POST', token, signal: AbortSignal.timeout(15000), body: JSON.stringify({
          p_store_id: storeId, p_request_id: request.id, p_message: request.message,
          ...recipientParams,
        }),
      }))
      delete lastRequests.current[channel]
      if (count === 0) {
        if (sms) setSmsAudience({ count: 0, phone: null, confirmed: false })
        else if (broadcast) setAudience(0)
        else setAudience(recipients.map(account => account.user_id === destination ? { ...account, push_available: false } : account))
        return
      }
      setMessage('')
      setQueued(count)
    } catch (cause) {
      if (sms && cause instanceof SupabaseError && cause.status === 409) {
        setError('SMS recipient list changed. Check it before sending.')
        setSmsAudience(undefined)
        setRevision(value => value + 1)
      } else setError('Could not confirm that the notification was queued. Try again.')
    } finally {
      inFlight.current = false
      setSending(false)
    }
  }

  return <dialog ref={ref} className="order-drawer" aria-labelledby={titleId}
    onCancel={event => {
      if (event.target !== event.currentTarget) return
      if (inFlight.current) event.preventDefault()
      else onCancel(event)
    }}
    onClick={event => { if (!inFlight.current) onClick(event) }}>
    <header className="order-drawer__header">
      <div className="order-drawer__identity">
        <p className="order-drawer__eyebrow">{broadcast ? t('Customers') : customerName}</p>
        <h2 id={titleId}>{t(broadcast ? 'Notification broadcast' : 'Notifications')}</h2>
      </div>
    </header>
    <div className="order-drawer__body">
      <form className="form" onSubmit={event => { event.preventDefault(); void send('push') }}>
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
          {smsAudience && (broadcast
            ? <p className="muted">{t('SMS recipients: {{count}}', { count: smsAudience.count })}</p>
            : !smsAudience.phone ? <p className="muted">{t('No valid phone number for SMS.')}</p>
              : <p className="muted">SMS · {smsAudience.phone}{!smsAudience.confirmed && <> · <strong>{t('Phone number is not confirmed')}</strong></>}</p>)}
        </div>
        {smsLookupFailed && <p className="error" role="alert">{t('Could not check SMS availability.')} <button type="button" className="text-btn" onClick={() => {
          setSmsLookupFailed(false)
          setRevision(value => value + 1)
        }}>{t('Try again')}</button></p>}
        {error && <p className="error" role="alert">{t(error)}{audience === undefined && <> <button type="button" className="text-btn" onClick={() => {
          setError('')
          setRevision(value => value + 1)
        }}>{t('Try again')}</button></>}</p>}
        <div className="actions">
          <button type="button" className="btn btn--ghost" disabled={sending} onClick={() => close()}>{t(queued ? 'Close' : 'Cancel')}</button>
          <button type="submit" className="btn" disabled={!canSend}>{t(broadcast ? 'Send push to all' : 'Send push')}</button>
          <button type="button" className="btn" disabled={!canSendSms} onClick={() => {
            if (broadcast) setConfirmSms(true)
            else void send('sms')
          }}>{t(broadcast ? 'Send SMS to all' : 'Send SMS')}</button>
        </div>
        {sending && <p className="muted" role="status">{t('Sending…')}</p>}
      </form>
    </div>
    {confirmSms && smsAudience && <ConfirmationDialog title={t('Confirm SMS broadcast')}
      message={t('Send this SMS to {{count}} customer numbers?', { count: smsAudience.count })}
      details={[t('This includes valid numbers that customers have not confirmed. SMS is billed by the provider.')]}
      confirmLabel={t('Send SMS to all')} onClose={confirmed => { setConfirmSms(false); if (confirmed) void send('sms') }} />}
  </dialog>
}
