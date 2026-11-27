import { useStorefrontSettingsSave } from './StorefrontSettingsSave'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { getThemeSettings, saveThemeSettings, themeSettingsChanged, type ThemeMode, type ThemeSettings as Settings } from '../lib/storefrontTheme'
import { ToggleSwitch } from './ToggleSwitch'

export function ThemeSettings() {
  const { t } = useTranslation()
  const { store } = useStore()
  const { token } = useAuth()
  const [draft, setDraft] = useState<Settings | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [, setSaved] = useState(false)
  const storeId = store?.id

  useEffect(() => {
    if (!storeId) return
    let active = true
    void getThemeSettings(storeId).then(value => { if (active) setDraft(value) }).catch(cause => {
      if (active) setError(`${t('Could not load theme settings.')} ${cause instanceof Error ? cause.message : ''}`)
    })
    return () => { active = false }
  }, [storeId, t])

  const save = async () => {
    if (!storeId || !token || !draft || busy) throw new Error('Settings are not ready.')
    setBusy(true)
    setError('')
    setSaved(false)
    try {
      await saveThemeSettings(storeId, token, { show_theme_switch: draft.show_theme_switch, default_theme: draft.default_theme })
      setSaved(true)
      window.dispatchEvent(new Event(themeSettingsChanged))
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('Could not save theme settings.'))
      throw cause
    } finally { setBusy(false) }
  }

  useStorefrontSettingsSave('ThemeSettings.tsx', save)

  return <section className="settings-card">
    <header className="banner-settings__header"><h3>{t('Storefront theme')}</h3></header>
    <p className="muted">{t('Choose the default appearance and let visitors switch themes.')}</p>
    {error && <p className="error" role="alert">{error}</p>}
    {draft && <form onSubmit={event => event.preventDefault()}>
      <label className="field switch-field">
        <ToggleSwitch checked={draft.show_theme_switch} disabled={busy} onChange={event => {
          setDraft({ ...draft, show_theme_switch: event.target.checked })
          setSaved(false)
        }} />
        {t('Show theme switch next to language')}
      </label>
      <label className="field"><span>{t('Default theme')}</span><select value={draft.default_theme} onChange={event => { setDraft({ ...draft, default_theme: event.target.value as ThemeMode }); setSaved(false) }}>
        <option value="system">{t('System theme')}</option><option value="light">{t('Light theme')}</option><option value="dark">{t('Dark theme')}</option>
      </select></label>
      <p className="muted">{t('Visitors’ saved choices take priority. When the switch is hidden, everyone uses the default theme.')}</p>

    </form>}
  </section>
}
