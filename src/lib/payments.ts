import { supabaseRequest } from './supabase'
import type { CartItem, CheckoutInput, Store } from '../types'

export const liqPayEnabled = import.meta.env.VITE_LIQPAY_ENABLED === 'true'
export const monobankEnabled = import.meta.env.VITE_MONOBANK_ENABLED === 'true'
export const novaPoshtaEnabled = import.meta.env.VITE_NOVAPOSHTA_ENABLED === 'true'

type OnlineCheckout = { store: Store; items: CartItem[]; checkout: CheckoutInput; token: string | null; testMode: boolean | null }
type CheckoutPayment = { data?: string; signature?: string; pageUrl?: string; receiptCode?: string }

export async function startLiqPayCheckout(input: OnlineCheckout) {
  return supabaseRequest<CheckoutPayment>('/functions/v1/liqpay-create-checkout', {
    method: 'POST',
    token: input.token,
    body: JSON.stringify({ storeId: input.store.id, items: input.items, checkout: input.checkout, testMode: input.testMode }),
  })
}

export function redirectToLiqPay(data: string, signature: string) {
  const form = document.createElement('form')
  form.method = 'POST'
  form.action = 'https://www.liqpay.ua/api/3/checkout'
  form.acceptCharset = 'utf-8'
  for (const [name, value] of Object.entries({ data, signature })) {
    const input = document.createElement('input')
    input.type = 'hidden'
    input.name = name
    input.value = value
    form.append(input)
  }
  document.body.append(form)
  form.submit()
}

export async function startMonobankCheckout(input: OnlineCheckout) {
  return supabaseRequest<CheckoutPayment>('/functions/v1/monobank-create-invoice', {
    method: 'POST', token: input.token,
    body: JSON.stringify({ storeId: input.store.id, items: input.items, checkout: input.checkout, testMode: input.testMode }),
  })
}

export function manageReservedOrder(orderId: string, action: 'pay' | 'cancel', token: string) {
  return supabaseRequest<{ pageUrl?: string; cancelled?: true }>('/functions/v1/manage-reserved-order', {
    method: 'POST', token, body: JSON.stringify({ orderId, action }),
  })
}
