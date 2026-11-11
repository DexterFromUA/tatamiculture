export function configuredSecret(name: string) {
  const value = Deno.env.get(name)?.trim()
  return value && value !== 'REPLACE_ME' ? value : undefined
}

export function kyivstarCredentials(mode: 'live' | 'sandbox' = 'live') {
  const clientId = configuredSecret('KYIVSTAR_CLIENT_ID')
  const clientSecret = configuredSecret('KYIVSTAR_CLIENT_SECRET')
  const from = mode === 'sandbox' ? 'messagedesk' : configuredSecret('KYIVSTAR_SMS_FROM')
  return clientId && clientSecret && from && (mode === 'sandbox' || from.toLowerCase() !== 'messagedesk')
    ? { clientId, clientSecret, from, mode } : null
}

export function kyivstarSignInCredentials() {
  return kyivstarCredentials() ?? kyivstarCredentials('sandbox')
}

export class KyivstarSmsError extends Error {
  constructor(readonly status: number) {
    super(`Kyivstar SMS HTTP ${status}`)
  }
}

const kyivstarUrl = 'https://api-gateway.kyivstar.ua'
let kyivstarToken: { value: string; expiresAt: number } | undefined

export async function sendKyivstar(credentials: NonNullable<ReturnType<typeof kyivstarCredentials>>, phone: string, body: string) {
  if (!kyivstarToken || Date.now() >= kyivstarToken.expiresAt) {
    const response = await fetch(`${kyivstarUrl}/idp/oauth2/token`, {
      method: 'POST',
      headers: { Authorization: `Basic ${btoa(`${credentials.clientId}:${credentials.clientSecret}`)}` },
      body: new URLSearchParams({ grant_type: 'client_credentials' }),
      signal: AbortSignal.timeout(2000),
    })
    if (!response.ok) throw new Error(`Kyivstar OAuth HTTP ${response.status}`)
    const { access_token, expires_in = 0 } = await response.json().catch(() => ({}))
    if (typeof access_token !== 'string' || !access_token) throw new Error('Missing Kyivstar access token')
    kyivstarToken = { value: access_token, expiresAt: Date.now() + Math.max(0, (Number(expires_in) || 0) - 60) * 1000 }
  }
  const prefix = credentials.mode === 'sandbox' ? '/sandbox' : ''
  const response = await fetch(`${kyivstarUrl}${prefix}/rest/v1/sms`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${kyivstarToken.value}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ from: credentials.from, to: phone, text: body, maxSegments: 1 }),
    signal: AbortSignal.timeout(2000),
  })
  if (response.status === 401) kyivstarToken = undefined
  if (!response.ok) throw new KyivstarSmsError(response.status)
  const { msgId } = await response.json().catch(() => ({}))
  if (typeof msgId !== 'string' || !msgId) throw new Error('Kyivstar did not accept the SMS')
}
