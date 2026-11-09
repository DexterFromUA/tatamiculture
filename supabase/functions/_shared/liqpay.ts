const unsetLiveKey = '__LIQPAY_LIVE_KEY_NOT_CONFIGURED__'

function readPair(prefix: string) {
  const publicKey = Deno.env.get(`${prefix}_PUBLIC_KEY`)?.trim()
  const privateKey = Deno.env.get(`${prefix}_PRIVATE_KEY`)?.trim()
  if (!publicKey || !privateKey || publicKey === unsetLiveKey || privateKey === unsetLiveKey) return
  return { publicKey, privateKey }
}

export function legacyLiqPayKeys() {
  return readPair('LIQPAY')
}

export function liqPayKeys(testMode: boolean) {
  const pair = testMode ? legacyLiqPayKeys() : readPair('LIQPAY_LIVE') ?? legacyLiqPayKeys()
  if (pair?.publicKey.startsWith('sandbox_') === testMode && pair?.privateKey.startsWith('sandbox_') === testMode) return pair
}

function toBase64(bytes: Uint8Array) {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary)
}

export function encodeLiqPayData(payload: Record<string, unknown>) {
  return toBase64(new TextEncoder().encode(JSON.stringify(payload)))
}

// The existing merchant checkout uses LiqPay's legacy SHA-1 signature.
export async function liqPaySignature(privateKey: string, data: string) {
  const hash = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(`${privateKey}${data}${privateKey}`))
  return toBase64(new Uint8Array(hash))
}

export function secureEqual(left: string, right: string) {
  let difference = left.length ^ right.length
  const length = Math.max(left.length, right.length)
  for (let index = 0; index < length; index += 1) {
    difference |= (left.charCodeAt(index) || 0) ^ (right.charCodeAt(index) || 0)
  }
  return difference === 0
}

export function decodeLiqPayData<T>(data: string): T {
  const binary = atob(data)
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0))
  return JSON.parse(new TextDecoder().decode(bytes)) as T
}
