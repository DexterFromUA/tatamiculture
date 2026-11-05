import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { getPaymentSettings, paymentMethods, savePaymentSettings, type PaymentSettings as Settings } from '../lib/paymentMethods'

export function PaymentSettings() {
  const { t } = useTranslation()
  const { token } = useAuth()
  const { store } = useStore()
  const storeId = store?.id
  const [draft, setDraft] = useState<Settings | null>(null)
  const [saved, setSaved] = useState<Settings | null>(null)
  const [busy, setBusy] = useState(false)
  const [confirmed, setConfirmed] = useState(false)
  const [error, setError] = useState('')
  const [attempt, setAttempt] = useState(0)

  useEffect(() => {
    if (!storeId) return
    let cancelled = false
    void getPaymentSettings(storeId).then(settings => {
      if (!cancelled) {
        setDraft(settings)
        setSaved(settings)
      }
    }).catch(() => { if (!cancelled) setError('Could not load payment methods.') })
    return () => { cancelled = true }
  }, [storeId, attempt])

  const dirty = draft && saved && paymentMethods.some(({ field }) => draft[field] !== saved[field])
  const save = async () => {
    if (!storeId || !token || !draft || !dirty || busy) return
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

  return <section className="settings-card payment-settings">
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
          <input type="checkbox" role="switch" aria-label={t(name)} checked={draft[field]} disabled={busy} onChange={event => {
            setDraft({ ...draft, [field]: event.target.checked })
            setConfirmed(false)
          }} />
        </label>)}
      </div>
      {!paymentMethods.some(({ field, configured }) => configured && draft[field]) && <p className="muted">{t('With no payment methods available, customers cannot place orders.')}</p>}
      <div className="banner-settings__actions">
        <button type="button" className="btn" disabled={!dirty || busy || !token} onClick={() => void save()}>{t(busy ? 'Saving…' : 'Save settings')}</button>
        {confirmed && <p className="success" role="status">{t('Saved')}</p>}
      </div>
    </>}
  </section>
}
