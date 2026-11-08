import { createClient } from 'npm:@supabase/supabase-js@2'
import { CheckoutOrderError, createOnlineOrder } from '../_shared/checkout-order.ts'

type Body = {
  storeId: string
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
  const monoToken = Deno.env.get('MONOBANK_TOKEN')?.trim()
  const siteUrl = Deno.env.get('SITE_URL')?.replace(/\/$/, '')
  if (!supabaseUrl || !anonKey || !serviceRoleKey || !monoToken) return json({ error: 'Monobank is not configured' }, 503)

  try {
    const body = await request.json() as Body
    const serviceClient = createClient(supabaseUrl, serviceRoleKey)
    const order = await createOnlineOrder(serviceClient, request, anonKey, 'MONOBANK', body)
    const { data: items, error: itemsError } = await serviceClient.from('order_items').select('product_name,variant_name,quantity,unit_price').eq('order_id', order.id)
    if (itemsError || !items?.length) throw new Error(itemsError?.message ?? 'Order has no items')

    const invoiceRequest = {
      amount: Number(order.total_price), ccy: 980, validity: 3600, paymentType: 'debit',
      merchantPaymInfo: {
        reference: order.id, destination: `tatami.culture order ${order.receipt_code}`, comment: body.checkout.note || `tatami.culture order ${order.receipt_code}`,
        customerEmails: [body.checkout.email],
        basketOrder: items.map((item) => ({ name: `${item.product_name} (${item.variant_name})`, qty: item.quantity, sum: Number(item.unit_price), total: Number(item.unit_price) * item.quantity, unit: 'pcs' })),
      },
      ...(siteUrl && !/^https?:\/\/(localhost|127\.0\.0\.1)(?::\d+)?$/i.test(siteUrl) ? { redirectUrl: `${siteUrl}/receipt/${order.receipt_code}?payment=return` } : {}),
      webHookUrl: `${supabaseUrl}/functions/v1/monobank-webhook`,
    }
    const invoiceResponse = await fetch('https://api.monobank.ua/api/merchant/invoice/create', { method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Token': monoToken }, body: JSON.stringify(invoiceRequest) })
    const invoice = await invoiceResponse.json() as { invoiceId?: string; pageUrl?: string; errText?: string }
    if (!invoiceResponse.ok || !invoice.invoiceId || !invoice.pageUrl) throw new Error(invoice.errText ?? 'Monobank could not create an invoice')
    const { error: paymentError } = await serviceClient.from('payments').insert({ order_id: order.id, provider: 'MONOBANK', provider_order_id: invoice.invoiceId, status: 'PENDING' })
    if (paymentError) throw new Error(paymentError.message)
    return json({ pageUrl: invoice.pageUrl })
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : 'Checkout could not be started' }, error instanceof CheckoutOrderError ? error.status : 400)
  }
})
