import { createClient } from 'npm:@supabase/supabase-js@2'
import { reconcileDiscountPayments } from '../_shared/discount-payments.ts'
const headers = { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type' }
Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers })
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405, headers })
  try {
    const url = Deno.env.get('SUPABASE_URL')!
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SECRET_KEY')!
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? Deno.env.get('SUPABASE_PUBLISHABLE_KEY')!
    const authorization = request.headers.get('Authorization') ?? ''
    const service = createClient(url, serviceKey)
    const { data, error } = await service.auth.getUser(authorization.replace(/^Bearer /i, ''))
    if (error || !data.user) return new Response(JSON.stringify({ error: 'Authentication required' }), { status: 401, headers })
    const { storeId } = await request.json()
    await reconcileDiscountPayments(service, storeId, data.user.id)
    const client = createClient(url, anonKey, { global: { headers: { Authorization: authorization } } })
    const result = await client.rpc('my_customer_discount', { p_store_id: storeId })
    if (result.error) throw new Error(result.error.message)
    return new Response(JSON.stringify(result.data), { headers })
  } catch (error) {
    return new Response(JSON.stringify({ error: error instanceof Error ? error.message : 'Action failed' }), { status: 400, headers })
  }
})
