import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'
import { CheckoutOrderError, paymentReturnUrl } from './checkout-order.ts'
import { encodeLiqPayData, liqPayKeys, liqPaySignature } from './liqpay.ts'
import { monobankApi, monobankToken } from './monobank.ts'

type ReservedOrder = {
  id: string
  receipt_code: string
  total_price: number
  currency: string
  customer_phone: string
  customer_email: string
  payment_test_mode: boolean | null
  monobank_test_mode: boolean
}

type Payment = {
  id: string
  provider: 'MONOBANK' | 'LIQPAY'
  provider_order_id: string
  checkout_url: string | null
  checkout_managed: boolean
  checkout_started: boolean
}

const unavailable = () => new CheckoutOrderError('The payment provider could not confirm the invoice status. Try again shortly.', 502)
const pending = () => new CheckoutOrderError('The payment is being processed. Check the order status shortly.', 409)

const paymentHosts = {
  MONOBANK: new Set(['pay.monobank.ua', 'pay.mbnk.biz']),
  LIQPAY: new Set(['liqpay.ua', 'www.liqpay.ua']),
}

function paymentLink(provider: Payment['provider'], href: string) {
  const url = new URL(href)
  if (url.protocol !== 'https:' || !paymentHosts[provider].has(url.host)) throw unavailable()
  return { pageUrl: url.href }
}

