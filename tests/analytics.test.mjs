import test from 'node:test'
import assert from 'node:assert/strict'
import { calculateAnalytics } from '../src/lib/analytics.ts'

const order = (id, overrides = {}) => ({ id, user_id: null, customer_phone: '+380686224700', customer_email: '', status: 'DELIVERED', payment_status: 'PAID', total_price: 10000, currency: 'UAH', ...overrides })
test('unknown costs excluded from margin; known zero cost included; returns reduce net revenue', () => {
  const result = calculateAnalytics([order('a'), order('b'), order('c')], [{ order_id: 'a', cost_amount: 6000 }, { order_id: 'c', cost_amount: 0 }], [{ order_id: 'a', amount: 2000 }]).currencies[0]
  assert.equal(result.margin, 12000)
  assert.equal(result.netRevenue, 28000)
  assert.equal(result.known, 2)
  assert.equal(result.returnedOrders, 1)
})
test('currencies stay separate and cancelled orders do not contribute revenue', () => {
  const result = calculateAnalytics([order('a'), order('b', { currency: 'USD', total_price: 500 }), order('c', { status: 'CANCELLED_BY_STORE' })], [], [])
  assert.deepEqual(result.currencies.map(row => [row.currency, row.netRevenue]), [['UAH', 10000], ['USD', 500]])
})
test('repeat customers exclude unpaid/cancelled orders and normalize Ukrainian phone format', () => {
  const result = calculateAnalytics([order('a'), order('b', { customer_phone: '068 622 47 00' }), order('c', { status: 'PENDING', payment_status: 'PENDING', customer_phone: '111' }), order('d', { status: 'CANCELLED_BY_USER', customer_phone: '222' })], [], [])
  assert.equal(result.customers, 1)
  assert.equal(result.repeat, 1)
})
test('empty data yields no fabricated margin or customer rates', () => {
  assert.deepEqual(calculateAnalytics([], [], []), { customers: 0, repeat: 0, currencies: [] })
})
