import { useEffect, useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { getThemeSettings, saveThemeSettings, themeSettingsChanged } from '../lib/storefrontTheme'
import { SettingsSectionHeading } from './SettingsSectionHeading'
import { ToggleSwitch } from './ToggleSwitch'

export function LanguageSettings({ heading }: { heading: { number: string; title: string } }) {
  const { t } = useTranslation()
  const { store } = useStore()
  const { token } = useAuth()
  const storeId = store?.id
  const formId = useId()
  const [showLanguageSwitch, setShowLanguageSwitch] = useState<boolean | null>(null)
  const [error, setError] = useState('')
  const [saving, setSaving] = useState(false)
  const [saved, setSaved] = useState(false)

  useEffect(() => {
    if (!storeId) return
    let active = true
    void getThemeSettings(storeId).then(settings => {
      if (active) setShowLanguageSwitch(settings.show_language_switch)
    }).catch(() => {
      if (active) setError('Could not load language settings.')
    })
    return () => { active = false }
  }, [storeId])

  const save = async () => {
    if (!storeId || !token || showLanguageSwitch === null || saving) return
    setSaving(true)
    setSaved(false)
    setError('')
    try {
      await saveThemeSettings(storeId, token, { show_language_switch: showLanguageSwitch })
      setSaved(true)
      window.dispatchEvent(new Event(themeSettingsChanged))
    } catch {
      setError('Could not save language settings.')
    } finally {
      setSaving(false)
    }
  }

  return <>
    <SettingsSectionHeading {...heading} action={showLanguageSwitch !== null && (
      <div className="settings-workspace__heading-actions">
        <button type="submit" form={formId} className="btn" disabled={saving || !token}>
          {t(saving ? 'Saving…' : 'Save')}
        </button>
      </div>
    )} />
    {error && <p className="error" role="alert">{t(error)}</p>}
    {showLanguageSwitch !== null && <form id={formId} className="form" onSubmit={event => {
      event.preventDefault()
      void save()
    }}>
      <label className="field switch-field">
        <ToggleSwitch checked={showLanguageSwitch} disabled={saving} onChange={event => {
          setShowLanguageSwitch(event.target.checked)
          setSaved(false)
        }} />
        {t('Show language switch in the header')}
      </label>
      {saved && <div className="banner-settings__actions">
        <p className="success" role="status">{t('Saved')}</p>
      </div>}
    </form>}
  </>
}
