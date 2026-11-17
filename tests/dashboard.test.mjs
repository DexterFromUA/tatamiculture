import test from 'node:test'
import assert from 'node:assert/strict'
import { alignMergedOrderDates, dashboardDay, dashboardRange, dashboardMetrics, dashboardTrend, dashboardCustomer, inDashboardRange } from '../src/lib/dashboard.ts'

const order = (id, extra = {}) => ({
  id, user_id: null, crm_customer_id: null, customer_name: 'Buyer', customer_phone: '+380681234567', customer_email: '',
  created_at: '2026-11-17T10:00:00Z', receipt_code: id, status: 'DELIVERED', payment_status: 'PAID',
  payment_method: 'ONLINE', payment_test_mode: false, nova_poshta_ttn: null, nova_poshta_document_ref: null,
  total_price: 10000, customer_discount_amount: 0, currency: 'UAH', ...extra,
})

test('calendar boundaries use Kyiv dates, including the DST transition', () => {
  assert.equal(dashboardDay('2026-11-16T22:30:00Z'), '2026-11-17')
  assert.equal(dashboardDay('2026-10-24T21:30:00Z'), '2026-10-25')
  assert.equal(dashboardDay('2026-10-25T22:30:00Z'), '2026-10-26')
  assert.ok(inDashboardRange(order('a', { created_at: '2026-11-16T22:30:00Z' }), '2026-11-17', '2026-11-17'))
})
test('the comparison range has the same number of calendar days across DST', () => {
  assert.deepEqual(dashboardRange('2026-10-24', '2026-10-26'), {
    from: '2026-10-24', to: '2026-10-26', days: 3, previousFrom: '2026-10-21', previousTo: '2026-10-23',
  })
  assert.equal(dashboardRange('', '2026-11-17'), null)
  assert.equal(dashboardRange('2026-11-18', '2026-11-17'), null)
})
test('merged orders count once and retain all revenue and costs', () => {
  const roots = new Map([['a', 'a'], ['b', 'a']])
  const result = dashboardMetrics([order('a'), order('b')], [{ order_id: 'a', cost_amount: 4000 }, { order_id: 'b', cost_amount: 0 }], [], roots)
  assert.equal(result.count, 1)
  assert.equal(result.average, 20000)
  assert.equal(result.revenue, 20000)
  assert.equal(result.margin, 16000)
  assert.equal(result.known, 1)
})
test('merged order members use the primary order date across period boundaries', () => {
  const roots = new Map([['b', 'a']])
  const rows = alignMergedOrderDates([order('a', { created_at: '2026-11-16T10:00:00Z' }), order('b')], roots)
  const selected = rows.filter(row => inDashboardRange(row, '2026-11-16', '2026-11-16'))
  assert.equal(dashboardMetrics(selected, [], [], roots).revenue, 20000)
  assert.equal(dashboardMetrics(selected, [], [], roots).count, 1)
  assert.equal(rows.filter(row => inDashboardRange(row, '2026-11-17', '2026-11-17')).length, 0)
})
test('partial cost coverage never invents profit for the missing part of a merged order', () => {
  const result = dashboardMetrics([order('a'), order('b')], [{ order_id: 'a', cost_amount: 4000 }], [], new Map([['b', 'a']]))
  assert.equal(result.margin, 0)
  assert.equal(result.known, 0)
  assert.equal(result.delivered, 1)
})
test('refunds use the selected order cohort and cancellations do not generate sales', () => {
  const rows = [order('a'), order('b', { status: 'CANCELLED_BY_USER' }), order('c', { status: 'PENDING', customer_discount_amount: 1000 })]
  const result = dashboardMetrics(rows, [{ order_id: 'a', cost_amount: 4000 }], [{ order_id: 'a', amount: 2000 }, { order_id: 'outside', amount: 99000 }], new Map())
  assert.equal(result.revenue, 20000)
  assert.equal(result.count, 2)
  assert.equal(result.margin, 4000)
  assert.equal(result.refunded, 2000)
  assert.equal(result.netDelivered, 8000)
  assert.equal(result.cancelled, 1)
  assert.equal(result.discounts, 1000)
})
test('guest and registered orders with the same phone share a customer identity', () => {
  assert.equal(dashboardCustomer(order('a')), dashboardCustomer(order('b', { user_id: 'user', customer_phone: '068 123 45 67' })))
  assert.equal(dashboardCustomer(order('a', { customer_phone: '', customer_email: '', user_id: null })), null)
})
test('trend buckets preserve current and previous totals and ignore cancellations', () => {
  const range = dashboardRange('2026-09-01', '2026-11-17')
  const points = dashboardTrend([order('a'), order('b', { created_at: '2026-08-01T10:00:00Z' }), order('c', { status: 'CANCELLED_BY_STORE' })], range)
  assert.ok(points.length <= 31)
  assert.equal(points.reduce((sum, point) => sum + point.current, 0), 10000)
  assert.equal(points.reduce((sum, point) => sum + point.previous, 0), 10000)
})
