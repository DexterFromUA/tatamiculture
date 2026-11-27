import { useEffect, useLayoutEffect, useState } from 'react'
import i18n from '../i18n'
import { browserLanguage, languagePreferenceKey, readLanguagePreference, type StorefrontLanguage, type StorefrontLanguageMode } from '../lib/storefrontLanguage'

export function useStorefrontLanguage(defaultLanguage: StorefrontLanguageMode, showSwitch: boolean) {
  const [preference, setPreference] = useState(readLanguagePreference)
  const [detected, setDetected] = useState(browserLanguage)
  const fallback = defaultLanguage === 'auto' ? detected : defaultLanguage
  const language = (showSwitch ? preference : null) ?? fallback

  useEffect(() => {
    const syncPreference = (event: StorageEvent) => {
      if (event.key === languagePreferenceKey || event.key === null) setPreference(readLanguagePreference())
    }
    const syncBrowserLanguage = () => setDetected(browserLanguage())
    window.addEventListener('storage', syncPreference)
    window.addEventListener('languagechange', syncBrowserLanguage)
    return () => {
      window.removeEventListener('storage', syncPreference)
      window.removeEventListener('languagechange', syncBrowserLanguage)
    }
  }, [])

  useLayoutEffect(() => {
    if (i18n.language !== language) void i18n.changeLanguage(language)
  }, [language])

  return (next: StorefrontLanguage) => {
    setPreference(next)
    try { localStorage.setItem(languagePreferenceKey, next) } catch { /* Keep the current choice in memory. */ }
  }
}
