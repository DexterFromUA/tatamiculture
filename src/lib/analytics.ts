export type AnalyticsOrder = { id: string; user_id: string | null; customer_phone: string; customer_email: string; status: string; payment_status: string; total_price: number; currency: string }
export type AnalyticsCost = { order_id: string; cost_amount: number }
export type AnalyticsReturn = { order_id: string; amount: number }

export function calculateAnalytics(orders: AnalyticsOrder[], costs: AnalyticsCost[], returns: AnalyticsReturn[]) {
  const eligible = orders.filter(order => !order.status.startsWith('CANCELLED') && (['PAID', 'MOCK_PAID'].includes(order.payment_status) || order.status === 'DELIVERED'))
  const customers = new Map<string, number>()
  for (const order of eligible) {
    const phone = order.customer_phone.replace(/\D/g, '')
    const key = phone ? `phone:${phone.length >= 9 ? phone.slice(-9) : phone}` : order.customer_email.trim().toLowerCase() || order.user_id
    if (key) customers.set(key, (customers.get(key) ?? 0) + 1)
  }
  const costByOrder = new Map(costs.map(cost => [cost.order_id, cost.cost_amount]))
  const returnedByOrder = new Map<string, number>()
  for (const item of returns) returnedByOrder.set(item.order_id, (returnedByOrder.get(item.order_id) ?? 0) + item.amount)
  return {
    customers: customers.size,
    repeat: [...customers.values()].filter(count => count > 1).length,
    currencies: [...new Set(orders.map(order => order.currency))].map(currency => {
      const delivered = orders.filter(order => order.status === 'DELIVERED' && order.currency === currency)
      const known = delivered.filter(order => costByOrder.has(order.id))
      const returned = delivered.reduce((sum, order) => sum + (returnedByOrder.get(order.id) ?? 0), 0)
      return {
        currency, delivered: delivered.length, known: known.length,
        returned, returnedOrders: delivered.filter(order => returnedByOrder.has(order.id)).length,
        netRevenue: delivered.reduce((sum, order) => sum + Number(order.total_price), 0) - returned,
        margin: known.reduce((sum, order) => sum + Number(order.total_price) - costByOrder.get(order.id)! - (returnedByOrder.get(order.id) ?? 0), 0),
      }
    }),
  }
}
