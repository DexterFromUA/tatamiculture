import { useStorefrontSettingsSave } from './StorefrontSettingsSave'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { getThemeSettings, saveThemeSettings, themeSettingsChanged } from '../lib/storefrontTheme'
import { ToggleSwitch } from './ToggleSwitch'

export function LayoutSettings() {
  const { t } = useTranslation()
  const { store } = useStore()
  const { token } = useAuth()
  const [fullWidth, setFullWidth] = useState<boolean | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [, setSaved] = useState(false)
  const storeId = store?.id

  useEffect(() => {
    if (!storeId) return
    let active = true
    void getThemeSettings(storeId).then(settings => {
      if (active) setFullWidth(settings.full_width)
    }).catch(cause => {
      if (active) setError(cause instanceof Error ? cause.message : t('Could not load theme settings.'))
    })
    return () => { active = false }
  }, [storeId, t])

  const save = async () => {
    if (!storeId || !token || fullWidth === null || busy) throw new Error('Settings are not ready.')
    setBusy(true)
    setError('')
    setSaved(false)
    try {
      await saveThemeSettings(storeId, token, { full_width: fullWidth })
      setSaved(true)
      window.dispatchEvent(new Event(themeSettingsChanged))
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('Could not save theme settings.'))
      throw cause
    } finally {
      setBusy(false)
    }
  }

  useStorefrontSettingsSave('LayoutSettings.tsx', save)

  return <section className="settings-card">
    <header className="banner-settings__header"><h3>{t('Application layout')}</h3></header>
    {error && <p className="error" role="alert">{error}</p>}
    {fullWidth !== null && <form onSubmit={event => event.preventDefault()}>
      <label className="field switch-field">
        <ToggleSwitch checked={fullWidth} disabled={busy} onChange={event => {
          setFullWidth(event.target.checked)
          setSaved(false)
        }} />
        {t('Full-width application')}
      </label>

    </form>}
  </section>
}
