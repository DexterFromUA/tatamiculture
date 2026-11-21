import assert from 'node:assert/strict'
import { test } from 'node:test'
import { refundOrderPayment } from '../supabase/functions/_shared/order-refunds.ts'
import { decodeLiqPayData } from '../supabase/functions/_shared/liqpay.ts'

globalThis.Deno = { env: { get: key => ({
  MONOBANK_TOKEN: 'merchant-test-placeholder',
  LIQPAY_LIVE_PUBLIC_KEY: 'public-placeholder',
  LIQPAY_LIVE_PRIVATE_KEY: 'private-placeholder',
})[key] } }

const operation = {
  id: 'refund-reference', amount: 15000, currency: 'UAH', reference: 'original-payment',
  payment_id: null, payment_test_mode: false, provider: 'MONOBANK',
}
const monoStatus = { invoiceId: operation.reference, status: 'success', amount: 15000, ccy: 980 }

test('Monobank keeps an uncertain submission pending and checks the same refund without resending', async ({ mock }) => {
  const fetch = mock.method(globalThis, 'fetch', async (url, options) => {
    if (url.includes('/invoice/cancel')) {
      assert.deepEqual(JSON.parse(options.body), { invoiceId: operation.reference, extRef: operation.id })
      throw new Error('Connection interrupted')
    }
    return Response.json(monoStatus)
  })
  assert.equal((await refundOrderPayment(operation, false)).status, 'processing')
  assert.equal(fetch.mock.callCount(), 2)
  mock.method(globalThis, 'fetch', async (url) => {
    assert.ok(url.includes('/invoice/status'))
    return Response.json({ ...monoStatus, status: 'reversed',
      cancelList: [{ extRef: operation.id, amount: 15000, status: 'success' }] })
  })
  assert.equal((await refundOrderPayment(operation, true)).status, 'completed')
})

test('a mismatch in the original payment amount prevents a Monobank refund', async ({ mock }) => {
  const fetch = mock.method(globalThis, 'fetch', async () => Response.json({ ...monoStatus, amount: 16000 }))
  assert.equal((await refundOrderPayment(operation, false)).status, 'failed')
  assert.equal(fetch.mock.callCount(), 1)
})

test('LiqPay requests the original payment amount and keeps deferred refunds pending', async ({ mock }) => {
  const liqPay = { ...operation, provider: 'LIQPAY', payment_id: '42' }
  const status = { order_id: operation.reference, currency: 'UAH', amount: 150, payment_id: 42 }
  const fetch = mock.method(globalThis, 'fetch', async (url, options) => {
    assert.equal(url, 'https://www.liqpay.ua/api/request')
    const payload = decodeLiqPayData(options.body.get('data'))
    assert.equal(payload.order_id, operation.reference)
    if (payload.action === 'status') return Response.json({ ...status, status: 'success' })
    assert.equal(payload.action, 'refund')
    assert.equal(payload.amount, 150)
    return Response.json({ result: 'ok', status: 'reversed', payment_id: 42, wait_amount: 'true' })
  })
  assert.equal((await refundOrderPayment(liqPay, false)).status, 'processing')
  assert.equal(fetch.mock.callCount(), 2)
  mock.method(globalThis, 'fetch', async (_url, options) => {
    assert.equal(decodeLiqPayData(options.body.get('data')).action, 'status')
    return Response.json({ ...status, status: 'reversed', amount_return: 150 })
  })
  assert.equal((await refundOrderPayment(liqPay, true)).status, 'completed')
})
