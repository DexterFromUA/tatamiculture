import { createClient } from 'npm:@supabase/supabase-js@2'
import { reconcilePayment } from '../_shared/discount-payments.ts'

Deno.serve(async req => {
  if (req.method !== 'POST') return new Response(null, { status: 405 })
  const token = req.headers.get('X-Payment-Job')
  if (!token) return new Response(null, { status: 403 })
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const auth = await db.rpc('is_payment_check_job', { p_token: token })
  if (auth.error || !auth.data) return new Response(null, { status: 403 })
  const { data, error } = await db.rpc('claim_payment_checks')
  if (error) return new Response(null, { status: 503 })
  for (let offset = 0; offset < data.length; offset += 6) {
    const batch = data.slice(offset, offset + 6) as Array<{
      id: string; provider: string; provider_order_id: string | null; test_mode: boolean; expires_at: string
    }>
    await Promise.all(batch.map(async attempt => {
      const reason = await reconcilePayment(db, attempt, Date.parse(attempt.expires_at) < Date.now())
        .catch(() => 'Payment details require review')
      const update = await db.from('online_checkouts').update({ bank_review_reason: reason })
        .eq('id', attempt.id).eq('status', 'PENDING')
      if (update.error) throw update.error
    }))
  }
  return Response.json({ checked: data.length })
})
