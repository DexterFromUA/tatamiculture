import { createClient } from 'npm:@supabase/supabase-js@2'

type LiqPayCallback = { order_id: string; payment_id?: string | number; status: string }

function toBase64(bytes: Uint8Array) {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary)
}

const SHA3_ROUNDS = [
  0x0000000000000001n, 0x0000000000008082n, 0x800000000000808an, 0x8000000080008000n,
  0x000000000000808bn, 0x0000000080000001n, 0x8000000080008081n, 0x8000000000008009n,
  0x000000000000008an, 0x0000000000000088n, 0x0000000080008009n, 0x000000008000000an,
  0x000000008000808bn, 0x800000000000008bn, 0x8000000000008089n, 0x8000000000008003n,
  0x8000000000008002n, 0x8000000000000080n, 0x000000000000800an, 0x800000008000000an,
  0x8000000080008081n, 0x8000000000008080n, 0x0000000080000001n, 0x8000000080008008n,
]
const SHA3_ROTATIONS = [
  [0, 36, 3, 41, 18], [1, 44, 10, 45, 2], [62, 6, 43, 15, 61],
  [28, 55, 25, 21, 56], [27, 20, 39, 8, 14],
]
const WORD_MASK = (1n << 64n) - 1n

function rotateLeft(value: bigint, shift: number) {
  if (shift === 0) return value
  const bits = BigInt(shift)
  return ((value << bits) | (value >> (64n - bits))) & WORD_MASK
}

function keccakF1600(state: bigint[]) {
  for (const roundConstant of SHA3_ROUNDS) {
    const columns = Array.from({ length: 5 }, (_, x) => state[x] ^ state[x + 5] ^ state[x + 10] ^ state[x + 15] ^ state[x + 20])
    for (let x = 0; x < 5; x += 1) {
      const delta = columns[(x + 4) % 5] ^ rotateLeft(columns[(x + 1) % 5], 1)
      for (let y = 0; y < 5; y += 1) state[x + 5 * y] ^= delta
    }
    const next = Array<bigint>(25).fill(0n)
    for (let x = 0; x < 5; x += 1) for (let y = 0; y < 5; y += 1) next[y + 5 * ((2 * x + 3 * y) % 5)] = rotateLeft(state[x + 5 * y], SHA3_ROTATIONS[x][y])
    for (let x = 0; x < 5; x += 1) for (let y = 0; y < 5; y += 1) state[x + 5 * y] = next[x + 5 * y] ^ ((~next[(x + 1) % 5 + 5 * y]) & next[(x + 2) % 5 + 5 * y])
    state[0] ^= roundConstant
  }
}

function sha3_256(input: string) {
  const bytes = new TextEncoder().encode(input)
  const rate = 136
  const padded = new Uint8Array(Math.ceil((bytes.length + 1) / rate) * rate)
  padded.set(bytes)
  padded[bytes.length] = 0x06
  padded[padded.length - 1] |= 0x80
  const state = Array<bigint>(25).fill(0n)
  for (let offset = 0; offset < padded.length; offset += rate) {
    for (let index = 0; index < rate; index += 1) state[Math.floor(index / 8)] ^= BigInt(padded[offset + index]) << BigInt((index % 8) * 8)
    keccakF1600(state)
  }
  const hash = new Uint8Array(32)
  for (let index = 0; index < hash.length; index += 1) hash[index] = Number((state[Math.floor(index / 8)] >> BigInt((index % 8) * 8)) & 0xffn)
  return hash
}

async function liqPaySignature(privateKey: string, data: string) {
  const hash = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(`${privateKey}${data}${privateKey}`))
  return toBase64(new Uint8Array(hash))
}

function secureEqual(left: string, right: string) {
  let difference = left.length ^ right.length
  const length = Math.max(left.length, right.length)
  for (let index = 0; index < length; index += 1) {
    difference |= (left.charCodeAt(index) || 0) ^ (right.charCodeAt(index) || 0)
  }
  return difference === 0
}

function decodeLiqPayData<T>(data: string): T {
  const binary = atob(data)
  const bytes = Uint8Array.from(binary, (character) => character.charCodeAt(0))
  return JSON.parse(new TextDecoder().decode(bytes)) as T
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 })
  const privateKey = Deno.env.get('LIQPAY_PRIVATE_KEY')?.trim()
  const testMode = Deno.env.get('LIQPAY_TEST_MODE') === 'true'
  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SECRET_KEY')
  if (!privateKey || !supabaseUrl || !serviceRoleKey) return new Response('Not configured', { status: 503 })

  try {
    const form = await request.formData()
    const data = String(form.get('data') ?? '')
    const signature = String(form.get('signature') ?? '')
    if (!data || !signature || !secureEqual(await liqPaySignature(privateKey, data), signature)) {
      return new Response('Invalid signature', { status: 401 })
    }
    const callback = decodeLiqPayData<LiqPayCallback>(data)
    const client = createClient(supabaseUrl, serviceRoleKey)
    const paymentStatus = callback.status === 'success' || (testMode && callback.status === 'sandbox') ? 'PAID' : callback.status === 'failure' || callback.status === 'error' ? 'FAILED' : 'PENDING'
    const { error: paymentError } = await client.from('payments').update({
      status: paymentStatus,
      provider_payment_id: callback.payment_id ? String(callback.payment_id) : null,
      raw_callback: callback,
    }).eq('provider_order_id', callback.order_id)
    if (paymentError) throw paymentError
    if (paymentStatus === 'PAID') {
      const { error: orderError } = await client.from('orders').update({ status: 'PAID', payment_status: 'PAID' }).eq('id', callback.order_id)
      if (orderError) throw orderError
    } else if (paymentStatus === 'FAILED') {
      const { error: orderError } = await client.from('orders').update({ payment_status: 'FAILED' }).eq('id', callback.order_id)
      if (orderError) throw orderError
    }
    return new Response('OK')
  } catch (error) {
    return new Response(error instanceof Error ? error.message : 'Webhook failed', { status: 400 })
  }
})
