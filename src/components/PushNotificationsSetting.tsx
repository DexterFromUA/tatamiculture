import { useId } from 'react'
import { useTranslation } from 'react-i18next'
import { supportsCustomerPush, useCustomerPush } from '../hooks/useCustomerPush'
import { isStandalone } from '../lib/pwa'
import { ToggleSwitch } from './ToggleSwitch'

export function PushNotificationsSetting({ token }: { token: string }) {
  const { t } = useTranslation()
  const labelId = useId()
  const descriptionId = useId()
  const visible = import.meta.env.PROD && isStandalone()
  const supported = supportsCustomerPush()
  const { ready, busy, enabled, message, toggle } = useCustomerPush(token, visible && supported)

  if (!visible) return null

  return <div className="account-push">
    <div className="account-push__row">
      <div>
        <h3 id={labelId}>{t('Push notifications')}</h3>
        <p id={descriptionId} className="muted">{t(supported ? 'Get updates about your orders, personal discounts and items back in stock.' : 'Push notifications are unavailable on this device.')}</p>
      </div>
      {supported && <ToggleSwitch aria-labelledby={labelId} aria-describedby={descriptionId}
        checked={enabled} disabled={!ready || busy} onChange={() => void toggle()} />}
    </div>
    {busy && <p role="status" className="muted">{t('Saving…')}</p>}
    {message && <p role="status" className="muted">{t(message)}</p>}
  </div>
}
