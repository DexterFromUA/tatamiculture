import { readJson, writeJson } from './storage'
import { supabaseConfigured, supabaseRequest } from './supabase'
import { liqPayEnabled, monobankEnabled, novaPoshtaEnabled } from './payments'

export const paymentMethods = [
  { id: 'MONOBANK', field: 'monobank', name: 'monobank', description: 'Secure payment page', configured: supabaseConfigured && monobankEnabled },
  { id: 'LIQPAY', field: 'liqpay', name: 'LiqPay', description: 'Secure payment page', configured: supabaseConfigured && liqPayEnabled },
  { id: 'CASH_ON_DELIVERY', field: 'cash_on_delivery', name: 'Payment on delivery', description: novaPoshtaEnabled ? 'Pay when receiving at Nova Poshta' : 'Pay when receiving your order', configured: !supabaseConfigured || novaPoshtaEnabled || (!monobankEnabled && !liqPayEnabled) },
] as const

export type PaymentProvider = (typeof paymentMethods)[number]['id']
export type PaymentSettings = Record<(typeof paymentMethods)[number]['field'], boolean>
export const paymentUnavailable = 'This payment method is no longer available.'

const defaults: PaymentSettings = { cash_on_delivery: true, liqpay: true, monobank: true }
const mockKey = (storeId: string) => `shop.store.payment-methods.${storeId}`

export async function getPaymentSettings(storeId: string): Promise<PaymentSettings> {
  if (!supabaseConfigured) return readJson(mockKey(storeId), defaults)
  const rows = await supabaseRequest<PaymentSettings[]>(`/rest/v1/store_payment_methods?store_id=eq.${encodeURIComponent(storeId)}&select=cash_on_delivery,liqpay,monobank`, { cache: 'no-store' })
  return rows[0] ?? defaults
}

export async function savePaymentSettings(storeId: string, settings: PaymentSettings, token: string) {
  if (!supabaseConfigured) {
    writeJson(mockKey(storeId), settings)
    return
  }
  await supabaseRequest('/rest/v1/store_payment_methods?on_conflict=store_id', {
    method: 'POST', token, headers: { Prefer: 'resolution=merge-duplicates' },
    body: JSON.stringify({ store_id: storeId, ...settings }),
  })
}
