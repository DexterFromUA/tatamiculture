import { supabaseRequest } from './supabase'

export function updatePushSubscription(token: string, subscription: PushSubscription, language?: string) {
  const keys = subscription.toJSON().keys
  return supabaseRequest<void>('/rest/v1/rpc/set_customer_push_subscription', {
    token, method: 'POST',
    body: JSON.stringify({
      p_endpoint: subscription.endpoint,
      ...(language ? { p_p256dh: keys?.p256dh, p_auth: keys?.auth, p_language: language } : {}),
    }),
  })
}

export async function disableCustomerPush(token?: string | null) {
  const registration = await navigator.serviceWorker?.getRegistration()
  const subscription = await registration?.pushManager?.getSubscription()
  if (!subscription) return
  const results = await Promise.allSettled([
    subscription.unsubscribe(),
    token ? updatePushSubscription(token, subscription).then(() => true) : Promise.resolve(false),
  ])
  if (!results.some(result => result.status === 'fulfilled' && result.value)) {
    throw new Error('Could not turn off push notifications.')
  }
}
