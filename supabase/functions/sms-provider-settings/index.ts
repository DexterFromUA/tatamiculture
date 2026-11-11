import { createClient } from 'npm:@supabase/supabase-js@2'
import { configuredSecret, kyivstarSignInCredentials } from '../_shared/sms-auth.ts'

type AuthConfig = {
  hook_send_sms_enabled: boolean
  hook_send_sms_uri?: string
  sms_provider?: string
}

const headers = {
  'Content-Type': 'application/json',
  'Cache-Control': 'no-store',
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, PUT, OPTIONS',
}
const json = (body: unknown, status = 200) => Response.json(body, { status, headers })

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers })
  if (request.method !== 'GET' && request.method !== 'PUT') return json({ error: 'Method not allowed' }, 405)
  const authorization = request.headers.get('Authorization')
  if (!authorization?.startsWith('Bearer ')) return json({ error: 'Sign in required' }, 401)

  try {
    const url = Deno.env.get('SUPABASE_URL')!
    const key = (Deno.env.get('SUPABASE_ANON_KEY') ?? Deno.env.get('SUPABASE_PUBLISHABLE_KEY'))!
    const client = createClient(url, key, { global: { headers: { Authorization: authorization } } })
    const { data: auth, error: authError } = await client.auth.getUser()
    if (authError || !auth.user) return json({ error: 'Sign in required' }, 401)

    const { data: memberships, error: memberError } = await client.from('store_members')
      .select('role, stores!inner(slug)').eq('user_id', auth.user.id).eq('stores.slug', 'tatami')
    if (memberError) throw memberError
    if (!memberships.some(member => member.role === 'OWNER' || member.role === 'MANAGER')) {
      return json({ error: 'Manager access required' }, 403)
    }

    const token = configuredSecret('SMS_AUTH_MANAGEMENT_TOKEN')
    const secret = configuredSecret('SMS_AUTH_HOOK_SECRET')
    const kyivstarMode = secret ? kyivstarSignInCredentials()?.mode ?? null : null
    const kyivstarConfigured = kyivstarMode !== null
    if (!token) {
      if (request.method === 'PUT') return json({ error: 'The Supabase Management API token is missing.' }, 409)
      return json({ provider: null, kyivstarConfigured, kyivstarMode, managementConfigured: false })
    }

    const project = new URL(url).hostname.match(/^([a-z0-9]+)\.supabase\.co$/)?.[1]
    if (!project) throw new Error('Supabase project reference could not be determined')
    const authConfigUrl = `https://api.supabase.com/v1/projects/${project}/config/auth`
    const hookUrl = new URL('/functions/v1/send-auth-sms', url).href
    const managementHeaders = { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' }
    const readConfig = async (): Promise<AuthConfig> => {
      const response = await fetch(authConfigUrl, { headers: managementHeaders, signal: AbortSignal.timeout(5000) })
      if (!response.ok) throw new Error(`Supabase Management API HTTP ${response.status}`)
      return response.json()
    }

    let config = await readConfig()
    if (config.hook_send_sms_enabled && config.hook_send_sms_uri !== hookUrl) {
      return json({ error: 'Another Send SMS hook is active in Supabase.' }, 409)
    }
    if (config.sms_provider !== 'twilio' && config.sms_provider !== 'twilio_verify') {
      return json({ error: 'Twilio is not the built-in SMS provider in Supabase.' }, 409)
    }

    if (request.method === 'PUT') {
      const payload = await request.json().catch(() => null)
      const provider = payload?.provider
      if (provider !== 'kyivstar' && provider !== 'twilio') return json({ error: 'Invalid SMS provider' }, 400)
      if (provider === 'kyivstar' && !kyivstarConfigured) {
        return json({ error: 'Kyivstar credentials are missing.' }, 409)
      }

      const enableHook = provider === 'kyivstar'
      if (Boolean(config.hook_send_sms_enabled) !== enableHook) {
        const response = await fetch(authConfigUrl, {
          method: 'PATCH',
          headers: managementHeaders,
          body: JSON.stringify(enableHook
            ? { hook_send_sms_enabled: true, hook_send_sms_uri: hookUrl, hook_send_sms_secrets: secret }
            : { hook_send_sms_enabled: false }),
          signal: AbortSignal.timeout(5000),
        })
        if (!response.ok) throw new Error(`Supabase Management API HTTP ${response.status}`)
        await response.body?.cancel()
        config = await readConfig()
      }
      if (Boolean(config.hook_send_sms_enabled) !== enableHook) {
        return json({ error: 'Could not verify the SMS provider change.' }, 502)
      }
    }

    return json({ provider: config.hook_send_sms_enabled ? 'kyivstar' : 'twilio', kyivstarConfigured, kyivstarMode, managementConfigured: true })
  } catch {
    return json({ error: 'Could not load or save the SMS provider.' }, 502)
  }
})
