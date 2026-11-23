import { supabaseRequest } from './supabase'

export function updatePushSubscription(token: string, subscription: PushSubscription, language: string) {
  const keys = subscription.toJSON().keys
  return supabaseRequest<void>('/rest/v1/rpc/set_customer_push_subscription', {
    token, method: 'POST',
    body: JSON.stringify({
      p_endpoint: subscription.endpoint, p_p256dh: keys?.p256dh, p_auth: keys?.auth, p_language: language,
    }),
  })
}

export function rememberedPushEndpoint(userId: string) {
  try { return localStorage.getItem(`tatami-push-endpoint.${userId}`) } catch { return null }
}

export function rememberPushEndpoint(userId: string, endpoint: string) {
  try { localStorage.setItem(`tatami-push-endpoint.${userId}`, endpoint) } catch { /* Storage may be unavailable. */ }
}

export async function removePushEndpoint(token: string, userId: string | undefined, endpoint: string, signal?: AbortSignal) {
  await supabaseRequest<void>('/rest/v1/rpc/set_customer_push_subscription', {
    token, signal, method: 'POST', body: JSON.stringify({ p_endpoint: endpoint }),
  })
  if (userId && rememberedPushEndpoint(userId) === endpoint) {
    try { localStorage.removeItem(`tatami-push-endpoint.${userId}`) } catch { /* Storage may be unavailable. */ }
  }
  return true
}

export async function disableCustomerPush(token?: string | null, userId?: string) {
  const registration = await navigator.serviceWorker?.getRegistration()
  const subscription = await registration?.pushManager?.getSubscription()
  const endpoint = subscription?.endpoint ?? (userId ? rememberedPushEndpoint(userId) : null)
  if (!endpoint) return
  if (userId) rememberPushEndpoint(userId, endpoint)
  const results = await Promise.allSettled([
    subscription?.unsubscribe(),
    token ? removePushEndpoint(token, userId, endpoint, AbortSignal.timeout(10000)) : false,
  ])
  if (!results.some(result => result.status === 'fulfilled' && result.value)) {
    throw new Error('Could not turn off push notifications.')
  }
}
