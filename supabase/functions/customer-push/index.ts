import { createClient } from 'npm:@supabase/supabase-js@2'
import webPush from 'npm:web-push@3.6.7'
import { notificationCopy } from './copy.ts'

type Delivery = {
  id: string
  subscription_id: string
  endpoint: string
  p256dh: string
  auth_secret: string
  language: 'uk' | 'en'
  kind: string
  path: string
}

const configHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Cache-Control': 'no-store',
}

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: configHeaders })
  const publicKey = Deno.env.get('WEB_PUSH_PUBLIC_KEY')
  const privateKey = Deno.env.get('WEB_PUSH_PRIVATE_KEY')
  const subject = Deno.env.get('WEB_PUSH_SUBJECT')
  if (request.method === 'GET') {
    return Response.json({ publicKey: privateKey && subject ? publicKey ?? null : null }, { headers: configHeaders })
  }
  if (request.method !== 'POST') return new Response(null, { status: 405 })
  const token = request.headers.get('X-Push-Job')
  if (!token) return new Response(null, { status: 403 })
  if (!publicKey || !privateKey || !subject) return new Response(null, { status: 503 })

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!)
  const { data, error } = await db.rpc('claim_customer_push_deliveries', { p_token: token })
  if (error) return new Response(null, { status: error.code === '42501' ? 403 : 503 })

  let sent = 0
  const deliveries = (data ?? []) as Delivery[]
  for (let offset = 0; offset < deliveries.length; offset += 10) {
    await Promise.all(deliveries.slice(offset, offset + 10).map(async delivery => {
      try {
        const hostname = new URL(delivery.endpoint).hostname
        if (!/^(?:(?:[a-z0-9-]+\.)?push\.apple\.com|fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|[a-z0-9-]+\.notify\.windows\.com)$/.test(hostname)) {
          await db.from('customer_push_subscriptions').delete().eq('id', delivery.subscription_id)
          return
        }
        const { title, body } = notificationCopy(delivery.kind, delivery.language)
        await webPush.sendNotification(
          { endpoint: delivery.endpoint, keys: { p256dh: delivery.p256dh, auth: delivery.auth_secret } },
          JSON.stringify({
            id: delivery.id, title, message: body, path: delivery.path,
            // Older workers only display the body, so keep the event in it.
            body: `${title}. ${body}`,
          }),
          { TTL: 3600, timeout: 7000, vapidDetails: { subject, publicKey, privateKey } },
        )
        sent++
        const result = await db.from('customer_push_deliveries').delete().eq('id', delivery.id)
        if (result.error) console.error('Could not acknowledge push delivery', result.error.code)
      } catch (cause) {
        const status = (cause as { statusCode?: number })?.statusCode
        if (status === 404 || status === 410) {
          await db.from('customer_push_subscriptions').delete().eq('id', delivery.subscription_id)
        } else {
          console.warn('Web Push delivery could not be sent', status ?? 'network error')
        }
      }
    }))
  }
  return Response.json({ claimed: deliveries.length, sent })
})
