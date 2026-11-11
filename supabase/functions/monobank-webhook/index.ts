import { createClient } from 'npm:@supabase/supabase-js@2'
import { Buffer } from 'node:buffer'
import { createPublicKey, verify, type KeyObject } from 'node:crypto'
import { monobankApi, monobankToken } from '../_shared/monobank.ts'

type Callback = { invoiceId?: string; status?: string }

const publicKeys = new Map<string, { key: KeyObject; fetchedAt: number }>()

async function validSignature(token: string, body: Buffer, signature: Buffer) {
  const publicKey = publicKeys.get(token)
  if (publicKey) {
    if (verify('sha256', body, publicKey.key, signature)) return true
    // Allow key rotation without fetching a key for every invalid request.
    if (Date.now() - publicKey.fetchedAt < 60_000) return false
  }
  const response = await fetch(`${monobankApi}/pubkey`, {
    headers: { 'X-Token': token }, signal: AbortSignal.timeout(5000),
  })
  if (!response.ok) throw new Error('Monobank public key is unavailable')
  const { key } = await response.json() as { key: string }
  const parsedKey = createPublicKey(Buffer.from(key, 'base64'))
  publicKeys.set(token, { key: parsedKey, fetchedAt: Date.now() })
  return verify('sha256', body, parsedKey, signature)
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 })
  const signature = request.headers.get('X-Sign')
  if (!signature || signature.length > 128 || !/^[A-Za-z0-9+/]+={0,2}$/.test(signature)) {
    return new Response('Missing or invalid signature', { status: 401 })
  }
  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SECRET_KEY')
  if (!supabaseUrl || !serviceRoleKey) return new Response('Not configured', { status: 503 })
  try {
    const raw = Buffer.from(await request.arrayBuffer())
    const callback = JSON.parse(raw.toString('utf8')) as Callback
    if (typeof callback?.invoiceId !== 'string' || !/^[A-Za-z0-9_-]{1,128}$/.test(callback.invoiceId)) {
      return new Response('Missing or invalid invoice ID', { status: 400 })
    }
    const client = createClient(supabaseUrl, serviceRoleKey)
    const { data: invoiceOrder, error: lookupError } = await client.from('payments')
      .select('orders!inner(monobank_test_mode)').eq('provider_order_id', callback.invoiceId).eq('provider', 'MONOBANK')
      .maybeSingle<{ orders: { monobank_test_mode: boolean } }>()
    if (lookupError) throw lookupError
    if (!invoiceOrder) return new Response('Invoice not found', { status: 404 })
    const monoToken = monobankToken(invoiceOrder.orders.monobank_test_mode)
    if (!monoToken) return new Response('Not configured', { status: 503 })
    if (!await validSignature(monoToken, raw, Buffer.from(signature, 'base64'))) {
      return new Response('Invalid signature', { status: 401 })
    }
    // Bank callbacks may arrive out of order. Read the current invoice status.
    const statusResponse = await fetch(`${monobankApi}/invoice/status?invoiceId=${encodeURIComponent(callback.invoiceId)}`, {
      headers: { 'X-Token': monoToken }, signal: AbortSignal.timeout(5000),
    })
    const invoice = await statusResponse.json() as { status?: string }
    if (!statusResponse.ok) throw new Error('Monobank status check failed')
    const paid = invoice.status === 'success'
    if (!paid && invoice.status !== 'failure' && invoice.status !== 'expired') return new Response('OK')
    const { error } = await client.rpc('apply_online_payment_callback', {
      p_provider: 'MONOBANK', p_reference: callback.invoiceId, p_paid: paid,
      p_payment_id: null, p_callback: callback,
    })
    if (error) throw new Error(error.message)
    return new Response('OK')
  } catch (error) { return new Response(error instanceof Error ? error.message : 'Webhook failed', { status: 500 }) }
})
