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
    const { orderId, method, amount, attemptId, resolution } = await request.json() as {
      orderId?: string; method?: string; amount?: number; attemptId?: string; resolution?: string
    }
    const reviewing = method === 'review'
    const readOnly = method === 'check' || reviewing
    if (!orderId || !['automatic', 'manual', 'check', 'review'].includes(method ?? '') ||
      (method !== 'check' && (!Number.isSafeInteger(amount) || Number(amount) <= 0)) ||
      (reviewing && (!attemptId || !['record_paid', 'not_started'].includes(resolution ?? '')))) {
      return json({ error: 'Invalid refund request' }, 400)
    }
    const db = createClient(url, serviceKey)
    const { data, error } = await db.rpc('begin_order_cancellation_refund', {
      p_order_id: orderId, p_actor: user.id, p_method: readOnly ? 'check' : method, p_amount: amount ?? null,
    })
    if (error) return json({ error: error.message }, error.code === '42501' ? 403 : 409)
    const operation = data as (RefundOperation & { status: string | null }) | null
    if (!operation?.id) return json({ status: operation?.status ?? null })
    if (reviewing && (operation.id !== attemptId || operation.amount !== amount)) {
      return json({ error: 'The refund has changed or is still being processed. Check its status again.' }, 409)
    }

    const outcome = await refundOrderPayment(operation, readOnly)
    if (outcome.status === 'processing') {
      if (!outcome.absenceVerified) {
        return reviewing
          ? json({ error: 'The bank has not confirmed the refund state. Check its status again.' }, 409)
          : json({ status: 'processing' })
      }
      if (reviewing) {
        const { data: status, error: reviewError } = await db.rpc('resolve_order_cancellation_refund', {
          p_order_id: orderId, p_attempt_id: operation.id, p_actor: user.id, p_resolution: resolution,
        })
        if (reviewError) return json({ error: reviewError.message }, reviewError.code === '42501' ? 403 : 409)
        return json({ status })
      }
      const { data: allowed, error: reviewError } = await db.rpc('can_review_order_refund', { p_id: operation.id })
      if (reviewError) return json({ error: 'Could not check the refund. Try again later.' }, 503)
      return json({ status: 'processing', reviewAttemptId: allowed ? operation.id : undefined })
    }
    const { data: status, error: finishError } = await db.rpc('finish_order_cancellation_refund', {
      p_id: operation.id, p_status: outcome.status, p_error: outcome.error ?? null,
    })
    if (finishError) return json({ error: 'Could not save the refund outcome. Check the status before retrying.' }, 503)
    return json({ status })
  } catch {
    return json({ error: 'Could not process the refund. Check its status before retrying.' }, 400)
  }
})
