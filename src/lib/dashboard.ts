import type { AnalyticsCost, AnalyticsOrder, AnalyticsReturn } from './analytics'

export type DashboardOrder = AnalyticsOrder & {
  created_at: string
  customer_name: string
  crm_customer_id: string | null
  receipt_code: string
  payment_method: 'ONLINE' | 'CASH_ON_DELIVERY'
  payment_test_mode: boolean | null
  nova_poshta_ttn: string | null
  nova_poshta_document_ref: string | null
  customer_discount_amount: number
}
export type DashboardSale = {
  id: string; order_id: string; product_id: string | null; variant_id: string | null
  product_name: string; variant_name: string; quantity: number; line_total: number
  order_item_costs: { unit_cost: number | null } | null
}
export type DashboardInventory = {
  id: string; name: string; is_active: boolean; created_at: string
  product_variants: { id: string; name: string; stock_quantity: number; low_stock_threshold?: number; is_preorder: boolean }[]
}
export type DashboardRange = { from: string; to: string; previousFrom: string; previousTo: string; days: number }

const dayFormatter = new Intl.DateTimeFormat('en-CA', { timeZone: 'Europe/Kyiv', year: 'numeric', month: '2-digit', day: '2-digit' })
export function dashboardDay(iso: string | number) {
  return dayFormatter.format(new Date(iso))
}
export function shiftDay(day: string, amount: number) {
  const date = new Date(day + 'T12:00:00Z')
  date.setUTCDate(date.getUTCDate() + amount)
  return date.toISOString().slice(0, 10)
}
export function dashboardRange(from: string, to: string): DashboardRange | null {
  if (!/^\d{4}-\d{2}-\d{2}$/.test(from) || !/^\d{4}-\d{2}-\d{2}$/.test(to) || from > to) return null
  const difference = Date.parse(to + 'T12:00:00Z') - Date.parse(from + 'T12:00:00Z')
  if (!Number.isFinite(difference)) return null
  const days = Math.round(difference / 86400000) + 1
  return { from, to, days, previousFrom: shiftDay(from, -days), previousTo: shiftDay(from, -1) }
}

export function alignMergedOrderDates(orders: DashboardOrder[], rootById: Map<string, string>) {
  const byId = new Map(orders.map(order => [order.id, order]))
  return orders.map(order => {
    const root = byId.get(rootById.get(order.id) ?? order.id)
    return root ? { ...order, created_at: root.created_at } : order
  })
}
export const isCancelled = (order: Pick<DashboardOrder, 'status'>) => order.status.startsWith('CANCELLED')
export const inDashboardRange = (order: Pick<DashboardOrder, 'created_at'>, from: string, to: string) => {
  const day = dashboardDay(order.created_at)
  return day >= from && day <= to
}
export function dashboardCustomer(order: AnalyticsOrder & { crm_customer_id?: string | null }) {
  const phone = order.customer_phone.replace(/\D/g, '')
  if (phone) return `phone:${phone.length >= 9 ? phone.slice(-9) : phone}`
  return order.crm_customer_id || order.user_id || order.customer_email.trim().toLowerCase() || null
}

export function dashboardMetrics(orders: DashboardOrder[], costs: AnalyticsCost[], refunds: AnalyticsReturn[], rootById: Map<string, string>) {
  const valid = orders.filter(order => !isCancelled(order))
  const delivered = valid.filter(order => order.status === 'COMPLETED')
  const costById = new Map(costs.map(row => [row.order_id, Number(row.cost_amount)]))
  const refundById = new Map<string, number>()
  for (const refund of refunds) refundById.set(refund.order_id, (refundById.get(refund.order_id) ?? 0) + Number(refund.amount))
  const grouped = new Map<string, DashboardOrder[]>()
  for (const order of delivered) {
    const root = rootById.get(order.id) ?? order.id
    grouped.set(root, [...(grouped.get(root) ?? []), order])
  }
  const known = [...grouped.values()].filter(members => members.every(order => costById.has(order.id)))
  const count = new Set(valid.map(order => rootById.get(order.id) ?? order.id)).size
  const revenue = valid.reduce((sum, order) => sum + Number(order.total_price), 0)
  const refunded = delivered.reduce((sum, order) => sum + (refundById.get(order.id) ?? 0), 0)
  const knownRevenue = known.flat().reduce((sum, order) => sum + Number(order.total_price) - (refundById.get(order.id) ?? 0), 0)
  const margin = known.flat().reduce((sum, order) => sum + Number(order.total_price) - costById.get(order.id)! - (refundById.get(order.id) ?? 0), 0)
  return {
    count, revenue, average: count ? Math.round(revenue / count) : 0,
    delivered: grouped.size, known: known.length, margin, knownRevenue, refunded,
    netDelivered: delivered.reduce((sum, order) => sum + Number(order.total_price), 0) - refunded,
    discounts: valid.reduce((sum, order) => sum + Number(order.customer_discount_amount ?? 0), 0),
    customers: new Set(valid.map(dashboardCustomer).filter(Boolean)).size,
    cancelled: new Set(orders.filter(isCancelled).map(order => rootById.get(order.id) ?? order.id)).size,
  }
}

export function dashboardTrend(orders: DashboardOrder[], range: DashboardRange) {
  const sums = new Map<string, number>()
  for (const order of orders.filter(order => !isCancelled(order))) {
    const day = dashboardDay(order.created_at)
    sums.set(day, (sums.get(day) ?? 0) + Number(order.total_price))
  }
  // Keep long custom periods readable by combining adjacent days into at most 31 bars.
  const bucketSize = Math.max(1, Math.ceil(range.days / 31))
  return Array.from({ length: Math.ceil(range.days / bucketSize) }, (_, index) => {
    const offset = index * bucketSize
    let current = 0
    let previous = 0
    for (let day = offset; day < Math.min(offset + bucketSize, range.days); day++) {
      current += sums.get(shiftDay(range.from, day)) ?? 0
      previous += sums.get(shiftDay(range.previousFrom, day)) ?? 0
    }
    return { from: shiftDay(range.from, offset), to: shiftDay(range.from, Math.min(offset + bucketSize, range.days) - 1), current, previous }
  })
}
