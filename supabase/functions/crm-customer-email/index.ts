import { createClient } from 'npm:@supabase/supabase-js@2'

const headers = {
  'Content-Type': 'application/json',
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers })
const uuid = (value: unknown): value is string =>
  typeof value === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(value)

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers })
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const url = Deno.env.get('SUPABASE_URL')
  const key = Deno.env.get('SUPABASE_ANON_KEY') ?? Deno.env.get('SUPABASE_PUBLISHABLE_KEY')
  const authorization = request.headers.get('Authorization')
  if (!url || !key) return json({ error: 'Supabase is not configured' }, 503)
  if (!authorization?.startsWith('Bearer ')) return json({ error: 'Sign in required' }, 401)

  try {
    const client = createClient(url, key, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    })
    const { data: auth, error: authError } = await client.auth.getUser()
    if (authError || !auth.user) return json({ error: 'Sign in required' }, 401)

    const body = await request.json().catch(() => null)
    const subject = typeof body?.subject === 'string' ? body.subject.trim() : ''
    const message = typeof body?.message === 'string' ? body.message.trim() : ''
    if (!uuid(body?.storeId) || !uuid(body?.customerId) || !uuid(body?.userId) || !uuid(body?.requestId)
        || !subject || subject.length > 160 || /[\r\n]/.test(subject) || !message || message.length > 5000) {
      return json({ error: 'Enter a valid subject and message' }, 400)
    }

    const { data: accounts, error } = await client.rpc('crm_customer_accounts', {
      p_store_id: body.storeId,
      p_customer_id: body.customerId,
    })
    if (error) return json({ error: 'Manager access required' }, error.code === '42501' ? 403 : 502)
    const account = (accounts as { user_id: string; email: string | null; email_confirmed: boolean }[] | null)
      ?.find(item => item.user_id === body.userId)
    if (!account) return json({ error: 'Customer account not found' }, 404)
    if (!account.email || !account.email_confirmed) return json({ error: 'A confirmed email is required' }, 400)

    const apiKey = Deno.env.get('RESEND_API_KEY')?.trim()
    const from = Deno.env.get('CRM_EMAIL_FROM')?.trim()
    if (!apiKey || !from) return json({ error: 'Email sending is not configured' }, 503)

    const response = await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${apiKey}`,
        'Idempotency-Key': `crm/${auth.user.id}/${body.userId}/${body.requestId}`,
      },
      body: JSON.stringify({ from, to: [account.email], subject, text: message }),
      signal: AbortSignal.timeout(10000),
    })
    if (!response.ok) return json({ error: 'Email provider did not accept the message' }, 502)
    return json({ sent: true })
  } catch {
    return json({ error: 'Could not send email' }, 502)
  }
})
