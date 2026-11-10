import type { CrmCustomer, CrmOrder } from '../components/CrmCustomerCard'
import type { OrderDetailsOrder } from '../components/OrderOperations'
import { downloadCsv, fetchAll } from './crm'
import { formatPrice } from './format'

type Translate = (key: string) => string

type ExportOrder = Pick<OrderDetailsOrder,
  'id' | 'receipt_code' | 'customer_name' | 'customer_phone' | 'customer_email' | 'note' |
  'status' | 'payment_status' | 'payment_method' | 'payment_test_mode' | 'created_at' |
  'total_price' | 'currency' | 'nova_poshta_ttn' | 'nova_poshta_status'> & {
  crm_customer_id: string | null
  monobank_test_mode: boolean | null
  updated_at: string
  delivery_city: string
  delivery_address: string
  delivery_service_type: string | null
  nova_poshta_ttn_created_at: string | null
  nova_poshta_status_updated_at: string | null
  order_items: Array<{
    product_name: string; variant_name: string; quantity: number; unit_price: number; line_total: number; is_preorder: boolean
  }>
  order_returns: Array<{ amount: number }>
  order_financials: { cost_amount: number } | null
  payments: { provider: string; status: string } | null
}

export type CustomerExportOrder = CrmOrder & Pick<ExportOrder, 'payment_status' | 'payment_test_mode' | 'monobank_test_mode'>
type ExportOrderRef = { id: string; primaryReceipt?: string }

const orderFields = [
  'id', 'receipt_code', 'crm_customer_id', 'customer_name', 'customer_phone', 'customer_email', 'note',
  'status', 'payment_status', 'payment_method', 'payment_test_mode', 'monobank_test_mode', 'created_at', 'updated_at',
  'total_price', 'currency', 'delivery_city', 'delivery_address', 'delivery_service_type',
  'nova_poshta_ttn', 'nova_poshta_status', 'nova_poshta_ttn_created_at', 'nova_poshta_status_updated_at',
  'payments(provider,status)', 'order_items(product_name,variant_name,quantity,unit_price,line_total,is_preorder)',
  'order_returns(amount)', 'order_financials(cost_amount)',
].join(',')

const isTestOrder = (order: Pick<ExportOrder, 'payment_test_mode' | 'monobank_test_mode'>) =>
  order.payment_test_mode ?? order.monobank_test_mode ?? false

const isCancelled = (order: { status: string }) => order.status.startsWith('CANCELLED')

export async function downloadOrdersCsv(refs: ExportOrderRef[], token: string, t: Translate) {
  const orders = new Map<string, ExportOrder>()
  // Keep the filter short enough for the API when the export spans many pages.
  for (let index = 0; index < refs.length; index += 50) {
    const ids = refs.slice(index, index + 50).map(ref => encodeURIComponent(ref.id)).join(',')
    const batch = await fetchAll<ExportOrder>(`/rest/v1/orders?id=in.(${ids})&select=${orderFields}&order=id`, token)
    for (const order of batch) orders.set(order.id, order)
  }

  const headers = [
    'Order number', 'Primary order number', 'Order date', 'Updated at', 'Order status', 'Payment status', 'Payment method',
    'Payment provider', 'Provider payment status', 'Payment mode', 'Customer ID', 'Name', 'Phone', 'Email', 'Note',
    'City', 'Address', 'Delivery type', 'TTN', 'TTN created at', 'Shipment status', 'Shipment status updated at',
    'Order items', 'Units ordered', 'Preordered units', 'Currency', 'Total', 'Recorded refunds', 'Total after recorded refunds',
    'Order cost', 'Order ID',
  ].map(label => t(label))
  const rows = refs.map(({ id, primaryReceipt }) => {
    const order = orders.get(id)
    if (!order) throw new Error(t('An order could not be loaded. Refresh the list and try again.'))

    const items = order.order_items.map(item => {
      const name = [item.product_name, item.variant_name].filter(Boolean).join(' / ')
      return `${name} · ${item.quantity} × ${formatPrice(Number(item.unit_price) / 100, order.currency)} = ${formatPrice(Number(item.line_total) / 100, order.currency)}`
    }).join('\n')
    const units = order.order_items.reduce((count, item) => count + Number(item.quantity), 0)
    const preorderUnits = order.order_items.reduce((count, item) => count + (item.is_preorder ? Number(item.quantity) : 0), 0)
    const refunds = order.order_returns.reduce((amount, entry) => amount + Number(entry.amount), 0)
    const method = order.payment_method === 'CASH_ON_DELIVERY' ? 'Payment on delivery' : 'Online payment'
    const deliveryType = order.delivery_service_type === 'WarehousePostomat' ? 'Parcel locker'
      : order.delivery_service_type === 'WarehouseWarehouse' ? 'Branch' : ''

    return [
      order.receipt_code, primaryReceipt, order.created_at, order.updated_at, t(order.status), t(`payment_${order.payment_status}`), t(method),
      order.payments?.provider, order.payments ? t(`payment_${order.payments.status}`) : '',
      t(isTestOrder(order) ? 'Test mode' : 'Live mode'), order.crm_customer_id, order.customer_name, order.customer_phone, order.customer_email, order.note,
      order.delivery_city, order.delivery_address, deliveryType && t(deliveryType), order.nova_poshta_ttn, order.nova_poshta_ttn_created_at,
      order.nova_poshta_status, order.nova_poshta_status_updated_at, items, units, preorderUnits,
      order.currency, Number(order.total_price) / 100, refunds / 100, (Number(order.total_price) - refunds) / 100,
      order.order_financials ? Number(order.order_financials.cost_amount) / 100 : null, order.id,
    ]
  })
  downloadCsv('tatami.culture-orders.csv', [headers, ...rows])
}

