import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { getPaymentSettings, paymentMethods, savePaymentSettings, setPaymentTestMode, type PaymentMethodSettings } from '../lib/paymentMethods'

export function PaymentSettings() {
  const { t } = useTranslation()
  const { token } = useAuth()
  const { store } = useStore()
  const storeId = store?.id
  const [draft, setDraft] = useState<PaymentMethodSettings | null>(null)
  const [saved, setSaved] = useState<PaymentMethodSettings | null>(null)
  const [testMode, setTestMode] = useState<boolean | null>(null)
  const [modeBusy, setModeBusy] = useState(false)
  const [modeError, setModeError] = useState('')
  const [busy, setBusy] = useState(false)
  const [confirmed, setConfirmed] = useState(false)
  const [error, setError] = useState('')
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    if (!storeId) return
    let cancelled = false
    void getPaymentSettings(storeId).then(({ payment_test_mode, ...methods }) => {
      if (!cancelled) {
        setDraft(methods)
        setSaved(methods)
        setTestMode(payment_test_mode)
      }
    }).catch(() => { if (!cancelled) setError('Could not load payment methods.') })
    return () => { cancelled = true }
  }, [storeId, attempt])

  const dirty = draft && saved && paymentMethods.some(({ field }) => draft[field] !== saved[field])
  const save = async () => {
    if (!storeId || !token || !draft || !dirty || busy || modeBusy) return
    setBusy(true)
    setError('')
    setConfirmed(false)
    try {
      await savePaymentSettings(storeId, draft, token)
      setSaved(draft)
      setConfirmed(true)
    } catch {
      setError('Could not save payment methods.')
    } finally {
      setBusy(false)
    }
  }

  const changeMode = async (value: boolean) => {
    if (!storeId || !token || !saved || busy || modeBusy) return
    setModeError('')
    setModeBusy(true)
    setTestMode(value)
    try {
      await setPaymentTestMode(storeId, value, token)
    } catch (cause) {
      setTestMode(testMode)
      setModeError(cause instanceof Error ? cause.message : 'Could not save payment mode.')
    } finally {
      setModeBusy(false)
    }
  }

  return <>
    {saved && <section className="nova-mode">
      <div>
        <p className="eyebrow">{t('Payment environment')}</p>
        <h2>{t(testMode === null ? 'Current provider modes' : testMode ? 'Test mode' : 'Live mode')}</h2>
        <p className="muted">{t(testMode === null
          ? 'Turn on test mode to use the sandbox for both Monobank and LiqPay.'
          : testMode ? 'New Monobank and LiqPay payments use test credentials.'
          : 'New Monobank and LiqPay payments use live credentials.')}</p>
      </div>
      <label className="mode-switch">
        <input type="checkbox" checked={testMode === true} disabled={busy || modeBusy || !token} onChange={event => void changeMode(event.target.checked)} />
        <span aria-hidden="true" />{t('Test mode')}
      </label>
      {modeError && <p className="error" role="alert">{t(modeError)}</p>}
    </section>}
    <section className="settings-card payment-settings">
      <header className="banner-settings__header">
        <p className="eyebrow">03 / {t('Settings')}</p>
        <h2>{t('Payment methods')}</h2>
        <p className="muted">{t('Choose which payment methods customers can use at checkout.')}</p>
      </header>
      {error && <p className="error" role="alert">{t(error)}</p>}
      {!draft && (error
        ? <button type="button" className="text-btn" onClick={() => { setError(''); setAttempt(value => value + 1) }}>{t('Try again')}</button>
        : <p className="muted" role="status">{t('Loading…')}</p>)}
      {draft && <>
        <div className="payment-settings__list">
          {paymentMethods.map(({ field, name, description, configured }) => <label key={field} className="payment-settings__row">
            <span><strong>{t(name)}</strong><small className="muted">{t(configured ? description : 'Integration is disabled in this deployment.')}</small></span>
            <input type="checkbox" role="switch" aria-label={t(name)} checked={draft[field]} disabled={busy || modeBusy} onChange={event => {
              setDraft({ ...draft, [field]: event.target.checked })
              setConfirmed(false)
            }} />
          </label>)}
        </div>
        {!paymentMethods.some(({ field, configured }) => configured && draft[field]) && <p className="muted">{t('With no payment methods available, customers cannot place orders.')}</p>}
        <div className="banner-settings__actions">
          <button type="button" className="btn" disabled={!dirty || busy || modeBusy || !token} onClick={() => void save()}>{t(busy ? 'Saving…' : 'Save settings')}</button>
          {confirmed && <p className="success" role="status">{t('Saved')}</p>}
        </div>
      </>}
    </section>
  </>
}
