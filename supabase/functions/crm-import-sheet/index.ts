import { createClient } from 'npm:@supabase/supabase-js@2'

const headers = {
  'Content-Type': 'application/json',
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Cache-Control': 'no-store',
}
const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers })
const maxBytes = 5 * 1024 * 1024
const accessError = 'Could not open this sheet. Check link access or upload a file.'

function exportUrl(link: unknown) {
  if (typeof link !== 'string' || link.length > 2048) return null
  const url = URL.parse(link.trim())
  if (!url || url.origin !== 'https://docs.google.com' || url.username || url.password) return null
  const match = url.pathname.match(/^\/spreadsheets(?:\/u\/\d+)?\/d\/(e\/)?([\w-]+)(?:\/(?:edit|view|export|pubhtml|pub))?\/?$/)
  if (!match) return null
  const [, published, id] = match
  const gid = url.searchParams.get('gid') ?? new URLSearchParams(url.hash.slice(1)).get('gid')
  if (gid !== null && !/^\d+$/.test(gid)) return null
  const download = new URL(published ? `/spreadsheets/d/e/${id}/pub?output=csv` : `/spreadsheets/d/${id}/export?format=csv`, url.origin)
  if (gid !== null) {
    download.searchParams.set('gid', gid)
    if (published) download.searchParams.set('single', 'true')
  }
  return download
}

async function fetchSheet(url: URL) {
  const signal = AbortSignal.timeout(12000)
  for (let redirects = 0; redirects < 4; redirects++) {
    const response = await fetch(url, { signal, redirect: 'manual' })
    if (![301, 302, 303, 307, 308].includes(response.status)) return response
    await response.body?.cancel()
    const location = response.headers.get('location')
    const next = location && URL.parse(location, url)
    if (!next || next.protocol !== 'https:' || next.port || next.username || next.password
      || !(next.hostname === 'docs.google.com' || next.hostname.endsWith('.googleusercontent.com'))) break
    url = next
  }
  return null
}

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
    const download = exportUrl(body?.link)
    if (!download) return json({ error: 'Enter a valid Google Sheets link.' }, 400)
    const { data: allowed, error } = await client.rpc('is_store_member', { target_store_id: body?.storeId })
    if (error || allowed !== true) return json({ error: 'Manager access required' }, 403)

    const response = await fetchSheet(download)
    if (!response?.ok || !response.body || !/^text\/csv\b/i.test(response.headers.get('content-type') ?? '')) {
      await response?.body?.cancel()
      return json({ error: accessError }, 422)
    }
    const reader = response.body.getReader()
    const decoder = new TextDecoder()
    let bytes = 0
    let csv = ''
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      bytes += value.byteLength
      if (bytes > maxBytes) {
        await reader.cancel()
        return json({ error: 'Use a spreadsheet up to 5 MB.' }, 413)
      }
      csv += decoder.decode(value, { stream: true })
    }
    return json({ csv: csv + decoder.decode() })
  } catch {
    return json({ error: 'Could not load the Google spreadsheet. Try again.' }, 502)
  }
})
