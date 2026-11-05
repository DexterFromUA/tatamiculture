import { createClient } from 'npm:@supabase/supabase-js@2'
import { CheckoutOrderError, createOnlineOrder } from '../_shared/checkout-order.ts'

type CheckoutBody = {
  diagnostic?: boolean
  storeId: string
  items: Array<{ optionId: string; quantity: number }>
  checkout: { name: string; email: string; phone: string; city: string; address: string; note: string; cityRef?: string; addressRef?: string; deliveryServiceType?: string }
}

function toBase64(bytes: Uint8Array) {
  let binary = ''
  for (const byte of bytes) binary += String.fromCharCode(byte)
  return btoa(binary)
}

function encodeLiqPayData(payload: Record<string, unknown>) {
  return toBase64(new TextEncoder().encode(JSON.stringify(payload)))
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

function liqPaySha3Signature(privateKey: string, data: string) {
  return toBase64(sha3_256(`${privateKey}${data}${privateKey}`))
}

// The merchant's current LiqPay sandbox validates the legacy SHA-1 scheme.
// Keep SHA3 above only for the non-payment diagnostic vector.
async function liqPaySignature(privateKey: string, data: string) {
  const hash = await crypto.subtle.digest('SHA-1', new TextEncoder().encode(`${privateKey}${data}${privateKey}`))
  return toBase64(new Uint8Array(hash))
}

const json = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
  status,
  headers: {
    'Content-Type': 'application/json',
    'Access-Control-Allow-Origin': '*',
    'Access-Control-Allow-Headers': 'authorization, apikey, content-type',
  },
})

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type' } })
  if (request.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? Deno.env.get('SUPABASE_PUBLISHABLE_KEY')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SECRET_KEY')
  // Dashboard copy/paste can leave a trailing line break in a secret. It would
  // change the SHA3 input and make LiqPay reject an otherwise valid key pair.
  const publicKey = Deno.env.get('LIQPAY_PUBLIC_KEY')?.trim()
  const privateKey = Deno.env.get('LIQPAY_PRIVATE_KEY')?.trim()
  const testMode = Deno.env.get('LIQPAY_TEST_MODE') === 'true'
  const siteUrl = Deno.env.get('SITE_URL')?.replace(/\/$/, '')
  if (!supabaseUrl || !anonKey || !serviceRoleKey || !publicKey || !privateKey) {
    return json({ error: 'Payment service is not configured' }, 503)
  }

  try {
    const body = await request.json() as CheckoutBody
    // Safe one-off diagnostic for configuring Edge Function secrets. It never
    // creates an order and never returns a private key or its digest.
    if (body.diagnostic === true) {
      const exampleData = 'eyJwdWJsaWNfa2V5IjoiaTAwMDAwMDAwIiwidmVyc2lvbiI6NywiYWN0aW9uIjoicGF5IiwiYW1vdW50IjoiMyIsImN1cnJlbmN5IjoiVUFIIiwiZGVzY3JpcHRpb24iOiJ0ZXN0Iiwib3JkZXJfaWQiOiIwMDAwMDEifQ=='
      const examplePrivateKey = 'a4825234f4bae72a0be04eafe9e8e2bada209255'
      const providerData = encodeLiqPayData({
        public_key: publicKey,
        version: '3',
        action: 'status',
        order_id: `signature-check-${crypto.randomUUID()}`,
        ...(testMode ? { sandbox: 1 } : {}),
      })
      const providerResponse = await fetch('https://www.liqpay.ua/api/request', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ data: providerData, signature: liqPaySha3Signature(privateKey, providerData) }),
      })
      const providerBody = await providerResponse.text()
      const legacyProviderResponse = await fetch('https://www.liqpay.ua/api/request', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({ data: providerData, signature: await liqPaySignature(privateKey, providerData) }),
      })
      const legacyProviderBody = await legacyProviderResponse.text()
      return json({
        sha3ImplementationOk: liqPaySha3Signature(examplePrivateKey, exampleData) === '0adgJ8F2Ds5HCVkcz4AlmdLMRoIJf7IxsL3QmeFRz/s=',
        publicKey,
        publicKeyIsSandbox: publicKey.startsWith('sandbox_'),
        privateKeyIsSandbox: privateKey.startsWith('sandbox_'),
        privateKeyLength: privateKey.length,
        privateKeyHasWrappingQuotes: (/^["']/.test(privateKey) || /["']$/.test(privateKey)),
        testMode,
        providerStatus: providerResponse.status,
        providerResponse: providerBody,
        legacySha1ProviderStatus: legacyProviderResponse.status,
        legacySha1ProviderResponse: legacyProviderBody,
      })
    }
    const serviceClient = createClient(supabaseUrl, serviceRoleKey)
    const order = await createOnlineOrder(serviceClient, request, anonKey, 'LIQPAY', body)

    const { data: items, error: itemsError } = await serviceClient
      .from('order_items')
      .select('product_name,variant_name,quantity,unit_price')
      .eq('order_id', order.id)
    if (itemsError || !items?.length) throw new Error(itemsError?.message ?? 'Order has no items')

    const payload = {
      public_key: publicKey,
      version: '3',
      action: 'pay',
      amount: Number(order.total_price) / 100,
      currency: String(order.currency),
      description: `Tatami.Culture order ${order.receipt_code}`,
      order_id: order.id,
      // LiqPay does not need a return URL to complete the payment: the webhook
      // below is authoritative. A browser-local URL is not reachable by LiqPay,
      // so only send result_url once the storefront has a public URL.
      ...(siteUrl && !/^https?:\/\/(localhost|127\.0\.0\.1)(?::\d+)?$/i.test(siteUrl)
        ? { result_url: `${siteUrl}/receipt/${order.receipt_code}?payment=return` }
        : {}),
      server_url: `${supabaseUrl}/functions/v1/liqpay-webhook`,
      language: 'uk',
      ...(testMode ? { sandbox: 1 } : {}),
      product_name: items.map((item) => `${item.product_name} (${item.variant_name})`),
      product_count: items.map((item) => item.quantity),
      product_price: items.map((item) => Number(item.unit_price) / 100),
    }
    const data = encodeLiqPayData(payload)
    const signature = await liqPaySignature(privateKey, data)
    const { error: paymentError } = await serviceClient.from('payments').insert({
      order_id: order.id,
      provider: 'LIQPAY',
      provider_order_id: order.id,
      status: 'PENDING',
    })
    if (paymentError) throw new Error(paymentError.message)
    return json({ data, signature })
  } catch (error) {
    return json({ error: error instanceof Error ? error.message : 'Checkout could not be started' }, error instanceof CheckoutOrderError ? error.status : 400)
  }
})
