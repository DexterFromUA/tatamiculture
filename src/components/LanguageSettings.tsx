import { useEffect, useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { getThemeSettings, saveThemeSettings, themeSettingsChanged, type ThemeSettings } from '../lib/storefrontTheme'
import type { StorefrontLanguageMode } from '../lib/storefrontLanguage'
import { SettingsSectionHeading } from './SettingsSectionHeading'
import { ToggleSwitch } from './ToggleSwitch'

export function LanguageSettings({ heading }: { heading: { number: string; title: string } }) {
  const { t } = useTranslation()
  const { store } = useStore()
  const { token } = useAuth()
  const storeId = store?.id
  const formId = useId()
  const [draft, setDraft] = useState<Pick<ThemeSettings, 'show_language_switch' | 'default_language'> | null>(null)
  const [error, setError] = useState('')
  const [saving, setSaving] = useState(false)
  const [saved, setSaved] = useState(false)

  useEffect(() => {
    if (!storeId) return
    let active = true
    void getThemeSettings(storeId).then(({ show_language_switch, default_language }) => {
      if (active) setDraft({ show_language_switch, default_language })
    }).catch(() => {
      if (active) setError('Could not load language settings.')
    })
    return () => { active = false }
  }, [storeId])

  const save = async () => {
    if (!storeId || !token || !draft || saving) return
    setSaving(true)
    setSaved(false)
    setError('')
    try {
      await saveThemeSettings(storeId, token, draft)
      setSaved(true)
      window.dispatchEvent(new Event(themeSettingsChanged))
    } catch {
      setError('Could not save language settings.')
    } finally {
      setSaving(false)
    }
  }

  return <>
    <SettingsSectionHeading {...heading} action={draft && (
      <div className="settings-workspace__heading-actions">
        <button type="submit" form={formId} className="btn" disabled={saving || !token}>
          {t(saving ? 'Saving…' : 'Save')}
        </button>
      </div>
    )} />
    {error && <p className="error" role="alert">{t(error)}</p>}
    {draft && <form id={formId} className="form" onSubmit={event => {
      event.preventDefault()
      void save()
    }}>
      <label className="field switch-field">
        <ToggleSwitch checked={draft.show_language_switch} disabled={saving} onChange={event => {
          setDraft({ ...draft, show_language_switch: event.target.checked })
          setSaved(false)
        }} />
        {t('Show language switch in the header')}
      </label>
      <label className="field">
        <span>{t('Default language')}</span>
        <select value={draft.default_language} disabled={saving} onChange={event => {
          setDraft({ ...draft, default_language: event.target.value as StorefrontLanguageMode })
          setSaved(false)
        }}>
          <option value="auto">{t('Automatically')}</option>
          <option value="uk">{t('Ukrainian')}</option>
          <option value="en">{t('English')}</option>
        </select>
      </label>
      {saved && <div className="banner-settings__actions">
        <p className="success" role="status">{t('Saved')}</p>
      </div>}
    </form>}
  </>
}
