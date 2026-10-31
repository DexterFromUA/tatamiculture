const url = import.meta.env.VITE_SUPABASE_URL?.replace(/\/$/, '')
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

export const supabaseConfigured = Boolean(url && anonKey)

type RequestOptions = RequestInit & { token?: string | null }

export class SupabaseError extends Error {
  public readonly status: number

  constructor(message: string, status: number) {
    super(message)
    this.status = status
  }
}

export async function supabaseRequest<T>(path: string, options: RequestOptions = {}): Promise<T> {
  if (!url || !anonKey) throw new Error('Supabase is not configured')
  const { token, headers, ...request } = options
  const response = await fetch(`${url}${path}`, {
    ...request,
    headers: {
      apikey: anonKey,
      Authorization: `Bearer ${token ?? anonKey}`,
      ...(request.body ? { 'Content-Type': 'application/json' } : {}),
      ...headers,
    },
  })

  if (!response.ok) {
    const body = await response.json().catch(() => null) as { message?: string } | null
    throw new SupabaseError(body?.message ?? 'Supabase request failed', response.status)
  }
  if (response.status === 204) return undefined as T
  return response.json() as Promise<T>
}

function encodedStoragePath(path: string) {
  return path.split('/').map(encodeURIComponent).join('/')
}

function safeFilename(name: string) {
  const extension = name.split('.').pop()?.toLowerCase()
  const permittedExtension = extension && ['jpg', 'jpeg', 'png', 'webp'].includes(extension) ? extension : 'jpg'
  return `${crypto.randomUUID()}.${permittedExtension}`
}

export async function uploadProductImage(productId: string, file: File, token: string) {
  if (!url || !anonKey) throw new Error('Supabase is not configured')
  const allowedTypes = ['image/jpeg', 'image/png', 'image/webp']
  if (!allowedTypes.includes(file.type)) throw new Error('Use a JPG, PNG, or WebP image')
  if (file.size > 5 * 1024 * 1024) throw new Error('Image must be 5 MB or smaller')

  const storagePath = `products/${productId}/${safeFilename(file.name)}`
  const response = await fetch(`${url}/storage/v1/object/product-images/${encodedStoragePath(storagePath)}`, {
    method: 'POST',
    headers: {
      apikey: anonKey,
      Authorization: `Bearer ${token}`,
      'Content-Type': file.type,
      'x-upsert': 'false',
    },
    body: file,
  })
  if (!response.ok) {
    const body = await response.json().catch(() => null) as { message?: string } | null
    throw new SupabaseError(body?.message ?? 'Image upload failed', response.status)
  }
  return {
    storagePath,
    publicUrl: `${url}/storage/v1/object/public/product-images/${encodedStoragePath(storagePath)}`,
  }
}

export async function removeProductImage(storagePath: string, token: string) {
  if (!url || !anonKey || !storagePath.startsWith('products/')) return
  const response = await fetch(`${url}/storage/v1/object/product-images/${encodedStoragePath(storagePath)}`, {
    method: 'DELETE',
    headers: { apikey: anonKey, Authorization: `Bearer ${token}` },
  })
  if (!response.ok && response.status !== 404) {
    const body = await response.json().catch(() => null) as { message?: string } | null
    throw new SupabaseError(body?.message ?? 'Image removal failed', response.status)
  }
}
