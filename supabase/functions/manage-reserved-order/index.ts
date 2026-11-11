import { createClient } from 'npm:@supabase/supabase-js@2'
import { CheckoutOrderError } from '../_shared/checkout-order.ts'
import { manageReservedPayment } from '../_shared/reserved-payment.ts'

const headers = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Content-Type': 'application/json',
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers })

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response(null, { headers })
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const url = Deno.env.get('SUPABASE_URL')
  const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SECRET_KEY')
  if (!url || !key) return json({ error: 'Payment service is not configured' }, 503)
  const token = request.headers.get('Authorization')?.match(/^Bearer (.+)$/i)?.[1]
  if (!token) return json({ error: 'Sign in required' }, 401)

  const client = createClient(url, key)
  const { data: { user }, error: authError } = await client.auth.getUser(token)
  if (authError || !user) return json({ error: 'Sign in required' }, 401)

  try {
    const { orderId, action } = await request.json()
    if (typeof orderId !== 'string' || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(orderId)
        || (action !== 'pay' && action !== 'cancel')) {
      return json({ error: 'Invalid reservation action' }, 400)
    }
    const { data: order, error } = await client.from('orders')
      .select('id,receipt_code,total_price,currency,customer_phone,customer_email,payment_test_mode,monobank_test_mode')
      .eq('id', orderId).eq('user_id', user.id).maybeSingle()
    if (error) throw new Error(error.message)
    if (!order) return json({ error: 'Order not found' }, 404)

    const siteUrl = Deno.env.get('SITE_URL')?.replace(/\/$/, '')
    return json(await manageReservedPayment(client, order, user.id, action, url, siteUrl))
  } catch (error) {
    if (error instanceof CheckoutOrderError) return json({ error: error.message }, error.status)
    console.error('Reserved order action failed', error)
    return json({ error: 'Could not update the reservation. Try again shortly.' }, 502)
  }
})