export async function manageReservedPayment(
  client: SupabaseClient, order: ReservedOrder, userId: string, action: 'pay' | 'cancel',
  supabaseUrl: string, siteUrl?: string,
) {
  const operation = crypto.randomUUID()
  const { data: payment, error: beginError } = await client.rpc('begin_reserved_order_action', {
    p_order_id: order.id, p_user_id: userId, p_operation: operation,
  }).single<Payment>()
  if (beginError || !payment) {
    throw new CheckoutOrderError(beginError?.message ?? 'Order not found', beginError?.code === 'PT404' ? 404 : 409)
  }

  const updatePayment = async (values: Record<string, unknown>) => {
    const { error } = await client.from('payments').update(values)
      .eq('id', payment.id).eq('checkout_operation', operation).gt('checkout_operation_until', new Date().toISOString())
      .in('status', ['PENDING', 'FAILED']).select('id').single()
    if (error) throw pending()
  }
  const returnUrl = paymentReturnUrl(siteUrl, order.receipt_code)
  const testMode = order.payment_test_mode ?? order.monobank_test_mode
  const description = `${testMode ? 'TEST · ' : ''}tatami.culture order ${order.receipt_code}`
  let reference = payment.provider_order_id

  const cancelOrder = async () => {
    const { error } = await client.rpc('cancel_customer_reservation', {
      p_order_id: order.id, p_user_id: userId, p_operation: operation, p_provider_order_id: reference,
    })
    if (error) throw new CheckoutOrderError(error.message, 409)
    return { cancelled: true as const }
  }

  const recordPaid = async (callback: unknown, amount: number, currency: string, paymentId: string | null = null) => {
    if (amount !== order.total_price || currency !== order.currency) throw unavailable()
    const { error } = await client.rpc('apply_online_payment_callback', {
      p_provider: payment.provider, p_reference: reference, p_paid: true, p_payment_id: paymentId, p_callback: callback,
    })
    if (error) throw unavailable()
    throw new CheckoutOrderError('This reservation is no longer awaiting payment.', 409)
  }

  try {
    if (payment.provider === 'MONOBANK') {
      const token = monobankToken(testMode)
      if (!token) throw unavailable()
      const headers = { 'X-Token': token, 'Content-Type': 'application/json' }
      // Managed rows keep the order ID as a placeholder until an invoice can be
      // published. Legacy Monobank rows always contain a real invoice ID.
      if (reference !== order.id) {
        const response = await fetch(`${monobankApi}/invoice/status?invoiceId=${encodeURIComponent(reference)}`, {
          headers, signal: AbortSignal.timeout(6000),
        })
        if (!response.ok && response.status !== 404) throw unavailable()
        if (response.ok) {
          const invoice = await response.json() as { status?: string; invoiceId?: string; amount?: number; ccy?: number }
          const state = invoice.status
          if (state === 'success' && invoice.invoiceId === reference) {
            return await recordPaid(invoice, invoice.amount ?? NaN, invoice.ccy === 980 ? 'UAH' : '')
          }
          if (state === 'processing' || state === 'hold' || state === 'reversed') throw pending()
          if (state !== 'created' && state !== 'failure' && state !== 'expired') throw unavailable()
          if (state === 'created' && action === 'pay' && payment.checkout_url) return paymentLink('MONOBANK', payment.checkout_url)
          if (state !== 'expired') {
            const removed = await fetch(`${monobankApi}/invoice/remove`, {
              method: 'POST', headers, body: JSON.stringify({ invoiceId: reference }), signal: AbortSignal.timeout(6000),
            })
            if (!removed.ok) throw unavailable()
          }
        }
      }
      if (action === 'cancel') return await cancelOrder()
      const { data: items, error } = await client.from('order_items')
        .select('product_name,variant_name,quantity,unit_price').eq('order_id', order.id)
      if (error || !items?.length || order.currency !== 'UAH') throw unavailable()
      const response = await fetch(`${monobankApi}/invoice/create`, {
        method: 'POST', headers, signal: AbortSignal.timeout(8000),
        body: JSON.stringify({
          amount: order.total_price, ccy: 980, validity: 3600, paymentType: 'debit',
          merchantPaymInfo: {
            reference: order.id, destination: description,
            ...(order.customer_email && !testMode ? { customerEmails: [order.customer_email] } : {}),
            basketOrder: items.map(item => ({
              name: `${item.product_name} (${item.variant_name})`, qty: item.quantity,
              sum: item.unit_price, total: item.unit_price * item.quantity, unit: 'pcs',
            })),
          },
          redirectUrl: returnUrl, webHookUrl: `${supabaseUrl}/functions/v1/monobank-webhook`,
        }),
      })
      const invoice = await response.json() as { invoiceId?: string; pageUrl?: string }
      if (!response.ok || !invoice.invoiceId || !invoice.pageUrl) throw unavailable()
      const link = paymentLink('MONOBANK', invoice.pageUrl)
      await updatePayment({ provider_order_id: invoice.invoiceId, checkout_url: link.pageUrl, checkout_managed: true, status: 'PENDING' })
      return link
    }

    if (!payment.checkout_managed) {
      throw new CheckoutOrderError('This order uses an older LiqPay payment link. Contact the store to manage the reservation.', 409)
    }
    const keys = liqPayKeys(testMode)
    if (!keys) throw unavailable()
    const liqPay = async (action: string, fields: Record<string, unknown> = {}) => {
      const data = encodeLiqPayData({
        version: '3', public_key: keys.publicKey, action, order_id: reference,
        ...(testMode ? { sandbox: 1 } : {}), ...fields,
      })
      const response = await fetch('https://www.liqpay.ua/api/request', {
        method: 'POST', body: new URLSearchParams({ data, signature: await liqPaySignature(keys.privateKey, data) }),
        signal: AbortSignal.timeout(8000),
      })
      if (!response.ok) throw unavailable()
      return await response.json() as {
        status?: string; result?: string; href?: string; order_id?: string; payment_id?: string | number;
        amount?: string | number; currency?: string;
      }
    }

    if (payment.checkout_started) {
      const invoice = await liqPay('status')
      if ((invoice.status === 'success' || (testMode && invoice.status === 'sandbox')) && invoice.order_id === reference) {
        return await recordPaid(invoice, Math.round(Number(invoice.amount) * 100), invoice.currency ?? '',
          invoice.payment_id ? String(invoice.payment_id) : null)
      }
      if (invoice.status === 'invoice_wait' && action === 'pay' && payment.checkout_url) return paymentLink('LIQPAY', payment.checkout_url)
      if (!['invoice_wait', 'failure', 'error'].includes(invoice.status ?? '')) throw pending()
      const removed = await liqPay('invoice_cancel')
      if (removed.result !== 'ok') throw unavailable()
      // Persist the invalidation before trying to create another payable invoice.
      await updatePayment({ checkout_started: false, checkout_url: null })
    }
    if (action === 'cancel') return await cancelOrder()

    reference = crypto.randomUUID()
    await updatePayment({ provider_order_id: reference, checkout_started: true, checkout_url: null, status: 'PENDING' })
    const phone = order.customer_phone.replace(/\D/g, '').replace(/^0(?=\d{9}$)/, '380')
    const email = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(order.customer_email) ? order.customer_email : ''
    const invoice = await liqPay('invoice_send', {
      amount: order.total_price / 100, currency: order.currency, description, language: 'uk',
      ...(email ? { email } : { phone }),
      action_payment: 'pay', result_url: returnUrl, server_url: `${supabaseUrl}/functions/v1/liqpay-webhook`,
    })
    if (invoice.result === 'error' && !invoice.href) {
      await updatePayment({ checkout_started: false })
      throw unavailable()
    }
    if (invoice.result !== 'ok' || !invoice.href || invoice.status !== 'invoice_wait') throw unavailable()
    const link = paymentLink('LIQPAY', invoice.href)
    await updatePayment({ checkout_url: link.pageUrl })
    return link
  } finally {
    await client.from('payments').update({ checkout_operation: null, checkout_operation_until: null })
      .eq('id', payment.id).eq('checkout_operation', operation)
  }
}
