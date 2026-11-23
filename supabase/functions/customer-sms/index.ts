import { createClient } from 'npm:@supabase/supabase-js@2'
import { configuredSecret, sendSmsClub, smsClubCredentials, smsClubHookQuery } from '../_shared/sms-auth.ts'

type Delivery = { id: string; phone: string; body: string }

async function smsClubSelected(url: string) {
  const project = new URL(url).hostname.match(/^([a-z0-9]+)\.supabase\.co$/)?.[1]
  const token = configuredSecret('SMS_AUTH_MANAGEMENT_TOKEN')
  if (!project || !token) throw new Error('SMS provider configuration unavailable')
  const response = await fetch(`https://api.supabase.com/v1/projects/${project}/config/auth`, {
    headers: { Authorization: `Bearer ${token}` }, signal: AbortSignal.timeout(5000),
  })
  if (!response.ok) throw new Error('SMS provider settings unavailable')
  const config = await response.json()
  const hook = new URL(`/functions/v1/send-auth-sms${smsClubHookQuery}`, url).href
  return config.hook_send_sms_enabled === true && config.hook_send_sms_uri === hook
}

Deno.serve(async request => {
  if (request.method !== 'POST') return new Response(null, { status: 405 })
  const token = request.headers.get('X-Push-Job')
  if (!token) return new Response(null, { status: 403 })
  const credentials = smsClubCredentials()
  if (!credentials) return new Response(null, { status: 503 })

  const url = Deno.env.get('SUPABASE_URL')!
  const db = createClient(url, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const authorization = await db.rpc('customer_sms_job_authorized', { p_token: token })
  if (authorization.error) return new Response(null, { status: 503 })
  if (authorization.data !== true) return new Response(null, { status: 403 })
  try {
    if (!await smsClubSelected(url)) return Response.json({ claimed: 0, accepted: 0, paused: true })
  } catch {
    return new Response(null, { status: 503 })
  }
  const { data, error } = await db.rpc('claim_customer_sms_deliveries', { p_token: token })
  if (error) return new Response(null, { status: error.code === '42501' ? 403 : 503 })

  const deliveries = (data ?? []) as Delivery[]
  let accepted = 0
  // A timeout could mean the provider already accepted the message. A claimed SMS is never sent again.
  for (let index = 0; index < deliveries.length; index += 5) {
    await Promise.all(deliveries.slice(index, index + 5).map(async delivery => {
      let sent = false
      try {
        await sendSmsClub(credentials, delivery.phone, delivery.body)
        sent = true
        accepted++
      } catch (error) {
        console.warn('SMSClub did not confirm a notification', delivery.id, error instanceof Error ? error.name : '')
      }
      const result = await db.rpc('complete_customer_sms_delivery', { p_token: token, p_id: delivery.id, p_accepted: sent })
      if (result.error) console.error('Could not record SMS submission result', delivery.id, result.error.code)
    }))
  }

  return Response.json({ claimed: deliveries.length, accepted })
})
