export class NovaPoshtaRateLimit extends Error {
  constructor(readonly retryAfter = 60, readonly rejected = false) {
    super('Too many Nova Poshta requests. Wait a minute and try again.')
  }
}

export function novaPoshtaRateLimit(response: Response, errors = '', rejected = false) {
  if (response.status !== 429 && !/too many requests|rate limit|request limit|забагато запитів|багато запитів/i.test(errors)) return null
  const retryAfter = response.headers.get('Retry-After')?.trim()
  const seconds = retryAfter && /^\d+$/.test(retryAfter) ? Number(retryAfter)
    : retryAfter ? Math.ceil((Date.parse(retryAfter) - Date.now()) / 1000) : NaN
  return new NovaPoshtaRateLimit(Number.isFinite(seconds) ? Math.max(1, seconds) : undefined, rejected)
}
