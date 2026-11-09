import { createClient } from 'npm:@supabase/supabase-js@2'
import { liqPayKeys } from '../_shared/liqpay.ts'
import { monobankToken } from '../_shared/monobank.ts'

const headers = {
  'Content-Type': 'application/json',
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers })

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers })
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const url = Deno.env.get('SUPABASE_URL')
  const key = Deno.env.get('SUPABASE_ANON_KEY') ?? Deno.env.get('SUPABASE_PUBLISHABLE_KEY')
  const authorization = request.headers.get('Authorization')
  if (!url || !key) return json({ error: 'Supabase is not configured' }, 503)
  if (!authorization?.startsWith('Bearer ')) return json({ error: 'Sign in required' }, 401)

  try {
    const body = await request.json().catch(() => null)
    if (typeof body?.storeId !== 'string' || typeof body.testMode !== 'boolean') {
      return json({ error: 'Invalid payment mode' }, 400)
    }
    const { storeId, testMode } = body as { storeId: string; testMode: boolean }
    const client = createClient(url, key, { global: { headers: { Authorization: authorization } } })
    const { data: auth, error: authError } = await client.auth.getUser()
    if (authError || !auth.user) return json({ error: 'Sign in required' }, 401)
    const { data: membership, error: memberError } = await client.from('store_members').select('role')
      .eq('store_id', storeId).eq('user_id', auth.user.id).maybeSingle()
    if (memberError || !membership) return json({ error: 'Manager access required' }, 403)

    const { data: settings, error: settingsError } = await client.from('store_payment_methods')
      .select('monobank,liqpay').eq('store_id', storeId).maybeSingle()
    if (settingsError) throw settingsError
    if (settings?.monobank !== false && !monobankToken(testMode)) {
      return json({ error: testMode ? 'Monobank test mode requires a separate test token.' : 'Monobank live token is not configured.' }, 409)
    }
    if (settings?.liqpay !== false && !liqPayKeys(testMode)) {
      return json({ error: testMode ? 'LiqPay test keys are not configured.' : 'LiqPay live keys are not configured.' }, 409)
    }
    const { error } = await client.from('store_payment_methods')
      .upsert({ store_id: storeId, payment_test_mode: testMode }, { onConflict: 'store_id' })
    if (error) throw error
    return json({ testMode })
  } catch {
    return json({ error: 'Could not save payment mode.' }, 502)
  }
})
