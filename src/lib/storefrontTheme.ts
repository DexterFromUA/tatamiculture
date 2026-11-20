import { supabaseConfigured, supabaseRequest } from './supabase'

export type ThemeMode = 'system' | 'light' | 'dark'
export type ThemeSettings = { show_theme_switch: boolean; default_theme: ThemeMode }
export const defaultThemeSettings: ThemeSettings = { show_theme_switch: true, default_theme: 'system' }
export const themeSettingsChanged = 'tatami:theme-settings-changed'
export const themeStorageKey = (storeId: string) => `tatami.theme.${storeId}`

export function readThemePreference(storeId: string): ThemeMode | null {
  try {
    const value = localStorage.getItem(themeStorageKey(storeId))
    if (value === 'system' || value === 'light' || value === 'dark') return value
  } catch { /* Theme selection still works when browser storage is unavailable. */ }
  return null
}

export function resolveTheme(mode: ThemeMode, systemDark: boolean): 'light' | 'dark' {
  return mode === 'system' ? systemDark ? 'dark' : 'light' : mode
}

export async function getThemeSettings(storeId: string): Promise<ThemeSettings> {
  if (!supabaseConfigured) return { ...defaultThemeSettings }
  const rows = await supabaseRequest<ThemeSettings[]>(`/rest/v1/storefront_theme_settings?store_id=eq.${encodeURIComponent(storeId)}&select=show_theme_switch,default_theme`)
  return rows[0] ?? { ...defaultThemeSettings }
}
