import { createClient, type SupabaseClient } from 'npm:@supabase/supabase-js@2'

const cors = { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type' }
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: cors })

type Shipment = { store_id: string; ttn: string; sender_phone: string }
type Tracking = { Number?: string | number; Status?: string; StatusCode?: string | number; DatePayedKeeping?: string }

function paidStorageFrom(value: unknown) {
  if (typeof value !== 'string') return null
  const iso = /^(20\d{2})-(\d{2})-(\d{2})(?:$|[ T])/.exec(value.trim())
  const localized = /^(\d{2})\.(\d{2})\.(20\d{2})(?:$|\s)/.exec(value.trim())
  const day = iso ? iso[0].slice(0, 10) : localized ? `${localized[3]}-${localized[2]}-${localized[1]}` : null
  if (!day) return null
  const date = new Date(`${day}T00:00:00Z`)
  return Number.isFinite(date.getTime()) && date.toISOString().slice(0, 10) === day ? day : null
}

async function trackShipments(db: SupabaseClient, key: string, shipments: Shipment[]) {
  const checkedAt = new Date().toISOString()
  const response = await fetch('https://api.novaposhta.ua/v2.0/json/', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, signal: AbortSignal.timeout(8000),
    body: JSON.stringify({
      apiKey: key, modelName: 'TrackingDocument', calledMethod: 'getStatusDocuments',
      methodProperties: { Documents: shipments.map(({ ttn, sender_phone }) => ({
        DocumentNumber: ttn, Phone: sender_phone.replace(/\D/g, ''),
      })) },
    }),
  })
  const result = await response.json() as { success?: boolean; data?: Tracking[]; errors?: string[] }
  if (!response.ok || !result.success) throw new Error(result.errors?.join(', ') || 'Nova Poshta tracking is unavailable')
  const byNumber = new Map(result.data?.map(tracking => [String(tracking.Number ?? ''), tracking]))
  return await Promise.allSettled(shipments.map(async shipment => {
    const tracking = byNumber.get(shipment.ttn) ?? (shipments.length === 1 && !result.data?.[0]?.Number ? result.data?.[0] : undefined)
    if (!tracking?.Status) throw new Error('Nova Poshta returned no status for this TTN')
    const code = String(tracking.StatusCode ?? '')
    const { data: changed, error } = await db.rpc('apply_nova_poshta_tracking_with_storage', {
      p_store_id: shipment.store_id, p_ttn: shipment.ttn,
      p_status: tracking.Status, p_code: code, p_checked_at: checkedAt,
      p_paid_storage_from: paidStorageFrom(tracking.DatePayedKeeping),
    })
    if (error) throw error
    return { status: tracking.Status, code, changed }
  }))
}

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const url = Deno.env.get('SUPABASE_URL')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? Deno.env.get('SUPABASE_PUBLISHABLE_KEY')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SECRET_KEY')
  const key = Deno.env.get('NOVA_POSHTA_API_KEY')?.trim()
  if (!url || !anonKey || !serviceRoleKey || !key) return json({ error: 'Nova Poshta tracking is not configured' }, 503)
  const db = createClient(url, serviceRoleKey)

  try {
    const jobToken = request.headers.get('X-Tracking-Job')
    if (jobToken) {
      const { data: allowed, error: authError } = await db.rpc('is_nova_poshta_tracking_job', { p_token: jobToken })
      if (authError) throw authError
      if (!allowed) return json({ error: 'Invalid tracking job credentials' }, 403)
      const { data, error } = await db.rpc('active_nova_poshta_shipments')
      if (error) throw error
      const shipments = (data ?? []) as Shipment[]
      let updated = 0
      let failed = 0
      for (let offset = 0; offset < shipments.length; offset += 25) {
        const batch = shipments.slice(offset, offset + 25)
        try {
          const results = await trackShipments(db, key, batch)
          updated += results.filter(result => result.status === 'fulfilled').length
          failed += results.filter(result => result.status === 'rejected').length
        } catch {
          failed += batch.length
        }
      }
      return json({ updated, failed }, failed && !updated ? 502 : 200)
    }

    const auth = createClient(url, anonKey, { global: { headers: { Authorization: request.headers.get('Authorization') ?? '' } } })
    const { data: { user } } = await auth.auth.getUser()
    if (!user) return json({ error: 'Sign in as a store manager first' }, 401)
    const { orderId } = await request.json() as { orderId?: string }
    if (!orderId) return json({ error: 'Order is required' }, 400)
    const { data: order, error: orderError } = await db.from('orders').select('store_id,nova_poshta_ttn').eq('id', orderId).maybeSingle()
    if (orderError) throw orderError
    if (!order) return json({ error: 'Order was not found' }, 404)
    const { data: member, error: memberError } = await db.from('store_members').select('role').eq('store_id', order.store_id).eq('user_id', user.id).maybeSingle()
    if (memberError) throw memberError
    if (!member) return json({ error: 'You do not have access to this order' }, 403)
    if (!order.nova_poshta_ttn) return json({ error: 'Create a TTN first' }, 400)
    if (order.nova_poshta_ttn.startsWith('TEST-')) return json({ error: 'This TTN is no longer supported. Unlink it and add a current TTN.' }, 409)
    const { data: settings, error: settingsError } = await db.from('delivery_settings').select('sender_phone').eq('store_id', order.store_id).maybeSingle()
    if (settingsError) throw settingsError

    const [result] = await trackShipments(db, key, [{ store_id: order.store_id, ttn: order.nova_poshta_ttn, sender_phone: settings?.sender_phone ?? '' }])
    if (result.status === 'rejected') throw result.reason
    return json(result.value)
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : 'Tracking could not be updated' }, 502)
  }
})
