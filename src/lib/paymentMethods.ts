import { supabaseConfigured, supabaseRequest } from './supabase'
import { liqPayEnabled, monobankEnabled, novaPoshtaEnabled } from './payments'
import liqPayIcon from '../assets/liqpay.svg'
import monoIcon from '../assets/plata-by-mono.svg'

export const paymentMethods = [
  { id: 'MONOBANK', field: 'monobank', name: 'monobank', icon: monoIcon, description: 'Secure payment page', configured: supabaseConfigured && monobankEnabled },
  { id: 'LIQPAY', field: 'liqpay', name: 'LiqPay', icon: liqPayIcon, description: 'Secure payment page', configured: supabaseConfigured && liqPayEnabled },
  { id: 'CASH_ON_DELIVERY', field: 'cash_on_delivery', name: 'Payment on delivery', icon: null, description: novaPoshtaEnabled ? 'Pay when receiving at Nova Poshta' : 'Pay when receiving your order', configured: novaPoshtaEnabled || (!monobankEnabled && !liqPayEnabled) },
] as const

export type PaymentProvider = (typeof paymentMethods)[number]['id']
export type PaymentMethodSettings = Record<(typeof paymentMethods)[number]['field'], boolean>
export type PaymentSettings = PaymentMethodSettings & { payment_test_mode: boolean | null }
export const paymentUnavailable = 'This payment method is no longer available.'
export const paymentSettingsChanged = 'Payment settings changed. Please try again.'

const defaults: PaymentSettings = { cash_on_delivery: true, liqpay: true, monobank: true, payment_test_mode: null }

export async function getPaymentSettings(storeId: string): Promise<PaymentSettings> {
  const rows = await supabaseRequest<PaymentSettings[]>(`/rest/v1/store_payment_methods?store_id=eq.${encodeURIComponent(storeId)}&select=cash_on_delivery,liqpay,monobank,payment_test_mode`, { cache: 'no-store' })
  return rows[0] ?? defaults
}

export async function savePaymentSettings(storeId: string, settings: PaymentMethodSettings, token: string) {
  await supabaseRequest('/rest/v1/store_payment_methods?on_conflict=store_id', {
    method: 'POST', token, headers: { Prefer: 'resolution=merge-duplicates' },
    body: JSON.stringify({ store_id: storeId, ...settings }),
  })
}

export async function setPaymentTestMode(storeId: string, testMode: boolean, token: string) {
  await supabaseRequest('/functions/v1/set-payment-mode', {
    method: 'POST', token, body: JSON.stringify({ storeId, testMode }),
  })
}
