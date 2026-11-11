import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { supabaseRequest } from '../lib/supabase'

type SmsProvider = 'kyivstar' | 'twilio'
type SmsSettings = {
  provider: SmsProvider | null
  kyivstarConfigured: boolean
  managementConfigured: boolean
}

const settingsPath = '/functions/v1/sms-provider-settings'

export function SmsProviderSettings() {
  const { t } = useTranslation()
  const { token } = useAuth()
  const [settings, setSettings] = useState<SmsSettings | null>(null)
  const [attempt, setAttempt] = useState(0)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState('')

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
      || (provider === 'kyivstar' && !settings.kyivstarConfigured)) return
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

  return <section className="settings-card sms-provider-settings">
    <header className="banner-settings__header">
      <h2>{t('SMS sign-in')}</h2>
      <p className="muted">{t('Choose who sends verification codes for sign-in and registration.')}</p>
    </header>
    {error && <p className="error" role="alert">{t(error)}</p>}
    {!settings && (error
      ? <button type="button" className="text-btn" onClick={() => { setError(''); setAttempt(value => value + 1) }}>{t('Try again')}</button>
      : <p className="muted" role="status">{t('Loading…')}</p>)}
    {settings && <div className="sms-provider-settings__provider" aria-busy={saving}>
      <div className="sms-provider-settings__switch">
        <strong>Twilio</strong>
        <label className="mode-switch">
          <input type="checkbox" role="switch" aria-label={t('Use Kyivstar for SMS')} checked={settings.provider === 'kyivstar'}
            disabled={!token || saving || !settings.managementConfigured || (settings.provider !== 'kyivstar' && !settings.kyivstarConfigured)}
            onChange={event => void switchProvider(event.target.checked ? 'kyivstar' : 'twilio')} />
          <span aria-hidden="true" />
        </label>
        <strong>{t('Kyivstar')}</strong>
      </div>
      {saving && <p className="muted" role="status">{t('Saving…')}</p>}
      {!settings.kyivstarConfigured && <p className="muted">{t('Add the Kyivstar credentials in Supabase to activate it.')}</p>}
      {!settings.managementConfigured && <p className="muted">{t('Add the Supabase Management API token to switch providers here.')}</p>}
    </div>}
  </section>
}