export function downloadCustomersCsv(customers: CrmCustomer[], orders: CustomerExportOrder[], storeCurrency: string, t: Translate) {
  const customerIds = new Set(customers.map(customer => customer.id))
  const ordersByCustomer = new Map<string, CustomerExportOrder[]>()
  const currencies = new Set([storeCurrency])
  for (const order of orders) {
    if (!order.crm_customer_id || !customerIds.has(order.crm_customer_id) || isTestOrder(order)) continue
    const entries = ordersByCustomer.get(order.crm_customer_id) ?? []
    entries.push(order)
    ordersByCustomer.set(order.crm_customer_id, entries)
    if (!isCancelled(order)) currencies.add(order.currency)
  }
  const currencyList = [...currencies].sort()
  const headers = [
    'Customer ID', 'Name', 'Phone', 'Email', 'Tags', 'Private notes', 'Customer created at',
    'Live orders', 'Non-cancelled orders', 'Paid orders', 'Delivered orders', 'Cancelled orders',
    'First order date', 'Latest order date', 'Latest order number', 'Latest order status', 'Latest payment status',
  ].map(label => t(label))
  for (const currency of currencyList) {
    headers.push(...['Non-cancelled order total', 'Paid order total', 'Average order value'].map(label => `${t(label)} (${currency})`))
  }

  const rows = customers.map(customer => {
    const history = ordersByCustomer.get(customer.id) ?? []
    const active = history.filter(order => !isCancelled(order))
    const paid = active.filter(order => order.payment_status === 'PAID')
    const delivered = active.filter(order => order.status === 'DELIVERED')
    // The customer page loads the order history newest first.
    const latest = history[0]
    const first = history.at(-1)
    const totals = currencyList.flatMap(currency => {
      const sameCurrency = active.filter(order => order.currency === currency)
      const total = sameCurrency.reduce((sum, order) => sum + Number(order.total_price), 0)
      const paidTotal = paid.reduce((sum, order) => order.currency === currency ? sum + Number(order.total_price) : sum, 0)
      return [total / 100, paidTotal / 100, sameCurrency.length ? Math.round(total / sameCurrency.length) / 100 : null]
    })
    return [
      customer.id, customer.name, customer.phone, customer.email, customer.tags.join(', '), customer.notes, customer.created_at,
      history.length, active.length, paid.length, delivered.length, history.length - active.length,
      first?.created_at, latest?.created_at, latest?.receipt_code, latest ? t(latest.status) : '',
      latest ? t(`payment_${latest.payment_status}`) : '', ...totals,
    ]
  })
  downloadCsv('tatami.culture-customers.csv', [headers, ...rows])
}
