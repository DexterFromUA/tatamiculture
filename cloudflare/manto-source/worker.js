import { mantoImageLink, mantoProductLink } from '../../supabase/functions/crm-import-manto/product.ts'

const encoder = new TextEncoder()
const redirects = new Set([301, 302, 303, 307, 308])
const imageTypes = new Set(['image/jpeg', 'image/png', 'image/webp'])

function result(status, body = null, headers = {}) {
  return new Response(body, { status, headers: { 'Cache-Control': 'no-store', ...headers } })
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url)
    if (url.pathname !== '/') return result(404)
    if (request.method !== 'GET') return result(405)
    if (!env.MANTO_SOURCE_TOKEN) return result(503)

    const supplied = encoder.encode(request.headers.get('Authorization') ?? '')
    const expected = encoder.encode(`Bearer ${env.MANTO_SOURCE_TOKEN}`)
    if (supplied.length !== expected.length || !crypto.subtle.timingSafeEqual(supplied, expected)) return result(401)

    const link = url.searchParams.get('url')
    const product = mantoProductLink(link)
    const target = product?.url ?? mantoImageLink(link)
    if (!target) return result(400)

    try {
      const response = await fetch(target, {
        redirect: 'manual',
        cache: 'no-store',
        signal: AbortSignal.timeout(product ? 18000 : 10000),
        headers: product
          ? { Accept: 'text/html', 'Accept-Language': target.hostname === 'www.mantoshop.pl' ? 'pl' : 'en' }
          : { Accept: 'image/webp,image/jpeg,image/png' },
      })
      const type = response.headers.get('Content-Type')?.split(';', 1)[0].trim().toLowerCase() ?? ''
      const validType = product ? type === 'text/html' : imageTypes.has(type)
      if (response.ok && response.body && validType) {
        return result(200, response.body, { 'Content-Type': product ? 'text/html; charset=utf-8' : type })
      }

      await response.body?.cancel()
      if (product && redirects.has(response.status)) {
        const next = mantoProductLink(response.headers.get('Location'), target.href)
        if (next?.id === product.id && next.url.href !== target.href) {
          return result(response.status, null, { Location: next.url.href })
        }
      }
      if (response.status === 429 || response.status >= 500 || !product) return result(502)
      return result(422)
    } catch (cause) {
      const timeout = cause instanceof Error && cause.name === 'TimeoutError'
      console.warn('Manto source request failed', { host: target.hostname, name: cause instanceof Error ? cause.name : 'unknown' })
      return result(timeout ? 504 : 502)
    }
  },
}
