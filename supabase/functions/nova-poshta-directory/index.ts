import { NovaPoshtaRateLimit, novaPoshtaRateLimit } from '../_shared/nova-poshta-rate-limit.ts'

type DirectoryBody = { action: 'cities' | 'warehouses'; query?: string; cityRef?: string; page?: number }
type Entry = { ref: string; name: string; area?: string; type?: string }

const cache = new Map<string, { rows: Entry[]; expiresAt: number }>()
const pending = new Map<string, Promise<Entry[]>>()
let retryAt = 0

const json = (body: unknown, status = 200, retryAfter?: number) => new Response(JSON.stringify(body), { status, headers: {
  'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  'Access-Control-Expose-Headers': 'Retry-After', ...(retryAfter === undefined ? {} : { 'Retry-After': String(retryAfter) }),
} })

async function novaPost(payload: Record<string, unknown>, apiKey: string) {
  const response = await fetch('https://api.novaposhta.ua/v2.0/json/', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ apiKey, ...payload }), signal: AbortSignal.timeout(8000) })
  const rejectedByGateway = novaPoshtaRateLimit(response)
  if (rejectedByGateway) throw rejectedByGateway
  const result = await response.json().catch(() => null) as { success?: boolean; data?: Array<Record<string, unknown>>; errors?: string[]; message?: string } | null
  const message = (Array.isArray(result?.errors) && result.errors.join(', ')) || result?.message || ''
  const limit = novaPoshtaRateLimit(response, message)
  if (limit) throw limit
  if (!response.ok || !result?.success) throw new Error(message || 'Nova Poshta directory is unavailable')
  return result.data ?? []
}

async function directoryEntries(key: string, load: () => Promise<Entry[]>) {
  const cached = cache.get(key)
  if (cached && cached.expiresAt > Date.now()) return cached.rows
  const current = pending.get(key)
  if (current) return current
  if (retryAt > Date.now()) throw new NovaPoshtaRateLimit(Math.ceil((retryAt - Date.now()) / 1000))
  const request = load().then(rows => {
    cache.delete(key)
    cache.set(key, { rows, expiresAt: Date.now() + 5 * 60_000 })
    const oldestKey = cache.keys().next().value
    if (cache.size > 256 && oldestKey !== undefined) cache.delete(oldestKey)
    return rows
  }).catch(error => {
    if (error instanceof NovaPoshtaRateLimit) retryAt = Math.max(retryAt, Date.now() + error.retryAfter * 1000)
    throw error
  }).finally(() => pending.delete(key))
  pending.set(key, request)
  return request
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type' } })
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  const apiKey = Deno.env.get('NOVA_POSHTA_API_KEY')?.trim()
  if (!apiKey) return json({ error: 'Nova Poshta is not configured' }, 503)
  try {
    const body = await request.json() as DirectoryBody
    if (body.action === 'cities') {
      const query = body.query?.trim() ?? ''
      if (query.length < 2) return json([])
      return json(await directoryEntries(`cities:${query.toLocaleLowerCase('uk-UA')}`, async () => {
        const data = await novaPost({ modelName: 'Address', calledMethod: 'getCities', methodProperties: { FindByString: query, Limit: '20', Page: '1' } }, apiKey)
        return data.map(city => ({ ref: String(city.Ref ?? ''), name: String(city.Description ?? ''), area: String(city.AreaDescription ?? '') }))
      }))
    }
    if (body.action === 'warehouses' && body.cityRef) {
      const page = body.page ?? 1
      if (!Number.isSafeInteger(page) || page < 1) return json({ error: 'Invalid directory page' }, 400)
      return json(await directoryEntries(`warehouses:${body.cityRef}:${page}`, async () => {
        const data = await novaPost({ modelName: 'AddressGeneral', calledMethod: 'getWarehouses', methodProperties: { CityRef: body.cityRef, Limit: '100', Page: String(page), Language: 'UA' } }, apiKey)
        return data.map(warehouse => ({ ref: String(warehouse.Ref ?? ''), name: String(warehouse.Description ?? ''), type: String(warehouse.CategoryOfWarehouse ?? '') }))
      }))
    }
    return json({ error: 'Invalid directory request' }, 400)
  } catch (error) {
    if (error instanceof NovaPoshtaRateLimit) return json({ error: error.message }, 429, error.retryAfter)
    return json({ error: error instanceof Error ? error.message : 'Nova Poshta directory failed' }, 400)
  }
})
