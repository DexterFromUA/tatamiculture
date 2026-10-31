import { createClient } from 'npm:@supabase/supabase-js@2'

type Callback = { invoiceId?: string; status?: string }

Deno.serve(async (request) => {
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 })
  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SECRET_KEY')
  const monoToken = Deno.env.get('MONOBANK_TOKEN')?.trim()
  if (!supabaseUrl || !serviceRoleKey || !monoToken) return new Response('Not configured', { status: 503 })
  try {
    const raw = await request.text()
    const callback = JSON.parse(raw) as Callback
    if (!callback.invoiceId) return new Response('Missing invoice ID', { status: 400 })
    // Confirm status directly with Monobank. This keeps the public webhook safe
    // even if a forged callback is sent without a valid X-Sign signature.
    const statusResponse = await fetch(`https://api.monobank.ua/api/merchant/invoice/status?invoiceId=${encodeURIComponent(callback.invoiceId)}`, { headers: { 'X-Token': monoToken } })
    const invoice = await statusResponse.json() as { status?: string }
    if (!statusResponse.ok) throw new Error('Monobank status check failed')
    const paymentStatus = invoice.status === 'success' ? 'PAID' : invoice.status === 'failure' || invoice.status === 'expired' ? 'FAILED' : 'PENDING'
    const client = createClient(supabaseUrl, serviceRoleKey)
    const { error: paymentError } = await client.from('payments').update({ status: paymentStatus, raw_callback: JSON.parse(raw) }).eq('provider_order_id', callback.invoiceId).eq('provider', 'MONOBANK')
    if (paymentError) throw paymentError
    if (paymentStatus === 'PAID') {
      const { data: payment } = await client.from('payments').select('order_id').eq('provider_order_id', callback.invoiceId).eq('provider', 'MONOBANK').single()
      if (payment?.order_id) await client.from('orders').update({ status: 'PAID', payment_status: 'PAID' }).eq('id', payment.order_id)
    } else if (paymentStatus === 'FAILED') {
      const { data: payment } = await client.from('payments').select('order_id').eq('provider_order_id', callback.invoiceId).eq('provider', 'MONOBANK').single()
      if (payment?.order_id) await client.from('orders').update({ payment_status: 'FAILED' }).eq('id', payment.order_id)
    }
    return new Response('OK')
  } catch (error) { return new Response(error instanceof Error ? error.message : 'Webhook failed', { status: 400 }) }
})
