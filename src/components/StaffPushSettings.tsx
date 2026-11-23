import { useEffect, useId, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { isStandalone } from '../lib/pwa'
import { supabaseRequest } from '../lib/supabase'
import { ToggleSwitch } from './ToggleSwitch'

type StaffPreference = {
  user_id: string
  display_name: string | null
  role: 'OWNER' | 'MANAGER'
  enabled: boolean
  has_subscription: boolean
}

export function StaffPushSettings() {
  const { t } = useTranslation()
  const { token, user } = useAuth()
  const { store } = useStore()
  const storeId = store?.id
  const titleId = useId()
  const [staff, setStaff] = useState<StaffPreference[]>()
  const [revision, setRevision] = useState(0)
  const [savingId, setSavingId] = useState<string>()
  const [error, setError] = useState('')

  useEffect(() => {
    if (!storeId || !token) return
    const abort = new AbortController()
    void supabaseRequest<StaffPreference[]>('/rest/v1/rpc/crm_staff_push_settings', {
      method: 'POST', token, signal: abort.signal, body: JSON.stringify({ p_store_id: storeId }),
    }).then(rows => {
      if (!abort.signal.aborted) setStaff(rows)
    }).catch(() => {
      if (!abort.signal.aborted) setError('Could not load administrator notifications.')
    })
    return () => abort.abort()
  }, [revision, storeId, token])

  const save = async (userId: string, enabled: boolean) => {
    if (!storeId || !token || savingId) return
    setSavingId(userId)
    setError('')
    try {
      await supabaseRequest('/rest/v1/rpc/set_crm_staff_push_enabled', {
        method: 'POST', token, signal: AbortSignal.timeout(10000),
        body: JSON.stringify({ p_store_id: storeId, p_user_id: userId, p_enabled: enabled }),
      })
      setStaff(rows => rows?.map(row => row.user_id === userId ? { ...row, enabled } : row))
    } catch {
      setError('Could not update administrator notifications.')
      setRevision(value => value + 1)
    } finally {
      setSavingId(undefined)
    }
  }

  return <section className="settings-card staff-push-settings" aria-labelledby={titleId}>
    <h3 id={titleId}>{t('Administrator push notifications')}</h3>
    <p className="muted">{t('Enabled administrators get a push when a new order is ready to process.')}</p>
    {error && <p className="error" role="alert">{t(error)}</p>}
    {!staff && (error
      ? <button type="button" className="text-btn" onClick={() => { setError(''); setRevision(value => value + 1) }}>{t('Try again')}</button>
      : <p className="muted" role="status">{t('Loading…')}</p>)}
    {staff?.length === 0 && <p className="muted">{t('No administrators found.')}</p>}
    {staff && staff.length > 0 && <ul className="staff-push-settings__list">
      {staff.map(row => {
        const role = t(row.role === 'OWNER' ? 'Store owner' : 'Administrator')
        const name = row.display_name || role
        const deviceStatusId = `${titleId}-${row.user_id}`
        return <li key={row.user_id} className="staff-push-settings__row" aria-busy={savingId === row.user_id}>
          <div className="staff-push-settings__identity">
            <strong>{name}</strong>
            {row.display_name && <span className="muted">{role}</span>}
            <small className="muted" id={deviceStatusId}>
              {t(row.has_subscription ? 'Push notifications are enabled on a device.' : 'Enable push notifications in the profile of the installed app.')}
            </small>
            {!row.has_subscription && row.user_id === user?.id && isStandalone() && <Link className="text-btn" to="/account">{t('Open notification settings in your profile')}</Link>}
          </div>
          <ToggleSwitch aria-label={t('New order notifications for {{name}}', { name })} aria-describedby={deviceStatusId}
            checked={row.enabled} disabled={Boolean(savingId)} onChange={event => void save(row.user_id, event.target.checked)} />
        </li>
      })}
    </ul>}
  </section>
}
