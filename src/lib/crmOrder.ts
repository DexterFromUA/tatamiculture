import { supabaseRequest } from './supabase'

export type CrmOrderInput = {
  requestId: string
  customer: { name: string; phone: string }
  delivery: { city: string; address: string; cityRef?: string; addressRef?: string; serviceType?: string }
  note: string
  items: { variantId: string; quantity: number }[]
  total: number
}

export function createCrmOrder(storeId: string, token: string, order: CrmOrderInput) {
  return supabaseRequest<{ id: string }>('/rest/v1/rpc/create_crm_order', {
    method: 'POST', token, signal: AbortSignal.timeout(20000),
    body: JSON.stringify({
      p_store_id: storeId,
      p_request_id: order.requestId,
      p_customer: order.customer,
      p_delivery: order.delivery,
      p_note: order.note,
      p_items: order.items.map(({ variantId, quantity }) => ({ variantId, quantity })),
      p_expected_total: order.total,
    }),
  })
}
