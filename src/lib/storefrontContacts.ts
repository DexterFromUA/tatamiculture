import { supabaseConfigured, supabaseRequest } from './supabase'

export type StorefrontContacts = { email: string; instagram_url: string }
export const contactsChanged = 'tatami:contacts-changed'
export const demoContacts: StorefrontContacts = { email: 'shalimovvlad@gmail.com', instagram_url: 'https://www.instagram.com/tatami.culture' }

export async function getStorefrontContacts(storeId: string): Promise<StorefrontContacts> {
  if (!supabaseConfigured) return demoContacts
  const rows = await supabaseRequest<StorefrontContacts[]>(`/rest/v1/storefront_contacts?store_id=eq.${encodeURIComponent(storeId)}&select=email,instagram_url`)
  return rows[0] ?? { email: '', instagram_url: '' }
}
