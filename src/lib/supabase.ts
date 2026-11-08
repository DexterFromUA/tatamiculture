import { authSessionExpiredEvent, authSessionKey, clearAuthSession, expiresWithin, readAuthSession, sameAuthSession, saveAuthSession } from './authSession'

const url = import.meta.env.VITE_SUPABASE_URL?.replace(/\/$/, '')
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY

export const supabaseConfigured = Boolean(url && anonKey)

type RequestOptions = RequestInit & { token?: string | null }

export class SupabaseError extends Error {
  public readonly status: number
  public readonly code?: string

  constructor(message: string, status: number, code?: string) {
    super(message)
    this.status = status
    this.code = code
  }
}

async function responseError(response: Response) {
  const body = await response.json().catch(() => null) as {
    message?: string; msg?: string; error?: string; code?: unknown; error_code?: string
  } | null
  const code = body?.error_code ?? (typeof body?.code === 'string' ? body.code : undefined)
  return new SupabaseError(body?.message ?? body?.msg ?? body?.error ?? 'Supabase request failed', response.status, code)
}

function send(path: string, token: string | null | undefined, request: RequestInit) {
  if (!url || !anonKey) throw new Error('Supabase is not configured')
  const headers = new Headers(request.headers)
  headers.set('apikey', anonKey)
  headers.set('Authorization', `Bearer ${token ?? anonKey}`)
  if (request.body && !headers.has('Content-Type')) headers.set('Content-Type', 'application/json')
  return fetch(`${url}${path}`, { ...request, headers })
}

function endSession(token: string) {
  if (readAuthSession()?.token === token) {
    clearAuthSession()
    window.dispatchEvent(new Event(authSessionExpiredEvent))
  }
  return new SupabaseError('Session expired', 401)
}

let pendingRefresh: { token: string; promise: Promise<string> } | undefined

async function rotateToken(token: string) {
  const current = readAuthSession()
  if (!current || !sameAuthSession(current.token, token)) throw endSession(token)
  if (current.token !== token) return current.token
  if (!current.refreshToken) throw endSession(token)

  const response = await send('/auth/v1/token?grant_type=refresh_token', null, {
    method: 'POST',
    body: JSON.stringify({ refresh_token: current.refreshToken }),
    signal: AbortSignal.timeout(15000),
  })
  if (!response.ok) {
    const error = await responseError(response)
    const latest = readAuthSession()
    if (latest && latest.token !== token && sameAuthSession(latest.token, token)) return latest.token
    if ([400, 401, 403].includes(error.status)
      || ['refresh_token_not_found', 'refresh_token_already_used', 'session_not_found'].includes(error.code ?? '')) {
      throw endSession(token)
    }
    throw error
  }

  const next = await response.json() as { access_token?: string; refresh_token?: string }
  if (!next.access_token || !next.refresh_token) throw new Error('Could not refresh the session.')
  const latest = readAuthSession()
  if (!latest || !sameAuthSession(latest.token, token)) throw endSession(token)
  if (latest.token !== token) return latest.token
  saveAuthSession({ token: next.access_token, refreshToken: next.refresh_token })
  return next.access_token
}

function refreshSession(token: string) {
  if (pendingRefresh && sameAuthSession(pendingRefresh.token, token)) return pendingRefresh.promise
  // Read the latest token again under the lock, since another tab may have rotated it.
  const promise = (navigator.locks
    ? navigator.locks.request(authSessionKey, () => rotateToken(token))
    : rotateToken(token)).finally(() => {
    if (pendingRefresh?.promise === promise) pendingRefresh = undefined
  })
  pendingRefresh = { token, promise }
  return promise
}

function rejectedToken(path: string, error: SupabaseError) {
  if (error.status !== 401 && error.status !== 403) return false
  return (path === '/auth/v1/user' && error.status === 401)
    || ['PGRST301', 'PGRST303', 'bad_jwt', 'session_not_found', 'user_not_found'].includes(error.code ?? '')
    || /^(jwt expired|invalid jwt)\.?$/i.test(error.message)
}

