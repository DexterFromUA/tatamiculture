import { createClient } from 'npm:@supabase/supabase-js@2'
import { parse } from 'npm:node-html-parser@9.0.7'
import { mantoImageLink, mantoProductLink, parseMantoProduct } from './product.ts'

const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Cache-Control': 'no-store',
}
const json = (body: unknown, status = 200) => Response.json(body, { status, headers: cors })
const imageTypes = new Set(['image/jpeg', 'image/png', 'image/webp'])
const redirects = new Set([301, 302, 303, 307, 308])

type MantoSource = { endpoint: URL; token: string }

async function fetchManto(source: MantoSource, target: URL, signal: AbortSignal) {
  const endpoint = new URL(source.endpoint)
  endpoint.searchParams.set('url', target.href)
  const response = await fetch(endpoint, {
    signal, redirect: 'manual',
    headers: { Authorization: `Bearer ${source.token}`, 'User-Agent': 'Tatami CRM Manto import/1.0' },
  })
  if (response.status === 504 || !(response.ok || response.status === 422 || redirects.has(response.status))) {
    await response.body?.cancel()
    if (response.status === 504) throw new DOMException('Manto source request timed out', 'TimeoutError')
    throw new Error(`Manto source returned HTTP ${response.status}`)
  }
  return response
}

async function boundedBody(response: Response, limit: number) {
  const reader = response.body?.getReader()
  if (!reader) throw new Error('Empty Manto response')
  const chunks: Uint8Array<ArrayBuffer>[] = []
  let length = 0
  try {
    for (;;) {
      const { done, value } = await reader.read()
      if (done) break
      length += value.length
      if (length > limit) throw new Error('Manto response is too large')
      chunks.push(new Uint8Array(value))
    }
    return new Blob(chunks)
  } finally {
    await reader.cancel().catch(() => {})
  }
}

async function fetchProduct(source: NonNullable<ReturnType<typeof mantoProductLink>>, relay: MantoSource) {
  let url = source.url
  const signal = AbortSignal.timeout(20000)
  for (let redirect = 0; redirect < 4; redirect++) {
    const response = await fetchManto(relay, url, signal)
    if (response.ok && response.body && /^text\/html\b/i.test(response.headers.get('content-type') ?? '')) {
      const html = await boundedBody(response, 2 * 1024 * 1024).then(body => body.text())
      try {
        return parseMantoProduct(html, source.id, url.href, new Date().toISOString(), parse)
      } catch (cause) {
        console.warn('Manto product data could not be parsed', { productId: source.id, cause: cause instanceof Error ? cause.name : 'unknown' })
        return null
      }
    }
    await response.body?.cancel()
    if (!redirects.has(response.status)) break
    const next = mantoProductLink(response.headers.get('location'), url.href)
    if (!next || next.id !== source.id || next.url.href === url.href) break
    url = next.url
  }
  return null
}

Deno.serve(async request => {
  if (request.method === 'OPTIONS') return new Response(null, { status: 204, headers: cors })
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const url = Deno.env.get('SUPABASE_URL')
  const key = Deno.env.get('SUPABASE_ANON_KEY') ?? Deno.env.get('SUPABASE_PUBLISHABLE_KEY')
  if (!url || !key) return json({ error: 'Supabase is not configured' }, 503)
  const authorization = request.headers.get('Authorization')
  if (!authorization?.startsWith('Bearer ')) return json({ error: 'Sign in required' }, 401)

  try {
    const client = createClient(url, key, {
      global: { headers: { Authorization: authorization } },
      auth: { persistSession: false, autoRefreshToken: false },
    })
    const { data: auth, error: authError } = await client.auth.getUser()
    if (authError || !auth.user) return json({ error: 'Sign in required' }, 401)
    const body = await request.json().catch(() => null)
    if (typeof body?.storeId !== 'string' || !/^[a-f\d-]{36}$/i.test(body.storeId)) return json({ error: 'Store is required' }, 400)
    const { data: allowed, error } = await client.rpc('is_store_member', { target_store_id: body.storeId })
    if (error || allowed !== true) return json({ error: 'Manager access required' }, 403)

    const relayUrl = Deno.env.get('MANTO_SOURCE_URL')
    const relayToken = Deno.env.get('MANTO_SOURCE_TOKEN')
    const endpoint = relayUrl ? URL.parse(relayUrl) : null
    if (!endpoint || endpoint.protocol !== 'https:' || endpoint.username || endpoint.password || !relayToken) {
      console.error('Manto source is not configured')
      return json({ error: 'Manto source is not configured.' }, 503)
    }
    const relay = { endpoint, token: relayToken }

    if (body.action === 'image') {
      const image = mantoImageLink(body.imageUrl)
      if (!image) return json({ error: 'Invalid Manto image.' }, 400)
      const response = await fetchManto(relay, image, AbortSignal.timeout(12000))
      const type = response.headers.get('content-type')?.split(';', 1)[0] ?? ''
      if (!response.ok || !response.body || !imageTypes.has(type)) {
        await response.body?.cancel()
        return json({ error: 'Could not download a Manto image.' }, 502)
      }
      return new Response(await boundedBody(response, 5 * 1024 * 1024), {
        headers: { ...cors, 'Content-Type': type },
      })
    }

    const source = mantoProductLink(body.link)
    if (!source) return json({ error: 'Enter a link to a Manto product.' }, 400)
    const product = await fetchProduct(source, relay)
    return product ? json(product) : json({ error: 'Could not find product data on the Manto page.', code: 'MANTO_PRODUCT_UNAVAILABLE' }, 422)
  } catch (cause) {
    const name = cause instanceof Error ? cause.name : 'UnknownError'
    console.error('Manto import failed', { name, message: cause instanceof Error ? cause.message : undefined })
    return json({
      error: name === 'TimeoutError' ? 'Manto took too long to respond. Try again.' : 'Could not connect to Manto. Try again.',
      code: name === 'TimeoutError' ? 'MANTO_TIMEOUT' : 'MANTO_REQUEST_FAILED',
    }, 502)
  }
})
