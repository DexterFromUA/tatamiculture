import { supabaseRequest } from './supabase'

export const defaultParcelDescription = 'речі від tatami.culture'

const endpoint = '/functions/v1/nova-poshta-create-ttn'

export type DispatchLocation = { cityRef: string; cityName: string; warehouseRef: string; warehouseName: string }
export type TtnPreview = {
  weightGrams: number | null
  declaredValueMinor: number
  dispatchLocation: DispatchLocation
  recipientLocation: DispatchLocation
}
export type TtnShipment = { ttn: string; documentRef: string; existing?: boolean }
export type TtnAttempt = { id: string; state: 'creating' | 'review' }
export type OrderDeliveryActions = { cancelStockPending: boolean; ttn: string | null; ttnAttempt: TtnAttempt | null }

export function getOrderDeliveryActions(orderId: string, token: string, signal: AbortSignal) {
  return supabaseRequest<OrderDeliveryActions>('/rest/v1/rpc/get_order_delivery_actions', {
    method: 'POST', token, signal, body: JSON.stringify({ p_order_id: orderId }),
  })
}

export function resolveTtnAttempt(orderId: string, token: string, recovery: {
  action: 'attach' | 'not_created'; attemptId?: string; ttn?: string
}) {
  return supabaseRequest<{ ttn: string | null; documentRef: string | null }>(endpoint, {
    method: 'POST', token, signal: AbortSignal.timeout(20000), body: JSON.stringify({ orderId, recovery }),
  })
}

export async function getTtnPreview(orderId: string, token: string, signal?: AbortSignal) {
  const timeout = AbortSignal.timeout(15000)
  try {
    return await supabaseRequest<TtnPreview>(`${endpoint}?orderId=${encodeURIComponent(orderId)}`, {
      token, cache: 'no-store', signal: signal ? AbortSignal.any([signal, timeout]) : timeout,
    })
  } catch (error) {
    if (timeout.aborted && !signal?.aborted) throw new Error('Checking the shipment details timed out. Try again.', { cause: error })
    throw error
  }
}

export async function createTtn(token: string, details: {
  orderId: string
  description: string
  internalOrderNumber: string
  weightGrams: number
  declaredValueMinor: number
  recipientName?: string
  dispatchLocation?: Pick<DispatchLocation, 'cityRef' | 'warehouseRef'>
  recipientLocation?: DispatchLocation
}) {
  const signal = AbortSignal.timeout(45000)
  try {
    return await supabaseRequest<TtnShipment>(endpoint, {
      method: 'POST', token, body: JSON.stringify(details), signal,
    })
  } catch (error) {
    if (signal.aborted) throw new Error('TTN creation timed out. Check the order and Nova Poshta before retrying.', { cause: error })
    throw error
  }
}
