import { supabaseRequest } from './supabase'

export type StorefrontContacts = { email: string; instagram_url: string }
export const contactsChanged = 'tatami:contacts-changed'

export async function getStorefrontContacts(storeId: string): Promise<StorefrontContacts> {
  const rows = await supabaseRequest<StorefrontContacts[]>(`/rest/v1/storefront_contacts?store_id=eq.${encodeURIComponent(storeId)}&select=email,instagram_url`)
  return rows[0] ?? { email: '', instagram_url: '' }
}
