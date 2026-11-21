import { createClient } from 'npm:@supabase/supabase-js@2'
import { refundOrderPayment, type RefundOperation } from '../_shared/order-refunds.ts'

const cors = { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type' }
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: cors })

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const url = Deno.env.get('SUPABASE_URL')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? Deno.env.get('SUPABASE_PUBLISHABLE_KEY')
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SECRET_KEY')
  if (!url || !anonKey || !serviceKey) return json({ error: 'Refund service is not configured' }, 503)

  try {
    const auth = createClient(url, anonKey, { global: { headers: { Authorization: request.headers.get('Authorization') ?? '' } } })
    const { data: { user } } = await auth.auth.getUser()
    if (!user) return json({ error: 'Sign in as a store manager first' }, 401)
    const { orderId, method, amount } = await request.json() as { orderId?: string; method?: string; amount?: number }
    if (!orderId || !['automatic', 'manual', 'check'].includes(method ?? '') ||
      (method !== 'check' && (!Number.isSafeInteger(amount) || Number(amount) <= 0))) {
      return json({ error: 'Invalid refund request' }, 400)
    }
    const db = createClient(url, serviceKey)
    const { data, error } = await db.rpc('begin_order_cancellation_refund', {
      p_order_id: orderId, p_actor: user.id, p_method: method, p_amount: amount ?? null,
    })
    if (error) return json({ error: error.message }, error.code === '42501' ? 403 : 409)
    const operation = data as (RefundOperation & { status: string | null }) | null
    if (!operation?.id) return json({ status: operation?.status ?? null })

    const outcome = await refundOrderPayment(operation, method === 'check')
    if (outcome.status === 'processing') return json(outcome)
    const { data: status, error: finishError } = await db.rpc('finish_order_cancellation_refund', {
      p_id: operation.id, p_status: outcome.status, p_error: outcome.error ?? null,
    })
    if (finishError) return json({ error: 'Could not save the refund outcome. Check the status before retrying.' }, 503)
    return json({ status })
  } catch {
    return json({ error: 'Could not process the refund. Check its status before retrying.' }, 400)
  }
})
