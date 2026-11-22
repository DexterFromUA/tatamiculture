import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { disableCustomerPush, updatePushSubscription } from '../lib/customerPush'
import { isStandalone } from '../lib/pwa'
import { supabaseRequest } from '../lib/supabase'

function applicationServerKey(key: string) {
  const padded = key.replace(/-/g, '+').replace(/_/g, '/').padEnd(Math.ceil(key.length / 4) * 4, '=')
  return Uint8Array.from(atob(padded), char => char.charCodeAt(0))
}

export function PushNotificationsSetting({ token }: { token: string }) {
  const { t, i18n } = useTranslation()
  const [config, setConfig] = useState<{
    registration: ServiceWorkerRegistration
    publicKey: Uint8Array<ArrayBuffer>
    subscription: PushSubscription | null
  } | null>(null)
  const [enabled, setEnabled] = useState(false)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const standalone = isStandalone()
  const supported = 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window
  const language = i18n.resolvedLanguage === 'en' ? 'en' : 'uk'

  useEffect(() => {
    if (!standalone || !supported || !import.meta.env.PROD) return
    const abort = new AbortController()
    const load = async () => {
      const { publicKey } = await supabaseRequest<{ publicKey: string | null }>('/functions/v1/customer-push', {
        signal: abort.signal,
      })
      if (!publicKey) throw new Error('Push notifications are temporarily unavailable.')
      const registration = await navigator.serviceWorker.getRegistration()
      if (!registration) throw new Error('Push notifications are temporarily unavailable.')
      const active = registration.active ? registration : await navigator.serviceWorker.ready
      const subscription = await active.pushManager.getSubscription()
      const subscribed = subscription && await supabaseRequest<boolean>('/rest/v1/rpc/has_customer_push_subscription', {
        token, method: 'POST', body: JSON.stringify({ p_endpoint: subscription.endpoint }), signal: abort.signal,
      })
      if (subscription && subscribed) await updatePushSubscription(token, subscription, language)
      if (abort.signal.aborted) return
      setConfig({ registration: active, publicKey: applicationServerKey(publicKey), subscription })
      setEnabled(Boolean(subscribed))
      setMessage('')
    }
    void load().catch(() => { if (!abort.signal.aborted) setMessage('Push notifications are temporarily unavailable.') })
    return () => abort.abort()
  }, [standalone, supported, token, language])

  if (!standalone || !import.meta.env.PROD) return null

  const toggle = async () => {
    if (!config || busy) return
    setBusy(true)
    setMessage('')
    let createdSubscription: PushSubscription | undefined
    try {
      if (enabled) {
        await disableCustomerPush(token)
        setConfig({ ...config, subscription: await config.registration.pushManager.getSubscription() })
        setEnabled(false)
        return
      }
      if (Notification.permission === 'denied') {
        setMessage('Allow notifications for Tatami in your device settings.')
        return
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
    } catch {
      await createdSubscription?.unsubscribe().catch(() => {})
      setMessage(Notification.permission === 'denied'
        ? 'Allow notifications for Tatami in your device settings.'
        : 'Could not update push notifications. Try again.')
    } finally {
      setBusy(false)
    }
  }

  return <div className="account-push">
    <h3>{t('Push notifications')}</h3>
    <p className="muted">{t(supported ? 'Get updates about your orders and items back in stock.' : 'Push notifications are unavailable on this device.')}</p>
    {supported && <button type="button" className="btn btn--ghost" disabled={!config || busy} onClick={() => void toggle()}>
      {t(busy ? 'Saving…' : enabled ? 'Turn off push notifications' : 'Turn on push notifications')}
    </button>}
    {message && <p role="status" className="muted">{t(message)}</p>}
  </div>
}
