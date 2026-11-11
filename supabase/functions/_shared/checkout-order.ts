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

export function paymentReturnUrl(siteUrl: string | undefined, code: string) {
  return siteUrl && !/^https?:\/\/(localhost|127\.0\.0\.1)(?::\d+)?$/i.test(siteUrl)
    ? `${siteUrl}/cart?payment=${encodeURIComponent(code)}`
    : undefined
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

export async function prepareOnlineCheckout(
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

  const { data: attempt, error } = await serviceClient.rpc('prepare_online_checkout', {
    p_provider: provider,
    p_user_id: userId,
    p_store_id: body.storeId,
    p_items: body.items.map((item) => ({ variantId: item.optionId, quantity: item.quantity })),
    p_checkout: body.checkout,
    p_test_mode: testMode,
  }).single<OnlineCheckout>()
  if (error || !attempt) throw new CheckoutOrderError(error?.message ?? 'Checkout could not be started', error?.code === 'PT409' ? 409 : 400)
  return attempt
}

type OnlineCheckout = {
  id: string
  receipt_code: string
  total_price: number
  currency: string
  items: Array<{ product_name: string; variant_name: string; quantity: number; unit_price: number }>
}

export async function findOnlineCheckout(client: SupabaseClient, provider: OnlineProvider, reference: string) {
  const { data, error } = await client.from('online_checkouts').select('id,test_mode')
    .eq('provider', provider).eq('provider_order_id', reference).maybeSingle<{ id: string; test_mode: boolean }>()
  if (error) throw new Error(error.message)
  return data
}

export async function settleOnlineCheckout(
  client: SupabaseClient, provider: OnlineProvider, reference: string, paid: boolean,
  amount: number, currency: string, paymentId: string | null, callback: unknown,
) {
  if (!paid) {
    const { error } = await client.from('online_checkouts').update({ status: 'FAILED' })
      .eq('provider', provider).eq('provider_order_id', reference).eq('status', 'PENDING')
    if (error) throw new Error(error.message)
    return
  }
  if (!Number.isSafeInteger(amount) || amount <= 0 || !currency) throw new Error('Invalid payment amount or currency')
  const { error } = await client.rpc('confirm_online_checkout', {
    p_provider: provider, p_reference: reference, p_amount: amount, p_currency: currency,
    p_payment_id: paymentId, p_callback: callback,
  })
  if (error) throw new Error(error.message)
}
