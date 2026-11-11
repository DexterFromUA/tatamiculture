import { useEffect, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { normalizePhone } from '../lib/phone'
import { SupabaseError, supabaseRequest } from '../lib/supabase'

type SmsProvider = 'kyivstar' | 'twilio'
type SmsSettings = {
  provider: SmsProvider | null
  kyivstarConfigured: boolean
  kyivstarMode: 'live' | 'sandbox' | null
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
  const [testPhone, setTestPhone] = useState('')
  const [testSending, setTestSending] = useState(false)
  const [testAccepted, setTestAccepted] = useState(false)
  const [testError, setTestError] = useState('')

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

  async function sendTestSms(event: FormEvent) {
    event.preventDefault()
    if (!token || testSending) return
    setTestAccepted(false)
    const phone = normalizePhone(testPhone)
    if (!phone || !/^\+380\d{9}$/.test(phone)) {
      setTestError('Enter a valid Ukrainian phone number.')
      return
    }

    setTestSending(true)
    setTestError('')
    try {
      await supabaseRequest(settingsPath, { token, method: 'POST', body: JSON.stringify({ phone }) })
      setTestAccepted(true)
    } catch (cause) {
      setTestError(cause instanceof SupabaseError ? cause.message : 'Could not send the Kyivstar test SMS.')
    } finally {
      setTestSending(false)
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
      {settings.kyivstarMode === 'sandbox' && <p className="muted">{t('Kyivstar sandbox sends sign-in codes only to numbers confirmed in the Kyivstar portal.')}</p>}
      {!settings.kyivstarConfigured && <p className="muted">{t('Add the Kyivstar credentials in Supabase to activate it.')}</p>}
      {!settings.managementConfigured && <p className="muted">{t('Add the Supabase Management API token to switch providers here.')}</p>}
    </div>}
    <form className="sms-provider-settings__sandbox" onSubmit={event => void sendTestSms(event)}>
      <h3>{t('Kyivstar sandbox')}</h3>
      <p className="muted">{t('Send a test SMS to a phone number confirmed in the Kyivstar sandbox.')}</p>
      <label className="field">
        <span>{t('Test phone number')}</span>
        <input type="tel" autoComplete="tel" placeholder="+380" required value={testPhone} disabled={testSending}
          onChange={event => { setTestPhone(event.target.value); setTestError(''); setTestAccepted(false) }} />
      </label>
      <button type="submit" className="btn" disabled={!token || testSending || !testPhone.trim()}>{t(testSending ? 'Sending…' : 'Send test SMS')}</button>
      {testAccepted && <p className="success" role="status">{t('Kyivstar accepted the test SMS. Check your phone.')}</p>}
      {testError && <p className="error" role="alert">{t(testError)}</p>}
    </form>
  </section>
}
