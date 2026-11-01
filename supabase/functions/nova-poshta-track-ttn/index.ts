import { createClient } from 'npm:@supabase/supabase-js@2'

const cors = { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type' }
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: cors })

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? Deno.env.get('SUPABASE_PUBLISHABLE_KEY')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SECRET_KEY')
  if (!supabaseUrl || !anonKey || !serviceRoleKey) return json({ error: 'Supabase is not configured' }, 503)
  try {
    const { orderId } = await request.json() as { orderId?: string }
    if (!orderId) throw new Error('Order is required')
    const auth = createClient(supabaseUrl, anonKey, { global: { headers: { Authorization: request.headers.get('Authorization') ?? `Bearer ${anonKey}` } } })
    const { data: user } = await auth.auth.getUser()
    if (!user.user) return json({ error: 'Sign in as a store manager first' }, 401)
    const db = createClient(supabaseUrl, serviceRoleKey)
    const { data: order } = await db.from('orders').select('*').eq('id', orderId).maybeSingle()
    if (!order?.nova_poshta_ttn) throw new Error('Create a TTN first')
    const { data: member } = await db.from('store_members').select('role').eq('store_id', order.store_id).eq('user_id', user.user.id).maybeSingle()
    if (!member) return json({ error: 'You do not have access to this order' }, 403)
    const { data: settings } = await db.from('delivery_settings').select('nova_post_test_mode,sender_phone').eq('store_id', order.store_id).maybeSingle()
    const key = settings?.nova_post_test_mode ? Deno.env.get('NOVA_POSHTA_TEST_API_KEY')?.trim() : Deno.env.get('NOVA_POSHTA_API_KEY')?.trim()
    if (!key) throw new Error('Nova Poshta API key is not configured')
    const response = await fetch('https://api.novaposhta.ua/v2.0/json/', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ apiKey: key, modelName: 'TrackingDocument', calledMethod: 'getStatusDocuments', methodProperties: { Documents: [{ DocumentNumber: order.nova_poshta_ttn, Phone: String(settings?.sender_phone ?? '').replace(/\D/g, '') }] } }) })
    const result = await response.json() as { success?: boolean; data?: Array<{ Status?: string; StatusCode?: string }> ; errors?: string[] }
    const tracking = result.data?.[0]
    if (!response.ok || !result.success || !tracking?.Status) throw new Error(result.errors?.join(', ') || 'Nova Poshta tracking is unavailable')
    const changed = order.nova_poshta_status_code !== (tracking.StatusCode ?? '') || order.nova_poshta_status !== tracking.Status
    await db.from('orders').update({ nova_poshta_status: tracking.Status, nova_poshta_status_code: tracking.StatusCode ?? '', nova_poshta_status_updated_at: new Date().toISOString() }).eq('id', order.id)
    if (changed) await db.from('order_delivery_events').insert({ order_id: order.id, status_code: tracking.StatusCode ?? '', status_text: tracking.Status })
    return json({ status: tracking.Status, code: tracking.StatusCode ?? '', changed })
  } catch (error) { return json({ error: error instanceof Error ? error.message : 'Tracking could not be updated' }, 400) }
})
