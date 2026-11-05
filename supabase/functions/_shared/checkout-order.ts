import { createClient } from 'npm:@supabase/supabase-js@2'

type CheckoutBody = {
  storeId: string
  items: Array<{ optionId: string; quantity: number }>
  checkout: { name: string; email: string; phone: string; city: string; address: string; note: string; cityRef?: string; addressRef?: string; deliveryServiceType?: string }
}

export class CheckoutOrderError extends Error {
  constructor(message: string, readonly status: number) {
    super(message)
  }
}

export async function createOnlineOrder(
  serviceClient: ReturnType<typeof createClient>,
  request: Request,
  anonKey: string,
  provider: 'LIQPAY' | 'MONOBANK',
  body: CheckoutBody,
) {
  const token = request.headers.get('Authorization')?.match(/^Bearer (.+)$/i)?.[1]
  let userId: string | null = null
  if (token && token !== anonKey && token !== request.headers.get('apikey')) {
    const { data, error } = await serviceClient.auth.getUser(token)
    if (error || !data.user) throw new CheckoutOrderError('Your session has expired. Please sign in again.', 401)
    userId = data.user.id
  }

  const { data: order, error } = await serviceClient.rpc('create_order_with_payment', {
    p_provider: provider,
    p_user_id: userId,
    p_store_id: body.storeId,
    p_items: body.items.map((item) => ({ variantId: item.optionId, quantity: item.quantity })),
    p_customer_name: body.checkout.name,
    p_customer_email: body.checkout.email,
    p_customer_phone: body.checkout.phone,
    p_delivery_city: body.checkout.city,
    p_delivery_address: body.checkout.address,
    p_note: body.checkout.note,
    p_delivery_city_ref: body.checkout.cityRef ?? null,
    p_delivery_address_ref: body.checkout.addressRef ?? null,
    p_delivery_service_type: body.checkout.deliveryServiceType ?? null,
  })
  if (error || !order) throw new CheckoutOrderError(error?.message ?? 'Order could not be created', error?.code === 'PT409' ? 409 : 400)
  return order
}
