import { readJson, removeKey, writeJson } from './storage'

export const authSessionKey = 'shop.store.token'
export const authSessionExpiredEvent = 'tatami:session-expired'

type Credentials = { token: string; refreshToken?: string }

export function readAuthSession(): Credentials | null {
  return storedCredentials(readJson<Credentials | string | null>(authSessionKey, null))
}

function storedCredentials(stored: Credentials | string | null): Credentials | null {
  if (typeof stored === 'string') return stored ? { token: stored } : null
  return typeof stored?.token === 'string' && stored.token ? stored : null
}

export function previousSessionToken(raw: string | null) {
  try {
    return storedCredentials(JSON.parse(raw ?? 'null'))?.token
  } catch {
    return undefined
  }
}

export function saveAuthSession({ token, refreshToken }: Credentials) {
  writeJson(authSessionKey, { token, refreshToken })
}

export function clearAuthSession() {
  removeKey(authSessionKey)
}

function jwtClaims(token: string): { session_id?: string; exp?: number } {
  try {
    return JSON.parse(atob(token.split('.')[1].replace(/-/g, '+').replace(/_/g, '/'))) ?? {}
  } catch {
    return {}
  }
}

export function sameAuthSession(first: string, second: string) {
  if (first === second) return true
  const id = jwtClaims(first).session_id
  return Boolean(id && id === jwtClaims(second).session_id)
}

export function expiresWithin(token: string, seconds: number) {
  const { exp } = jwtClaims(token)
  return typeof exp === 'number' && exp * 1000 <= Date.now() + seconds * 1000
}
