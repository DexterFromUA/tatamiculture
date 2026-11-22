import { useEffect, useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { supabaseRequest } from '../lib/supabase'
import { ToggleSwitch } from './ToggleSwitch'

type SmsProvider = 'kyivstar' | 'twilio' | 'smsclub'
type SmsSettings = {
  provider: SmsProvider | null
  kyivstarConfigured: boolean
  smsClubConfigured: boolean
  managementConfigured: boolean
}

const settingsPath = '/functions/v1/sms-provider-settings'

export function SmsProviderSettings() {
  const { t } = useTranslation()
  const { token } = useAuth()
  const { store, setSmsNotificationsEnabled } = useStore()
  const notificationsLabel = useId()
  const notificationsDescription = useId()
  const [settings, setSettings] = useState<SmsSettings | null>(null)
  const [attempt, setAttempt] = useState(0)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')
  const [notificationsStatus, setNotificationsStatus] = useState<'saving' | 'saved' | 'error' | null>(null)

  useEffect(() => {
    if (!token) return
    const controller = new AbortController()
    void supabaseRequest<SmsSettings>(settingsPath, { token, cache: 'no-store', signal: controller.signal })
      .then(result => {
        if (controller.signal.aborted) return
        setSettings(result)
      })
      .catch(() => {
        if (!controller.signal.aborted) setError('Could not load the SMS provider.')
      })
    return () => controller.abort()
  }, [token, attempt])

  async function switchProvider(provider: SmsProvider) {
    if (!token || !settings?.managementConfigured || settings.provider === provider || saving
      || (provider === 'kyivstar' && !settings.kyivstarConfigured)
      || (provider === 'smsclub' && !settings.smsClubConfigured)) return
    setSaving(true)
    setError('')
    try {
      const result = await supabaseRequest<SmsSettings>(settingsPath, {
        token,
        method: 'PUT',
        body: JSON.stringify({ provider }),
      })
      setSettings(result)
    } catch {
      setError('Could not save the SMS provider.')
    } finally {
      setSaving(false)
    }
  }

  async function switchNotifications(enabled: boolean) {
    if (!token || !store || notificationsStatus === 'saving') return
    setNotificationsStatus('saving')
    try {
      await setSmsNotificationsEnabled(enabled, token)
      setNotificationsStatus('saved')
    } catch {
      setNotificationsStatus('error')
    }
  }

  return <section className="settings-card sms-provider-settings">
    <p className="muted sms-provider-settings__intro">{t('Choose who sends verification codes for sign-in and registration.')}</p>
    {error && <p className="error" role="alert">{t(error)}</p>}
    {!settings && (error
      ? <button type="button" className="text-btn" onClick={() => { setError(''); setAttempt(value => value + 1) }}>{t('Try again')}</button>
      : <p className="muted" role="status">{t('Loading…')}</p>)}
    {settings && <div className="sms-provider-settings__provider" aria-busy={saving}>
      <label className="field">
        <span>{t('SMS provider')}</span>
        <select value={settings.provider ?? ''} disabled={!token || saving || !settings.managementConfigured}
          onChange={event => void switchProvider(event.target.value as SmsProvider)}>
          {!settings.provider && <option value="" disabled>{t('Provider unavailable')}</option>}
          <option value="twilio">Twilio</option>
          <option value="kyivstar" disabled={!settings.kyivstarConfigured}>{t('Kyivstar')}</option>
          <option value="smsclub" disabled={!settings.smsClubConfigured}>SMSClub (smsclub.com.ua)</option>
        </select>
      </label>
      {saving && <p className="muted" role="status">{t('Saving…')}</p>}
      {!settings.kyivstarConfigured && <p className="muted">{t('Add the Kyivstar credentials in Supabase to activate it.')}</p>}
      {!settings.smsClubConfigured && <p className="muted">{t('Add the smsclub.com.ua API key and sender in Infisical to activate it.')}</p>}
      {!settings.managementConfigured && <p className="muted">{t('Add the Supabase Management API token to switch providers here.')}</p>}
    </div>}
    <div className="sms-provider-settings__notifications">
      <div className="sms-provider-settings__notification-row">
        <div>
          <h3 id={notificationsLabel}>{t('SMS notifications')}</h3>
          <p id={notificationsDescription} className="muted">{t('Show the “Notify me when available” button for out-of-stock variants.')}</p>
        </div>
        <ToggleSwitch aria-labelledby={notificationsLabel} aria-describedby={notificationsDescription}
          checked={store?.smsNotificationsEnabled ?? false} disabled={!store || !token || notificationsStatus === 'saving'}
          onChange={event => void switchNotifications(event.target.checked)} />
      </div>
      {notificationsStatus === 'saving' && <p className="muted" role="status">{t('Saving…')}</p>}
      {notificationsStatus === 'saved' && <p className="success" role="status">{t('Saved')}</p>}
      {notificationsStatus === 'error' && <p className="error" role="alert">{t('Could not save SMS notifications.')}</p>}
    </div>
  </section>
}
