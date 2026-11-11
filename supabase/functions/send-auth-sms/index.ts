import { Webhook } from 'npm:standardwebhooks@1.0.0'
import { configuredSecret, kyivstarSignInCredentials, sendKyivstar } from '../_shared/sms-auth.ts'

Deno.serve(async request => {
  if (request.method !== 'POST') return new Response(null, { status: 405 })
  const secret = configuredSecret('SMS_AUTH_HOOK_SECRET')
  if (!secret) return new Response(null, { status: 503 })

  let event: { user?: { phone?: string; new_phone?: string }; sms?: { phone?: string; otp?: string } }
  try {
    const webhook = new Webhook(secret.replace(/^v1,whsec_/, ''))
    event = webhook.verify(await request.text(), Object.fromEntries(request.headers)) as typeof event
  } catch {
    return new Response(null, { status: 401 })
  }

  // Newer Auth versions include the destination explicitly, including when changing a phone number.
  const digits = (event?.sms?.phone ?? (!event?.user?.new_phone ? event?.user?.phone : undefined))?.replace(/^\+/, '')
  const otp = event?.sms?.otp
  if (!digits || !/^[1-9]\d{1,14}$/.test(digits) || !otp || !/^\d{6,10}$/.test(otp)) {
    return new Response(null, { status: 400 })
  }

  const credentials = kyivstarSignInCredentials()
  if (!credentials) return new Response(null, { status: 503 })

  try {
    await sendKyivstar(credentials, digits, `Код tatami.culture: ${otp}`)
    return Response.json({})
  } catch (error) {
    console.error('Auth SMS could not be sent', error instanceof Error ? error.message : 'Unknown provider error')
    return Response.json({ error: { http_code: 502, message: 'Could not send an SMS code.' } }, { status: 502 })
  }
})
