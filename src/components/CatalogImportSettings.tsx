import { useStorefrontSettingsSave } from './StorefrontSettingsSave'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { getCatalogImportSettings, saveCatalogImportSettings, type CatalogImportSettings as Settings } from '../lib/catalogImportSettings'
import { ToggleSwitch } from './ToggleSwitch'

export function CatalogImportSettings() {
  const { t } = useTranslation()
  const { store } = useStore()
  const { token } = useAuth()
  const storeId = store?.id
  const [settings, setSettings] = useState<Settings | null>(null)
  const [autoFill, setAutoFill] = useState(false)
  const [discount, setDiscount] = useState('')
  const [busy, setBusy] = useState(false)
  const [, setSaved] = useState(false)
  const [error, setError] = useState('')

  useEffect(() => {
    if (!storeId || !token) return
    const request = new AbortController()
    void getCatalogImportSettings(storeId, token, request.signal).then(value => {
      if (request.signal.aborted) return
      setSettings(value)
      setAutoFill(value.auto_fill_cost)
      setDiscount(String(value.cost_discount_percent))
    }).catch(() => {
      if (!request.signal.aborted) setError('Could not load import cost settings.')
    })
    return () => request.abort()
  }, [storeId, token])

  const save = async () => {
    if (!storeId || !token || !settings || busy) throw new Error('Settings are not ready.')
    const next = {
      auto_fill_cost: autoFill,
      cost_discount_percent: autoFill ? Number(discount) : settings.cost_discount_percent,
    }
    setBusy(true)
    setError('')
    setSaved(false)
    try {
      await saveCatalogImportSettings(storeId, token, next)
      setSettings(next)
      setDiscount(String(next.cost_discount_percent))
      setSaved(true)
    } catch {
      setError('Could not save import cost settings.')
      throw new Error('Could not save import cost settings.')
    } finally {
      setBusy(false)
    }
  }

  useStorefrontSettingsSave('CatalogImportSettings.tsx', save)

  return <section className="settings-card">
    <header className="banner-settings__header"><h3>{t('Cost on import')}</h3></header>
    {error && <p className="error" role="alert">{t(error)}</p>}
    {settings && <form onSubmit={event => event.preventDefault()}>
      <label className="field switch-field">
        <ToggleSwitch checked={autoFill} disabled={busy} onChange={event => {
          setAutoFill(event.target.checked)
          setSaved(false)
        }} />
        {t('Fill in the cost automatically')}
      </label>
      <label className="field">
        <span>{t('Discount from supplier price, %')}</span>
        <input type="number" min="0" max="100" step="0.01" required value={discount}
          disabled={!autoFill || busy} onChange={event => {
            setDiscount(event.target.value)
            setSaved(false)
          }} />
      </label>

    </form>}
  </section>
}
