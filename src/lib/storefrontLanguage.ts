export type StorefrontLanguage = 'uk' | 'en'
export type StorefrontLanguageMode = 'auto' | StorefrontLanguage

export const languagePreferenceKey = 'tatami-language'

export function readLanguagePreference(): StorefrontLanguage | null {
  try {
    const value = localStorage.getItem(languagePreferenceKey)
    return value === 'uk' || value === 'en' ? value : null
  } catch {
    return null
  }
}

export function detectBrowserLanguage(languages: readonly string[]): StorefrontLanguage {
  for (const language of languages) {
    const code = language.toLowerCase().split('-')[0]
    if (code === 'uk' || code === 'en') return code
  }
  return 'uk'
}

export function browserLanguage(): StorefrontLanguage {
  if (typeof navigator === 'undefined') return 'uk'
  return detectBrowserLanguage(navigator.languages?.length ? navigator.languages : [navigator.language])
}