async function supabaseFetch(path: string, { token, ...request }: RequestOptions) {
  const stored = token && readAuthSession()
  // An in-flight action can still hold an older JWT for the same session.
  const session = token && stored && sameAuthSession(token, stored.token) ? stored : null
  let accessToken = session?.token ?? token
  if (session && expiresWithin(session.token, session.refreshToken ? 30 : 0)) {
    accessToken = await refreshSession(session.token)
  }
  request.signal?.throwIfAborted()
  const response = await send(path, accessToken, request)
  if (!session || !accessToken || (response.status !== 401 && response.status !== 403)) return response
  if (!rejectedToken(path, await responseError(response.clone()))) return response
  request.signal?.throwIfAborted()
  const refreshed = await refreshSession(accessToken)
  request.signal?.throwIfAborted()
  return send(path, refreshed, request)
}

export async function supabaseRequest<T>(path: string, options: RequestOptions = {}): Promise<T> {
  const response = await supabaseFetch(path, options)
  if (!response.ok) throw await responseError(response)
  if (response.status === 204) return undefined as T
  // PostgREST can return an empty body for successful writes.
  const body = await response.text()
  return (body ? JSON.parse(body) : undefined) as T
}

function encodedStoragePath(path: string) {
  return path.split('/').map(encodeURIComponent).join('/')
}

function safeFilename(name: string) {
  const extension = name.split('.').pop()?.toLowerCase()
  const permittedExtension = extension && ['jpg', 'jpeg', 'png', 'webp'].includes(extension) ? extension : 'jpg'
  return `${crypto.randomUUID()}.${permittedExtension}`
}

export async function uploadBannerImage(storeId: string, file: File, token: string) {
  if (!url || !anonKey) throw new Error('Supabase is not configured')
  if (!['image/jpeg', 'image/png', 'image/webp'].includes(file.type)) throw new Error('Use a JPG, PNG, or WebP image')
  if (file.size > 5 * 1024 * 1024) throw new Error('Image must be 5 MB or smaller')
  const path = `${storeId}/${safeFilename(file.name)}`
  const response = await supabaseFetch(`/storage/v1/object/storefront-banners/${encodedStoragePath(path)}`, {
    method: 'POST', token, headers: { 'Content-Type': file.type }, body: file,
  })
  if (!response.ok) throw await responseError(response)
  return { path, publicUrl: `${url}/storage/v1/object/public/storefront-banners/${encodedStoragePath(path)}` }
}

export async function removeBannerImage(path: string, token: string) {
  if (!url || !anonKey || !path) return
  const response = await supabaseFetch(`/storage/v1/object/storefront-banners/${encodedStoragePath(path)}`, { method: 'DELETE', token })
  if (!response.ok && response.status !== 404) throw await responseError(response)
}

export async function uploadProductImage(productId: string, file: File, token: string) {
  if (!url || !anonKey) throw new Error('Supabase is not configured')
  const allowedTypes = ['image/jpeg', 'image/png', 'image/webp']
  if (!allowedTypes.includes(file.type)) throw new Error('Use a JPG, PNG, or WebP image')
  if (file.size > 5 * 1024 * 1024) throw new Error('Image must be 5 MB or smaller')

  const storagePath = `products/${productId}/${safeFilename(file.name)}`
  const response = await supabaseFetch(`/storage/v1/object/product-images/${encodedStoragePath(storagePath)}`, {
    method: 'POST', token, headers: { 'Content-Type': file.type, 'x-upsert': 'false' }, body: file,
  })
  if (!response.ok) throw await responseError(response)
  return {
    storagePath,
    publicUrl: `${url}/storage/v1/object/public/product-images/${encodedStoragePath(storagePath)}`,
  }
}

export async function removeProductImage(storagePath: string, token: string) {
  if (!url || !anonKey || !storagePath.startsWith('products/')) return
  const response = await supabaseFetch(`/storage/v1/object/product-images/${encodedStoragePath(storagePath)}`, { method: 'DELETE', token })
  if (!response.ok && response.status !== 404) throw await responseError(response)
}
