import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { monobankApi, monobankToken } from './monobank.ts'
import { encodeLiqPayData, liqPayKeys, liqPaySignature } from './liqpay.ts'

// Resolve expired discounted invoices against the bank before releasing their limited use.
export async function reconcileDiscountPayments(client: SupabaseClient, storeId: string, userId: string) {
  const { data, error } = await client.from('online_checkouts')
    .select('id,provider,provider_order_id,test_mode').eq('store_id', storeId).eq('user_id', userId)
    .eq('status', 'PENDING').not('customer_discount_id', 'is', null).lt('expires_at', new Date().toISOString()).limit(20)
  if (error) throw new Error(error.message)
  for (const attempt of data ?? []) {
    if (!attempt.provider_order_id) {
      const { error } = await client.from('online_checkouts').update({ status: 'FAILED' }).eq('id', attempt.id).eq('status', 'PENDING')
      if (error) throw new Error(error.message)
      continue
    }
    let paid = false
    let failed = false
    let amount = NaN
    let currency = ''
    let paymentId: string | null = null
    let callback: unknown
    if (attempt.provider === 'MONOBANK') {
      const token = monobankToken(attempt.test_mode)
      if (!token) continue
      const response = await fetch(`${monobankApi}/invoice/status?invoiceId=${encodeURIComponent(attempt.provider_order_id)}`, {
        headers: { 'X-Token': token }, signal: AbortSignal.timeout(5000),
      })
      if (!response.ok) continue
      const invoice = await response.json()
      if (invoice.invoiceId !== attempt.provider_order_id) continue
      paid = invoice.status === 'success' && invoice.reference === attempt.id
      failed = ['failure', 'expired', 'reversed'].includes(invoice.status)
      amount = invoice.amount
      currency = invoice.ccy === 980 ? 'UAH' : ''
      callback = invoice
    } else {
      const keys = liqPayKeys(attempt.test_mode)
      if (!keys) continue
      const data = encodeLiqPayData({ public_key: keys.publicKey, version: '3', action: 'status', order_id: attempt.provider_order_id })
      const response = await fetch('https://www.liqpay.ua/api/request', {
        method: 'POST', body: new URLSearchParams({ data, signature: await liqPaySignature(keys.privateKey, data) }),
        signal: AbortSignal.timeout(5000),
      })
      if (!response.ok) continue
      const invoice = await response.json()
      paid = invoice.order_id === attempt.provider_order_id && (invoice.status === 'success' || (attempt.test_mode && invoice.status === 'sandbox'))
      failed = (invoice.order_id === attempt.provider_order_id && ['failure', 'error', 'reversed', 'expired'].includes(invoice.status))
        || invoice.err_code === 'order_not_found'
      amount = Math.round(Number(invoice.amount) * 100)
      currency = invoice.currency
      paymentId = invoice.payment_id ? String(invoice.payment_id) : null
      callback = invoice
    }
    if (paid && Number.isSafeInteger(amount) && amount > 0 && currency) {
      const { error } = await client.rpc('confirm_online_checkout', {
        p_provider: attempt.provider, p_reference: attempt.provider_order_id, p_amount: amount,
        p_currency: currency, p_payment_id: paymentId, p_callback: callback,
      })
      if (error) throw new Error(error.message)
    } else if (failed) {
      const { error } = await client.from('online_checkouts').update({ status: 'FAILED' }).eq('id', attempt.id).eq('status', 'PENDING')
      if (error) throw new Error(error.message)
    }
  }
}
