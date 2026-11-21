import { test } from 'node:test'
import assert from 'node:assert/strict'
import { reconcilePayment } from '../supabase/functions/_shared/discount-payments.ts'

const mono = { provider: 'MONOBANK', provider_order_id: 'invoice', id: 'checkout', test_mode: false }
globalThis.Deno = { env: { get: key => ({
  MONOBANK_TOKEN: 'test', LIQPAY_LIVE_PUBLIC_KEY: 'test', LIQPAY_LIVE_PRIVATE_KEY: 'test',
})[key] } }

test('reconciliation settles a verified invoice through the same RPC as the webhook', async ({ mock }) => {
  let provider = 'MONOBANK'
  const confirmed = []
  const db = { rpc: async (name, args) => { confirmed.push([name,args]); return {} } }
  mock.method(globalThis, 'fetch', async (url, options) => {
    if (provider === 'MONOBANK') {
      assert.ok(url.includes('/invoice/status'))
      return Response.json({ invoiceId: 'invoice', reference: 'checkout', amount: 10125, ccy: 980, status: 'success' })
    }
    const data = JSON.parse(Buffer.from(options.body.get('data'), 'base64'))
    assert.equal(data.action, 'status')
    return Response.json({ order_id: 'invoice', currency: 'UAH', amount: '101.25', payment_id: 42, status: 'success' })
  })
  for (provider of ['MONOBANK', 'LIQPAY']) {
    assert.equal(await reconcilePayment(db, { ...mono, provider }, false), null)
    const [rpc,args] = confirmed.at(-1)
    assert.equal(rpc, 'confirm_online_checkout')
    assert.equal(args.p_provider, provider)
    assert.equal(args.p_amount, 10125)
  }
})

test('missing reference and provider outage are sent to review', async ({ mock }) => {
  mock.method(globalThis,'fetch',async () => new Response(null,{status:503}))
  assert.equal(await reconcilePayment({},mono,true),'Bank lookup unavailable')
  assert.equal(await reconcilePayment({},{...mono,provider_order_id:null},true),'Missing bank reference')
})
