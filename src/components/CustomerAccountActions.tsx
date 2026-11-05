import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { SupabaseError, supabaseRequest } from '../lib/supabase'

type Account = { user_id: string; email: string | null; email_confirmed: boolean; can_delete: boolean }

export function CustomerAccountActions({ storeId, customerId, token, onDeleted }: {
  storeId: string; customerId: string; token: string; onDeleted: () => void
}) {
  const { t } = useTranslation()
  const [accounts, setAccounts] = useState<Account[] | null>(null)
  const [selectedId, setSelectedId] = useState('')
  const [subject, setSubject] = useState('')
  const [message, setMessage] = useState('')
  const [confirmDelete, setConfirmDelete] = useState(false)
  const [pending, setPending] = useState(false)
  const [error, setError] = useState('')
  const [status, setStatus] = useState('')
  const requestId = useRef<string | null>(null)

  useEffect(() => {
    const abort = new AbortController()
    void supabaseRequest<Account[]>('/rest/v1/rpc/crm_customer_accounts', {
      method: 'POST', token, signal: abort.signal,
      body: JSON.stringify({ p_store_id: storeId, p_customer_id: customerId }),
    }).then(rows => { if (!abort.signal.aborted) setAccounts(rows) }).catch(cause => {
      if (abort.signal.aborted) return
      if (cause instanceof SupabaseError && cause.status === 403) setAccounts([])
      else setError(cause instanceof Error ? cause.message : 'Action failed')
    })
    return () => abort.abort()
  }, [storeId, customerId, token])

  const account = accounts?.find(item => item.user_id === selectedId) ?? accounts?.[0]
  const canSend = account?.email_confirmed && Boolean(account.email)
  const perform = async (action: () => Promise<void>) => {
    if (pending) return
    setPending(true)
    setError('')
    setStatus('')
    try {
      await action()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Action failed')
    } finally {
      setPending(false)
    }
  }

  return <section className="customer-section customer-account-actions">
    <h3>{t('Registered account')}</h3>
    {error && <p className="error" role="alert">{t(error)}</p>}
    {status && <p role="status">{t(status)}</p>}
    {!accounts && !error && <p className="muted">{t('Loading…')}</p>}
    {accounts?.length === 0 && <p className="muted">{t('No registered account available')}</p>}
    {account && <>
      {accounts && accounts.length > 1 ? (
        <label className="field">{t('Registered account')}
          <select value={account.user_id} disabled={pending} onChange={event => {
            setSelectedId(event.target.value)
            setConfirmDelete(false)
            setError('')
            setStatus('')
            requestId.current = null
          }}>
            {accounts.map(item => <option value={item.user_id} key={item.user_id}>{item.email ?? item.user_id}</option>)}
          </select>
        </label>
      ) : <p>{account.email ?? '—'}</p>}
      {canSend ? <details>
        <summary>{t('Send email notification')}</summary>
        <form className="customer-account-actions__form" onSubmit={event => {
          event.preventDefault()
          if (!subject.trim() || !message.trim()) return
          void perform(async () => {
            requestId.current ??= crypto.randomUUID()
            await supabaseRequest('/functions/v1/crm-customer-email', {
              method: 'POST', token,
              body: JSON.stringify({ storeId, customerId, userId: account.user_id, subject, message, requestId: requestId.current }),
            })
            requestId.current = null
            setSubject('')
            setMessage('')
            setStatus('Email accepted for delivery')
          })
        }}>
          <label className="field">{t('Email subject')}<input value={subject} required maxLength={160} disabled={pending}
            onChange={event => { setSubject(event.target.value); requestId.current = null }} /></label>
          <label className="field">{t('Email message')}<textarea value={message} required rows={4} maxLength={5000} disabled={pending}
            onChange={event => { setMessage(event.target.value); requestId.current = null }} /></label>
          <button className="btn" disabled={pending || !subject.trim() || !message.trim()}>{t('Send email')}</button>
        </form>
      </details> : <p className="muted">{t('A confirmed email is required')}</p>}
      {account.can_delete && <div className="customer-account-actions__delete">
        {confirmDelete ? <>
          <p>{t('Permanently delete the account for {{email}}? Order history stays in the CRM.', { email: account.email ?? account.user_id })}</p>
          <div className="actions">
            <button type="button" className="btn btn--ghost customer-account-actions__danger" disabled={pending} onClick={() => void perform(async () => {
              await supabaseRequest('/rest/v1/rpc/delete_crm_customer_account', {
                method: 'POST', token,
                body: JSON.stringify({ p_store_id: storeId, p_customer_id: customerId, p_user_id: account.user_id }),
              })
              setAccounts(current => current?.filter(item => item.user_id !== account.user_id) ?? [])
              setSelectedId('')
              setConfirmDelete(false)
              setStatus('Customer account deleted')
              onDeleted()
            })}>{t('Confirm account deletion')}</button>
            <button type="button" className="text-btn" disabled={pending} onClick={() => setConfirmDelete(false)}>{t('Cancel')}</button>
          </div>
        </> : <button type="button" className="text-btn customer-account-actions__danger" disabled={pending} onClick={() => setConfirmDelete(true)}>{t('Delete account')}</button>}
      </div>}
    </>}
  </section>
}
