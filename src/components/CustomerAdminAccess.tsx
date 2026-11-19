import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { SupabaseError, supabaseRequest } from '../lib/supabase'

type AccountAccess = {
  user_id: string
  display_name: string
  email: string | null
  phone_suffix: string | null
  role: 'OWNER' | 'MANAGER' | 'CONTENT' | null
  is_self: boolean
}

export function CustomerAdminAccess({ storeId, customerId, token, onSaved }: {
  storeId: string; customerId: string; token: string; onSaved: () => void
}) {
  const { t } = useTranslation()
  const [accounts, setAccounts] = useState<AccountAccess[]>([])
  const [loading, setLoading] = useState(true)
  const [error, setError] = useState('')
  const [confirmation, setConfirmation] = useState<{ userId: string; grant: boolean } | null>(null)
  const [pending, setPending] = useState(false)
  const [saved, setSaved] = useState('')
  const [revision, setRevision] = useState(0)

  useEffect(() => {
    const abort = new AbortController()
    void supabaseRequest<AccountAccess[]>('/rest/v1/rpc/crm_customer_staff_access', {
      method: 'POST', token, signal: abort.signal,
      body: JSON.stringify({ p_store_id: storeId, p_customer_id: customerId }),
    }).then(rows => {
      if (!abort.signal.aborted) { setAccounts(rows); setError('') }
    }).catch(cause => {
      if (!abort.signal.aborted && !(cause instanceof SupabaseError && cause.status === 403)) {
        setError(cause instanceof Error ? cause.message : 'Action failed')
      }
    }).finally(() => { if (!abort.signal.aborted) setLoading(false) })
    return () => abort.abort()
  }, [storeId, customerId, token, revision])

  const changeAccess = async () => {
    if (!confirmation || pending) return
    setPending(true)
    setError('')
    setSaved('')
    try {
      await supabaseRequest('/rest/v1/rpc/set_crm_administrator', {
        method: 'POST', token, body: JSON.stringify({
          p_store_id: storeId, p_customer_id: customerId, p_user_id: confirmation.userId, p_grant: confirmation.grant,
        }),
      })
      setSaved(confirmation.grant ? 'Administrator access granted' : 'Administrator access removed')
      setConfirmation(null)
      setRevision(value => value + 1)
      onSaved()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Action failed')
    } finally {
      setPending(false)
    }
  }

  if (!loading && accounts.length === 0 && !error) return null
  return <section className="customer-admin-access" aria-labelledby="customer-admin-access-title">
    <div className="customer-admin-access__heading"><h3 id="customer-admin-access-title">{t('CRM access')}</h3></div>
    {loading ? <p className="muted" role="status">{t('Loading…')}</p> : accounts.map(account => {
      const admin = account.role === 'OWNER' || account.role === 'MANAGER'
      const accountLabel = account.email || (account.phone_suffix ? `•••• ${account.phone_suffix}` : account.display_name || t('Account'))
      const selected = confirmation?.userId === account.user_id
      return <div className="customer-admin-access__account" key={account.user_id}>
        <div className="customer-admin-access__row">
          <span className="customer-admin-access__identity"><strong>{account.display_name || t('Account')}</strong><small>{accountLabel}</small></span>
          <span className={admin ? 'customer-admin-access__status active' : 'customer-admin-access__status'}>
            {t(account.role === 'OWNER' ? 'Store owner' : admin ? 'Administrator' : account.role === 'CONTENT' ? 'Limited access' : 'Customer')}
          </span>
        </div>
        {account.is_self ? <p className="customer-admin-access__hint">{t('Your account')}</p>
          : account.role === 'OWNER' ? <p className="customer-admin-access__hint">{t('The store owner’s access is protected.')}</p>
            : !selected && <button type="button" className="text-btn customer-admin-access__action" disabled={pending}
              onClick={() => { setSaved(''); setError(''); setConfirmation({ userId: account.user_id, grant: !admin }) }}>
              {t(admin ? 'Remove administrator access' : 'Make administrator')}
            </button>}
        {selected && <div className="customer-admin-access__confirm">
          <p>{t(confirmation?.grant
            ? 'Grant {{account}} access to the CRM and administrator management?'
            : 'Remove CRM administrator access for {{account}}?', { account: accountLabel })}</p>
          <div className="actions">
            <button type="button" className="btn" disabled={pending} onClick={() => void changeAccess()}>{t(pending ? 'Saving…' : 'Confirm')}</button>
            <button type="button" className="text-btn" disabled={pending} onClick={() => setConfirmation(null)}>{t('Cancel')}</button>
          </div>
        </div>}
      </div>
    })}
    {error && <p className="error" role="alert">{t(error)}</p>}
    {saved && <p className="customer-admin-access__saved" role="status">✓ {t(saved)}</p>}
  </section>
}
