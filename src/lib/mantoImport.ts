import { SupabaseError, supabaseBlob, supabaseRequest } from './supabase'
import type { CatalogExchangeRate } from './catalogCosts'
import type { CatalogImportSettings } from './catalogImportSettings'

export type MantoSnapshot = {
  url: string
  checkedAt: string
  category: string
  currency: 'EUR' | 'PLN' | null
  variants: {
    key: string
    name: string
    ean: string | null
    sku: string
    quantity: number | null
    priceMinor: number | null
    weightGrams: number | null
  }[]
}

export type MantoSource = { manto_product_id: string; snapshot: MantoSnapshot }

export async function saveMantoSnapshot(storeId: string, productId: string, source: MantoSource, token: string, signal: AbortSignal) {
  const [updated] = await supabaseRequest<{ product_id: string }[]>(
    `/rest/v1/manto_product_sources?store_id=eq.${storeId}&product_id=eq.${productId}&manto_product_id=eq.${source.manto_product_id}&select=product_id`,
    {
      method: 'PATCH', token, signal, headers: { Prefer: 'return=representation' },
      body: JSON.stringify({ snapshot: source.snapshot }),
    },
  )
  if (!updated) throw new Error('The Manto link is no longer attached to this product.')
}

type MantoProduct = {
  id: string
  name: string
  description: string
  composition: string
  imageUrls: string[]
  sizeGuide: string | null
  weightGrams: number | null
  snapshot: MantoSnapshot
}

const endpoint = '/functions/v1/crm-import-manto'

async function requestManto<T>(request: (path: string) => Promise<T>, signal: AbortSignal) {
  try {
    return await request(`${endpoint}?forceFunctionRegion=eu-west-1`)
  } catch (cause) {
    signal.throwIfAborted()
    if (cause instanceof SupabaseError && cause.status < 500) throw cause
    return request(`${endpoint}?forceFunctionRegion=eu-west-3`)
  }
}

async function fetchLocalManto(url: URL, signal: AbortSignal) {
  return fetch(`/__manto-source${url.pathname}`, {
    redirect: 'error', credentials: 'omit', referrerPolicy: 'no-referrer', signal,
  })
}

export function getMantoDraftPricing(
  { variants, currency }: MantoSnapshot, storeCurrency: string, rates: CatalogExchangeRate[], settings: CatalogImportSettings,
) {
  const firstPrice = variants[0]?.priceMinor
  const sharedPrice = firstPrice != null && variants.every(variant => variant.priceMinor === firstPrice) ? firstPrice : null
  const rateInUah = (code: string) => code === 'UAH' ? 1 : rates.find(rate => rate.currency === code)?.uah_rate
  const sourceRate = currency && rateInUah(currency)
  const storeRate = rateInUah(storeCurrency)
  const rate = currency && (currency === storeCurrency ? 1 : sourceRate && storeRate && sourceRate / storeRate)
  const price = sharedPrice != null && rate ? String(Math.round(sharedPrice * rate) / 100) : ''
  const costAmount = (amount: number) => String(Math.round(amount * (10000 - Math.round(settings.cost_discount_percent * 100)) / 10000) / 100)
  const costsEnabled = Boolean(settings.auto_fill_cost && currency)

  return {
    price,
    defaultCost: costsEnabled && sharedPrice != null ? costAmount(sharedPrice) : '',
    variantCosts: new Map(costsEnabled && sharedPrice == null
      ? variants.flatMap(({ key, priceMinor }) => priceMinor == null ? [] : [[key, costAmount(priceMinor)] as const])
      : []),
    priceMessage: sharedPrice == null ? 'Manto does not have a single price for all sizes. Enter the sale price.'
      : !rate ? 'Exchange rate is unavailable. Enter the sale price.' : null,
  }
}

export async function readMantoProduct(storeId: string, token: string, link: string, signal: AbortSignal): Promise<MantoProduct> {
  if (import.meta.env.DEV) {
    const [{ mantoProductLink, parseMantoProduct }, { parse }] = await Promise.all([
      import('../../supabase/functions/crm-import-manto/product'),
      import('node-html-parser'),
    ])
    const source = mantoProductLink(link)
    if (!source) throw new Error('Enter a link to a Manto product.')
    try {
      const response = await fetchLocalManto(source.url, signal)
      if (response.ok && /^text\/html\b/i.test(response.headers.get('content-type') ?? '')) {
        const product = parseMantoProduct(await response.text(), source.id, source.url.href, new Date().toISOString(), parse)
        if (product) return product
      }
    } catch {
      signal.throwIfAborted()
    }
  }
  return requestManto(path => supabaseRequest<MantoProduct>(path, {
    method: 'POST', token, signal, body: JSON.stringify({ storeId, link }),
  }), signal)
}

async function downloadMantoImage(storeId: string, token: string, imageUrl: string, signal: AbortSignal) {
  if (import.meta.env.DEV) {
    const { mantoImageLink } = await import('../../supabase/functions/crm-import-manto/product')
    const url = mantoImageLink(imageUrl)
    if (url) {
      try {
        const response = await fetchLocalManto(url, signal)
        if (response.ok && /^image\/(?:jpeg|png|webp)$/i.test(response.headers.get('content-type') ?? '')) {
          const image = await response.blob()
          if (image.size <= 5 * 1024 * 1024) return image
        }
      } catch {
        signal.throwIfAborted()
      }
    }
  }
  return requestManto(path => supabaseBlob(path, {
    method: 'POST', token, signal, body: JSON.stringify({ storeId, action: 'image', imageUrl }),
  }), signal)
}

export async function downloadMantoPhotos(storeId: string, token: string, urls: string[], signal: AbortSignal) {
  const files = new Map<string, File>()
  for (let start = 0; start < urls.length; start += 4) {
    signal.throwIfAborted()
    await Promise.allSettled(urls.slice(start, start + 4).map(async (imageUrl, index) => {
      const blob = await downloadMantoImage(storeId, token, imageUrl, signal)
      const extension = blob.type === 'image/jpeg' ? 'jpg' : blob.type.split('/')[1]
      files.set(imageUrl, new File([blob], `manto-${start + index + 1}.${extension}`, { type: blob.type }))
    }))
  }
  signal.throwIfAborted()
  return files
}
