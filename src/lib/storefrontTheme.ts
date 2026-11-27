import { supabaseConfigured, supabaseRequest } from './supabase'

export type ThemeMode = 'system' | 'light' | 'dark'
export type ThemeSettings = {
  show_theme_switch: boolean
  default_theme: ThemeMode
  full_width: boolean
  show_language_switch: boolean
}
export const defaultThemeSettings: ThemeSettings = {
  show_theme_switch: true,
  default_theme: 'system',
  full_width: false,
  show_language_switch: true,
}
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
  const rows = await supabaseRequest<ThemeSettings[]>(`/rest/v1/storefront_theme_settings?store_id=eq.${encodeURIComponent(storeId)}&select=*`)
  return { ...defaultThemeSettings, ...rows[0] }
}

export async function saveThemeSettings(storeId: string, token: string, changes: Partial<ThemeSettings>) {
  const rows = await supabaseRequest<{ store_id: string }[]>(
    `/rest/v1/storefront_theme_settings?store_id=eq.${encodeURIComponent(storeId)}&select=store_id`,
    { method: 'PATCH', token, headers: { Prefer: 'return=representation' }, body: JSON.stringify(changes) },
  )
  if (!rows.length) {
    await supabaseRequest('/rest/v1/storefront_theme_settings?on_conflict=store_id', {
      method: 'POST', token, headers: { Prefer: 'resolution=ignore-duplicates' },
      body: JSON.stringify({ store_id: storeId, ...changes }),
    })
    const updated = await supabaseRequest<{ store_id: string }[]>(
      `/rest/v1/storefront_theme_settings?store_id=eq.${encodeURIComponent(storeId)}&select=store_id`,
      { method: 'PATCH', token, headers: { Prefer: 'return=representation' }, body: JSON.stringify(changes) },
    )
    if (!updated.length) throw new Error('Could not save theme settings.')
  }
}
