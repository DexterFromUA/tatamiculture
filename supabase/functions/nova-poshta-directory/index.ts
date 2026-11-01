type DirectoryBody = { action: 'cities' | 'warehouses'; query?: string; cityRef?: string }

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), { status, headers: { 'Content-Type': 'application/json', 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type' } })

async function novaPost(payload: Record<string, unknown>, apiKey: string) {
  const response = await fetch('https://api.novaposhta.ua/v2.0/json/', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ apiKey, ...payload }) })
  const result = await response.json() as { success?: boolean; data?: unknown[]; errors?: string[] }
  if (!response.ok || !result.success) throw new Error(result.errors?.join(', ') || 'Nova Poshta directory is unavailable')
  return result.data ?? []
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
      const data = await novaPost({ modelName: 'Address', calledMethod: 'getCities', methodProperties: { FindByString: query, Limit: '20', Page: '1' } }, apiKey)
      return json(data.map((city) => ({ ref: String(city.Ref ?? ''), name: String(city.Description ?? ''), area: String(city.AreaDescription ?? '') })))
    }
    if (body.action === 'warehouses' && body.cityRef) {
      const data = await novaPost({ modelName: 'AddressGeneral', calledMethod: 'getWarehouses', methodProperties: { CityRef: body.cityRef, Limit: '100', Page: '1', Language: 'UA' } }, apiKey)
      return json(data.map((warehouse) => ({ ref: String(warehouse.Ref ?? ''), name: String(warehouse.Description ?? ''), type: String(warehouse.CategoryOfWarehouse ?? '') })))
    }
    return json({ error: 'Invalid directory request' }, 400)
  } catch (error) { return json({ error: error instanceof Error ? error.message : 'Nova Poshta directory failed' }, 400) }
})
