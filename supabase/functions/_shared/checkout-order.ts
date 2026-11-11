import type { SupabaseClient } from 'npm:@supabase/supabase-js@2'

type CheckoutBody = {
  storeId: string
  items: Array<{ optionId: string; quantity: number }>
  checkout: { name: string; email: string; phone: string; city: string; address: string; note: string; cityRef?: string; addressRef?: string; deliveryServiceType?: string }
}

type OnlineProvider = 'LIQPAY' | 'MONOBANK'

export class CheckoutOrderError extends Error {
  constructor(message: string, readonly status: number) {
    super(message)
  }
}

export async function getCheckoutTestMode(
  client: SupabaseClient, storeId: string, provider: OnlineProvider, requested: unknown,
) {
  const { data, error } = await client.from('store_payment_methods')
    .select('payment_test_mode,monobank_test_mode').eq('store_id', storeId).maybeSingle()
  if (error) throw new Error(error.message)
  const sharedMode = data?.payment_test_mode
  const testMode = sharedMode ?? (provider === 'MONOBANK'
    ? data?.monobank_test_mode === true
    : Deno.env.get('LIQPAY_TEST_MODE') === 'true')
  if (requested !== testMode && (sharedMode != null || requested != null)) {
    throw new CheckoutOrderError('Payment settings changed. Please try again.', 409)
  }
  return testMode
}

export async function createOnlineOrder(
  serviceClient: SupabaseClient,
  request: Request,
  anonKey: string,
  provider: OnlineProvider,
  body: CheckoutBody,
  testMode: boolean,
) {
  const token = request.headers.get('Authorization')?.match(/^Bearer (.+)$/i)?.[1]
  let userId: string | null = null
  if (token && token !== anonKey && token !== request.headers.get('apikey')) {
    const { data, error } = await serviceClient.auth.getUser(token)
    if (error || !data.user) throw new CheckoutOrderError('Your session has expired. Please sign in again.', 401)
    userId = data.user.id
  }

  const { data: order, error } = await serviceClient.rpc(userId ? 'create_reserved_online_order' : 'create_order_with_payment', {
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
    p_monobank_test_mode: testMode,
  })
  if (error || !order) throw new CheckoutOrderError(error?.message ?? 'Order could not be created', error?.code === 'PT409' ? 409 : 400)
  return { order, userId }
}
