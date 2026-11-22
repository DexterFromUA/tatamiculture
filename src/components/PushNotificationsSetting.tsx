import { useTranslation } from 'react-i18next'
import { supportsCustomerPush, useCustomerPush } from '../hooks/useCustomerPush'
import { isStandalone } from '../lib/pwa'

export function PushNotificationsSetting({ token }: { token: string }) {
  const { t } = useTranslation()
  const visible = import.meta.env.PROD && isStandalone()
  const supported = supportsCustomerPush()
  const { ready, busy, enabled, message, toggle } = useCustomerPush(token, visible && supported)

  if (!visible) return null

  return <div className="account-push">
    <h3>{t('Push notifications')}</h3>
    <p className="muted">{t(supported ? 'Get updates about your orders, personal discounts and items back in stock.' : 'Push notifications are unavailable on this device.')}</p>
    {supported && <button type="button" className="btn btn--ghost" disabled={!ready || busy} onClick={() => void toggle()}>
      {t(busy ? 'Saving…' : enabled ? 'Turn off push notifications' : 'Turn on push notifications')}
    </button>}
    {message && <p role="status" className="muted">{t(message)}</p>}
  </div>
}
