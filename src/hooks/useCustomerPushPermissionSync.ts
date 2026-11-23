import { useEffect } from 'react'
import { rememberPushEndpoint, rememberedPushEndpoint, removePushEndpoint } from '../lib/customerPush'
import { supportsCustomerPush } from './useCustomerPush'

export function useCustomerPushPermissionSync(standalone: boolean, token: string | null, userId?: string) {
  useEffect(() => {
    if (!import.meta.env.PROD || !standalone || !token || !userId || !supportsCustomerPush()) return
    const abort = new AbortController()
    let checking = false
    let removedEndpoint: string | undefined

    const sync = async () => {
      if (checking || document.visibilityState !== 'visible' || abort.signal.aborted) return
      checking = true
      try {
        const remembered = rememberedPushEndpoint(userId)
        let endpoint = remembered
        if (!remembered || Notification.permission !== 'denied') {
          const registration = await navigator.serviceWorker.getRegistration()
          if (!registration?.active) return
          const subscription = await registration.pushManager.getSubscription()
          if (abort.signal.aborted) return
          if (subscription && Notification.permission !== 'denied') {
            if (remembered !== subscription.endpoint) rememberPushEndpoint(userId, subscription.endpoint)
            removedEndpoint = undefined
            return
          }
          endpoint = subscription?.endpoint ?? remembered
        }
        if (!endpoint || (!remembered && endpoint === removedEndpoint) || !navigator.onLine) return
        // Revoke only this installation's subscription. Other devices stay subscribed.
        await removePushEndpoint(token, userId, endpoint, AbortSignal.any([abort.signal, AbortSignal.timeout(10000)]))
        removedEndpoint = endpoint
      } catch {
        // A later foreground or online event can retry without interrupting the customer.
      } finally {
        checking = false
      }
    }

    void sync()
    document.addEventListener('visibilitychange', sync)
    window.addEventListener('online', sync)
    return () => {
      abort.abort()
      document.removeEventListener('visibilitychange', sync)
      window.removeEventListener('online', sync)
    }
  }, [standalone, token, userId])
}
