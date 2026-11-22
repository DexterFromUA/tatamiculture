import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { getThemeSettings, themeSettingsChanged, type ThemeMode, type ThemeSettings as Settings } from '../lib/storefrontTheme'
import { supabaseRequest } from '../lib/supabase'
import { ToggleSwitch } from './ToggleSwitch'

export function ThemeSettings() {
  const { t } = useTranslation()
  const { store } = useStore()
  const { token } = useAuth()
  const [draft, setDraft] = useState<Settings | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [saved, setSaved] = useState(false)
  const storeId = store?.id

  useEffect(() => {
    if (!storeId) return
    let active = true
    void getThemeSettings(storeId).then(value => { if (active) setDraft(value) }).catch(cause => {
      if (active) setError(`${t('Could not load theme settings.')} ${cause instanceof Error ? cause.message : ''}`)
    })
    return () => { active = false }
  }, [storeId, t])

  const save = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (!storeId || !token || !draft || busy) return
    setBusy(true)
    setError('')
    setSaved(false)
    try {
      await supabaseRequest('/rest/v1/storefront_theme_settings?on_conflict=store_id', {
        method: 'POST', token, headers: { Prefer: 'resolution=merge-duplicates' },
        body: JSON.stringify({ store_id: storeId, ...draft }),
      })
      setSaved(true)
      window.dispatchEvent(new Event(themeSettingsChanged))
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('Could not save theme settings.'))
    } finally { setBusy(false) }
  }

  return <section className="settings-card">
    <header className="banner-settings__header"><h2>{t('Storefront theme')}</h2><p className="muted">{t('Choose the default appearance and let visitors switch themes.')}</p></header>
    {error && <p className="error" role="alert">{error}</p>}
    {draft && <form className="form" onSubmit={event => void save(event)}>
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
      <div className="banner-settings__actions"><button className="btn" disabled={busy || !token}>{t(busy ? 'Saving…' : 'Save settings')}</button>{saved && <p className="success" role="status">{t('Saved')}</p>}</div>
    </form>}
  </section>
}
