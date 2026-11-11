import { createClient } from 'npm:@supabase/supabase-js@2'
import { decodeLiqPayData, legacyLiqPayKeys, liqPayKeys, liqPaySignature, secureEqual } from '../_shared/liqpay.ts'

type LiqPayCallback = { order_id: string; payment_id?: string | number; status: string }

Deno.serve(async (request) => {
  if (request.method !== 'POST') return new Response('Method not allowed', { status: 405 })
  const supabaseUrl = Deno.env.get('SUPABASE_URL')
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? Deno.env.get('SUPABASE_SECRET_KEY')
  if (!supabaseUrl || !serviceRoleKey) return new Response('Not configured', { status: 503 })

  try {
    const form = await request.formData()
    const data = form.get('data')
    const signature = form.get('signature')
    if (typeof data !== 'string' || !data || typeof signature !== 'string' || !/^[A-Za-z0-9+/]{27}=$/.test(signature)) {
      return new Response('Invalid signature', { status: 401 })
    }
    const callback = decodeLiqPayData<LiqPayCallback>(data)
    if (typeof callback?.order_id !== 'string' || !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i.test(callback.order_id)) {
      return new Response('Invalid order ID', { status: 400 })
    }

    const client = createClient(supabaseUrl, serviceRoleKey)
    const { data: payment, error: lookupError } = await client.from('payments')
      .select('order_id,orders!inner(payment_test_mode)')
      .eq('provider_order_id', callback.order_id).eq('provider', 'LIQPAY')
      .maybeSingle<{ order_id: string; orders: { payment_test_mode: boolean | null } }>()
    if (lookupError) throw lookupError
    if (!payment) return new Response('Invoice not found', { status: 404 })
    const storedMode = payment.orders.payment_test_mode
    const testMode = storedMode ?? (Deno.env.get('LIQPAY_TEST_MODE') === 'true')
    const keys = storedMode == null ? legacyLiqPayKeys() : liqPayKeys(testMode)
    if (!keys) return new Response('Not configured', { status: 503 })
    if (!secureEqual(await liqPaySignature(keys.privateKey, data), signature)) {
      return new Response('Invalid signature', { status: 401 })
    }

    const paid = callback.status === 'success' || (testMode && callback.status === 'sandbox')
    const failed = callback.status === 'failure' || callback.status === 'error'
    if (!paid && !failed) return new Response('OK')
    const { error } = await client.rpc('apply_online_payment_callback', {
      p_provider: 'LIQPAY', p_reference: callback.order_id, p_paid: paid,
      p_payment_id: callback.payment_id ? String(callback.payment_id) : null, p_callback: callback,
    })
    if (error) throw new Error(error.message)
    return new Response('OK')
  } catch (error) {
    return new Response(error instanceof Error ? error.message : 'Webhook failed', { status: 500 })
  }
})
