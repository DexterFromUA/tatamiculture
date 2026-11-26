const origin = 'https://www.mantoshop.eu'
const productPath = /^\/product-(?:eng|ger|pol)-([1-9]\d{0,11})(?:-[^\/]+)?\.html$/i

function mantoUrl(value: unknown, base?: string) {
  if (typeof value !== 'string' || value.length > 2048) return null
  let url: URL
  try {
    url = new URL(value.trim(), base)
  } catch {
    return null
  }
  const market = url.host.match(/^(?:www\.)?mantoshop\.(eu|pl)$/)?.[1]
  if (url.protocol !== 'https:' || !market
    || url.username || url.password) return null
  url.hostname = `www.mantoshop.${market}`
  url.search = ''
  url.hash = ''
  return url
}

export function mantoProductLink(value: unknown, base?: string) {
  const url = mantoUrl(value, base)
  const id = url?.pathname.match(productPath)?.[1]
  if (!url || !id) return null
  const locale = url.hostname === 'www.mantoshop.pl' ? 'pol' : 'eng'
  url.pathname = url.pathname.replace(/^\/product-(?:eng|ger|pol)-/i, `/product-${locale}-`)
  return { url, id }
}

export function mantoImageLink(value: unknown, base = origin) {
  const url = mantoUrl(value, base)
  if (!url || !/^\/(?:hpeciai\/|data\/include\/cms\/|data\/gfx\/pictures\/)[^?#]+\.(?:webp|jpe?g|png)$/i.test(url.pathname)) return null
  return url
}

type SupplierSize = {
  description?: unknown
  name?: unknown
  code_extern?: unknown
  code_producer?: unknown
  amount?: unknown
  price?: { value?: unknown }
  weight?: { g?: unknown }
}

const cleanText = (value: unknown, limit: number) => typeof value === 'string' ? value.trim().slice(0, limit) : ''

function nonnegativeInteger(value: unknown) {
  if (!(typeof value === 'number' || (typeof value === 'string' && /^\d+$/.test(value)))) return null
  const number = Number(value)
  return Number.isSafeInteger(number) && number >= 0 && number <= 2147483647 ? number : null
}

function priceInMinorUnits(value: unknown) {
  if (typeof value !== 'string' || !/^\d+(?:\.\d{1,2})?$/.test(value)) return null
  return nonnegativeInteger(Math.round(Number(value) * 100))
}

type HtmlNode = {
  text: string
  getAttribute(name: string): string | undefined
  querySelector(selector: string): HtmlNode | null
  querySelectorAll(selector: string): HtmlNode[]
}

export function parseMantoProduct(html: string, id: string, url: string, checkedAt: string, parse: (html: string) => HtmlNode) {
  const source = html.match(/\bvar\s+product_data\s*=\s*(\{[\s\S]*?\})\s*;?\s*var\s+trust_level\b/)?.[1]
  if (!source) return null
  const data = JSON.parse(source.replace(/^(\{\s*"product_id"\s*:\s*)'(\d+)'/, '$1"$2"')) as {
    product_id?: unknown; currency?: unknown; sizes?: Record<string, SupplierSize>
  }
  if (String(data.product_id) !== id || !data.sizes || typeof data.sizes !== 'object') return null
  const doc = parse(html)
  const meta = (property: string) => doc.querySelector(`meta[property="${property}"]`)?.getAttribute('content')
  const name = cleanText(meta('og:title') || doc.querySelector('h1')?.text, 200)
  if (!name) return null
  const descriptionLines = cleanText(meta('og:description'), 12000).split(/\r?\n/).map(line => line.trim()).filter(Boolean)
  const isComposition = (line: string) => /^\d+(?:[.,]\d+)?\s*%\s*\p{L}/u.test(line)
  const composition = descriptionLines.filter(isComposition).join('\n')
  const description = descriptionLines.filter(line => !isComposition(line)).join('\n')
  const photos = doc.querySelectorAll('#projector_photos a.photos__link').map(link => link.getAttribute('href'))
  const imageUrls = [...new Set([...photos, meta('og:image')].flatMap(image => mantoImageLink(image, url)?.href ?? []))].slice(0, 16)
  const sizeGuide = mantoImageLink(doc.querySelector('.sizes_chart_cms img')?.getAttribute('src'), url)?.href ?? null
  const breadcrumb = doc.querySelector('#breadcrumbs ol')
  const category = cleanText(breadcrumb?.querySelectorAll('li > a.category').at(-1)?.text, 120)
  const currency: 'EUR' | 'PLN' | null = data.currency === '€' || data.currency === 'EUR' ? 'EUR'
    : data.currency === 'zł' || data.currency === 'PLN' ? 'PLN' : null
  const mapped = Object.entries(data.sizes).flatMap(([remoteId, size]) => {
    if (!size || !/^[a-z\d_.-]{1,40}$/i.test(remoteId)) return []
    const sizeName = cleanText(size.description || size.name, 80) || 'One size'
    const barcode = cleanText(size.code_producer, 24)
    const ean = /^\d{8,14}$/.test(barcode) && /[1-9]/.test(barcode) ? barcode : null
    return [{
      remoteId, name: sizeName, ean, sku: cleanText(size.code_extern, 120) || ean || '',
      quantity: nonnegativeInteger(size.amount),
      priceMinor: priceInMinorUnits(size.price?.value),
      weightGrams: nonnegativeInteger(size.weight?.g),
    }]
  })
  if (!mapped.length || mapped.length > 100) return null
  const variants = mapped.map(({ remoteId, ...size }) => ({
    ...size,
    key: size.ean && mapped.filter(item => item.ean === size.ean).length === 1 ? `ean:${size.ean}` : `id:${remoteId}`,
  }))
  const weight = variants[0].weightGrams
  return {
    id, name, description, composition, imageUrls, sizeGuide,
    weightGrams: weight && variants.every(size => size.weightGrams === weight) ? weight : null,
    snapshot: { url, checkedAt, category, currency, variants },
  }
}
