// Stable import IDs let the existing CRM order RPC handle retries atomically.
export async function stableOrderId(parts: unknown[]) {
  const digest = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(JSON.stringify(parts)))
  const bytes = new Uint8Array(digest).slice(0, 16)
  bytes[6] = (bytes[6] & 15) | 128
  bytes[8] = (bytes[8] & 63) | 128
  const hex = Array.from(bytes, n => n.toString(16).padStart(2, '0')).join('')
  return [hex.slice(0, 8), hex.slice(8, 12), hex.slice(12, 16), hex.slice(16, 20), hex.slice(20)].join('-')
}

export function pendingCodKey(storeId: string, userId: string | undefined, items: { optionId: string; quantity: number }[]) {
  const lines = items.map(item => [item.optionId, item.quantity] as const).sort(([a], [b]) => a.localeCompare(b))
  return JSON.stringify(['tatami.cod.pending', storeId, userId ?? null, lines])
}
