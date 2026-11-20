import { useEffect, useLayoutEffect, useState } from 'react'
import { defaultThemeSettings, getThemeSettings, readThemePreference, resolveTheme, themeSettingsChanged, themeStorageKey, type ThemeMode } from '../lib/storefrontTheme'

export function useStorefrontTheme(storeId?: string) {
  const [settings, setSettings] = useState(defaultThemeSettings)
  const [preference, setPreference] = useState<ThemeMode | null>(null)
  const [systemDark, setSystemDark] = useState(() => window.matchMedia('(prefers-color-scheme: dark)').matches)
  const mode = settings.show_theme_switch ? preference ?? settings.default_theme : settings.default_theme
  const theme = resolveTheme(mode, systemDark)

  useEffect(() => {
    if (!storeId) return
    let active = true
    let request = 0
    const load = () => {
      const current = ++request
      void getThemeSettings(storeId).then(value => { if (active && current === request) setSettings(value) }).catch(() => { /* Keep system defaults if settings cannot be loaded. */ })
    }
    const syncPreference = () => setPreference(readThemePreference(storeId))
    syncPreference()
    load()
    window.addEventListener(themeSettingsChanged, load)
    window.addEventListener('storage', syncPreference)
    return () => { active = false; window.removeEventListener(themeSettingsChanged, load); window.removeEventListener('storage', syncPreference) }
  }, [storeId])

  useEffect(() => {
    const media = window.matchMedia('(prefers-color-scheme: dark)')
    const update = () => setSystemDark(media.matches)
    media.addEventListener('change', update)
    return () => media.removeEventListener('change', update)
  }, [])

  useLayoutEffect(() => {
    document.documentElement.dataset.theme = theme
  }, [theme])

  const selectTheme = (next: ThemeMode) => {
    if (!storeId) return
    setPreference(next)
    try { localStorage.setItem(themeStorageKey(storeId), next) } catch { /* In-memory preference remains usable. */ }
  }

  return { mode, theme, showThemeSwitch: settings.show_theme_switch, selectTheme }
}
