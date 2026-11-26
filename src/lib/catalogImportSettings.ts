import { supabaseRequest } from './supabase'

export type CatalogImportSettings = {
  auto_fill_cost: boolean
  cost_discount_percent: number
}

export const defaultCatalogImportSettings: CatalogImportSettings = {
  auto_fill_cost: false,
  cost_discount_percent: 20,
}

const settingsPath = '/rest/v1/catalog_import_settings'

export async function getCatalogImportSettings(storeId: string, token: string, signal?: AbortSignal) {
  const [settings] = await supabaseRequest<CatalogImportSettings[]>(
    `${settingsPath}?store_id=eq.${storeId}&select=auto_fill_cost,cost_discount_percent`,
    { token, signal, cache: 'no-store' },
  )
  return settings ?? defaultCatalogImportSettings
}

export function saveCatalogImportSettings(storeId: string, token: string, settings: CatalogImportSettings) {
  return supabaseRequest(`${settingsPath}?on_conflict=store_id`, {
    method: 'POST', token, headers: { Prefer: 'resolution=merge-duplicates' },
    body: JSON.stringify({ store_id: storeId, ...settings }),
  })
}
