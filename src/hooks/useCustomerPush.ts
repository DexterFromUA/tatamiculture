import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { disableCustomerPush, updatePushSubscription } from '../lib/customerPush'
import { supabaseRequest } from '../lib/supabase'

export function supportsCustomerPush() {
  return 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window
}

function applicationServerKey(key: string) {
  const padded = key.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(key.length / 4) * 4, '=')
  return Uint8Array.from(atob(padded), char => char.charCodeAt(0))
}

export function useCustomerPush(token: string | null, active: boolean) {
  const { i18n } = useTranslation()
  const [config, setConfig] = useState<{
    registration: ServiceWorkerRegistration
    publicKey: Uint8Array<ArrayBuffer>
    subscription: PushSubscription | null
  } | null>(null)
  const [enabled, setEnabled] = useState(false)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const language = i18n.resolvedLanguage === 'en' ? 'en' : 'uk'

  useEffect(() => {
    if (!active || !token) return
    const abort = new AbortController()
    const load = async (currentToken: string) => {
      const { publicKey } = await supabaseRequest<{ publicKey: string | null }>('/functions/v1/customer-push', {
        signal: abort.signal,
      })
      if (!publicKey) throw new Error('Push notifications are temporarily unavailable.')
      const registration = await navigator.serviceWorker.getRegistration()
      if (!registration) throw new Error('Push notifications are temporarily unavailable.')
      const activeRegistration = registration.active ? registration : await navigator.serviceWorker.ready
      const subscription = await activeRegistration.pushManager.getSubscription()
      const subscribed = subscription && await supabaseRequest<boolean>('/rest/v1/rpc/has_customer_push_subscription', {
        token: currentToken, method: 'POST', body: JSON.stringify({ p_endpoint: subscription.endpoint }), signal: abort.signal,
      })
      if (subscription && subscribed && !abort.signal.aborted) await updatePushSubscription(currentToken, subscription, language)
      if (abort.signal.aborted) return
      setConfig({ registration: activeRegistration, publicKey: applicationServerKey(publicKey), subscription })
      setEnabled(Boolean(subscribed))
      setMessage('')
    }
    void load(token).catch(() => { if (!abort.signal.aborted) setMessage('Push notifications are temporarily unavailable.') })
    return () => abort.abort()
  }, [active, token, language])

  const toggle = async () => {
    if (!token || !config || busy) return false
    setBusy(true)
    setMessage('')
    let createdSubscription: PushSubscription | undefined
    try {
      if (enabled) {
        await disableCustomerPush(token)
        setConfig({ ...config, subscription: await config.registration.pushManager.getSubscription() })
        setEnabled(false)
        return true
      }
      if (Notification.permission === 'denied') {
        setMessage('Allow notifications for Tatami in your device settings.')
        return false
      }
      let subscription = config.subscription
      if (!subscription) {
        // Call subscribe directly from the click so iOS can show the permission prompt.
        subscription = await config.registration.pushManager.subscribe({
          userVisibleOnly: true, applicationServerKey: config.publicKey,
        })
        createdSubscription = subscription
      }
      await updatePushSubscription(token, subscription, language)
      setConfig({ ...config, subscription })
      setEnabled(true)
      return true
    } catch {
      await createdSubscription?.unsubscribe().catch(() => {})
      setMessage(Notification.permission === 'denied'
        ? 'Allow notifications for Tatami in your device settings.'
        : 'Could not update push notifications. Try again.')
      return false
    } finally {
      setBusy(false)
    }
  }

  return { ready: Boolean(config), busy, enabled, message, toggle }
}
