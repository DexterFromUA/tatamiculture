import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { SupabaseError, supabaseRequest } from '../lib/supabase'

type Account = { user_id: string; email: string | null; can_delete: boolean }

export function CustomerAccountActions({ storeId, customerId, token, onDeleted }: {
  storeId: string; customerId: string; token: string; onDeleted: () => void
}) {
  const { t } = useTranslation()
  const [phoneConfirmed, setPhoneConfirmed] = useState<boolean | null>()
  const [accounts, setAccounts] = useState<Account[]>([])
  const [selectedId, setSelectedId] = useState('')
  const [confirmDelete, setConfirmDelete] = useState(false)
  const [pending, setPending] = useState(false)
  const [error, setError] = useState('')
  const [deleted, setDeleted] = useState(false)
  const [revision, setRevision] = useState(0)

  useEffect(() => {
    const abort = new AbortController()
    const options = {
      method: 'POST',
      token,
      signal: abort.signal,
      body: JSON.stringify({ p_store_id: storeId, p_customer_id: customerId }),
    }
    void supabaseRequest<boolean>('/rest/v1/rpc/crm_customer_phone_confirmed', options).then(confirmed => {
      if (!abort.signal.aborted) setPhoneConfirmed(confirmed)
    }).catch(() => {
      if (!abort.signal.aborted) setPhoneConfirmed(null)
    })
    void supabaseRequest<Account[]>('/rest/v1/rpc/crm_customer_accounts', options).then(rows => {
      if (!abort.signal.aborted) setAccounts(rows.filter(row => row.can_delete))
    }).catch(cause => {
      if (!abort.signal.aborted && !(cause instanceof SupabaseError && cause.status === 403)) {
        setError(cause instanceof Error ? cause.message : 'Action failed')
      }
    })
    return () => abort.abort()
  }, [storeId, customerId, token, revision])

  const account = accounts.find(item => item.user_id === selectedId) ?? accounts[0]
  const deleteAccount = async () => {
    if (!account || pending) return
    setPending(true)
    setError('')
    try {
      await supabaseRequest('/rest/v1/rpc/delete_crm_customer_account', {
        method: 'POST', token,
        body: JSON.stringify({ p_store_id: storeId, p_customer_id: customerId, p_user_id: account.user_id }),
      })
      setAccounts(current => current.filter(item => item.user_id !== account.user_id))
      setSelectedId('')
      setConfirmDelete(false)
      setPhoneConfirmed(undefined)
      setRevision(value => value + 1)
      setDeleted(true)
      onDeleted()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Action failed')
    } finally {
      setPending(false)
    }
  }

  return <div className="customer-account-actions">
    <div className="customer-account-actions__row">
      <span className={phoneConfirmed ? 'customer-phone-status customer-phone-status--confirmed' : 'customer-phone-status'} role="status">
        {t(phoneConfirmed === undefined ? 'Checking phone status…' : phoneConfirmed === null
          ? 'Phone status unavailable' : phoneConfirmed ? 'Phone confirmed' : 'Phone not confirmed')}
      </span>
      {account && !confirmDelete && <button type="button" className="text-btn customer-account-actions__danger"
        onClick={() => { setError(''); setDeleted(false); setConfirmDelete(true) }}>{t('Delete account')}</button>}
    </div>
    {error && <p className="error" role="alert">{t(error)}</p>}
    {deleted && <p role="status">{t('Customer account deleted')}</p>}
    {account && confirmDelete && <div className="customer-account-actions__delete">
      {accounts.length > 1 && <label className="field">{t('Account to delete')}
        <select value={account.user_id} disabled={pending} onChange={event => setSelectedId(event.target.value)}>
          {accounts.map(item => <option value={item.user_id} key={item.user_id}>{item.email ?? item.user_id}</option>)}
        </select>
      </label>}
      <p>{t('Permanently delete the account for {{email}}? Order history stays in the CRM.', { email: account.email ?? account.user_id })}</p>
      <div className="actions">
        <button type="button" className="btn btn--ghost customer-account-actions__danger" disabled={pending}
          onClick={() => void deleteAccount()}>{t('Confirm account deletion')}</button>
        <button type="button" className="text-btn" disabled={pending} onClick={() => setConfirmDelete(false)}>{t('Cancel')}</button>
      </div>
    </div>}
  </div>
}
