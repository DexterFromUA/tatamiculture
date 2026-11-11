import { createClient } from 'npm:@supabase/supabase-js@2'
import { CheckoutOrderError, prepareOnlineCheckout, getCheckoutTestMode, paymentReturnUrl } from '../_shared/checkout-order.ts'
import { monobankApi, monobankToken } from '../_shared/monobank.ts'

type Body = {
  storeId: string
  testMode?: boolean
  items: Array<{ optionId: string; quantity: number }>
  checkout: { name: string; email: string; phone: string; city: string; address: string; note: string; cityRef?: string; addressRef?: string; deliveryServiceType?: string }
}

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type' } })

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type' } })
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? Deno.env.get('SUPABASE_PUBLISHABLE_KEY')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SECRET_KEY')
  const siteUrl = Deno.env.get('SITE_URL')?.replace(/\/$/, '')
  if (!supabaseUrl || !anonKey || !serviceRoleKey) return json({ error: 'Monobank is not configured' }, 503)

  try {
    const body = await request.json() as Body
    const serviceClient = createClient(supabaseUrl, serviceRoleKey)
    const testMode = await getCheckoutTestMode(serviceClient, body.storeId, 'MONOBANK', body.testMode)
    const monoToken = monobankToken(testMode)
    if (!monoToken) return json({ error: testMode ? 'Monobank test mode requires a separate test token.' : 'Monobank is not configured' }, 503)
    const email = typeof body.checkout.email === 'string' ? body.checkout.email.trim() : ''
    const customerEmail = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ? email : ''
    body.checkout.email = customerEmail
    const attempt = await prepareOnlineCheckout(serviceClient, request, anonKey, 'MONOBANK', body, testMode)

    const invoiceRequest = {
      amount: Number(attempt.total_price), ccy: 980, validity: 3600, paymentType: 'debit',
      merchantPaymInfo: {
        reference: attempt.id, destination: `${testMode ? 'TEST · ' : ''}tatami.culture order ${attempt.receipt_code}`, comment: body.checkout.note || `tatami.culture order ${attempt.receipt_code}`,
        ...(customerEmail && !testMode ? { customerEmails: [customerEmail] } : {}),
        basketOrder: attempt.items.map((item) => ({ name: `${item.product_name} (${item.variant_name})`, qty: item.quantity, sum: Number(item.unit_price), total: Number(item.unit_price) * item.quantity, unit: 'pcs' })),
      },
      redirectUrl: paymentReturnUrl(siteUrl, attempt.receipt_code),
      webHookUrl: `${supabaseUrl}/functions/v1/monobank-webhook`,
    }
    const invoiceResponse = await fetch(`${monobankApi}/invoice/create`, { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Token': monoToken }, body: JSON.stringify(invoiceRequest) })
    const invoice = await invoiceResponse.json() as { invoiceId?: string; pageUrl?: string; errText?: string }
    if (!invoiceResponse.ok || !invoice.invoiceId || !invoice.pageUrl) throw new Error(invoice.errText ?? 'Monobank could not create an invoice')
    const { error: linkError } = await serviceClient.from('online_checkouts')
      .update({ provider_order_id: invoice.invoiceId }).eq('id', attempt.id)
      .is('provider_order_id', null).select('id').single()
    if (linkError) throw new Error(linkError.message)
    return json({ pageUrl: invoice.pageUrl, receiptCode: attempt.receipt_code })
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : 'Checkout could not be started' }, error instanceof CheckoutOrderError ? error.status : 400)
  }
})
