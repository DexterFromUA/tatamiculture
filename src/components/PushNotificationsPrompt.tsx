import { useId, useState } from 'react'
import { useNavigate } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { supportsCustomerPush, useCustomerPush } from '../hooks/useCustomerPush'
import { isStandalone } from '../lib/pwa'
import { CenteredDialog } from './CenteredDialog'

const promptKey = 'tatami-push-prompt-seen'
let answeredThisLaunch = false

function alreadyAnswered() {
  try {
    return answeredThisLaunch || localStorage.getItem(promptKey) === '1'
  } catch {
    return answeredThisLaunch
  }
}

function rememberAnswer() {
  answeredThisLaunch = true
  try { localStorage.setItem(promptKey, '1') } catch { /* Storage may be unavailable. */ }
}

export function PushNotificationsPrompt({ token }: { token: string | null }) {
  const { t } = useTranslation()
  const navigate = useNavigate()
  const titleId = useId()
  const messageId = useId()
  const [open, setOpen] = useState(() => import.meta.env.PROD && isStandalone()
    && supportsCustomerPush() && Notification.permission === 'default' && !alreadyAnswered())
  const push = useCustomerPush(token, open)

  const dismiss = () => {
    rememberAnswer()
    setOpen(false)
  }

  const accept = async () => {
    if (!token) {
      dismiss()
      void navigate('/login', { state: { from: '/account' } })
      return
    }
    rememberAnswer()
    const enabled = await push.toggle()
    if (enabled || Notification.permission === 'denied') setOpen(false)
  }

  if (!open || (token && (!push.ready || push.enabled))) return null

  return <CenteredDialog aria-labelledby={titleId} aria-describedby={messageId} busy={push.busy} onClose={dismiss}>
    <h2 id={titleId}>{t('Stay up to date with your orders')}</h2>
    <p id={messageId}>{t(token
      ? 'Turn on notifications for order updates, tracking numbers and personal discounts.'
      : 'Sign in to turn on notifications about your orders and personal discounts.')}</p>
    {push.message && <p className="muted" role="status">{t(push.message)}</p>}
    <div className="confirmation-dialog__actions">
      <form method="dialog">
        <button type="submit" className="btn btn--ghost" disabled={push.busy} autoFocus>{t('Not now')}</button>
      </form>
      <button type="button" className="btn" disabled={push.busy} onClick={() => void accept()}>
        {t(push.busy ? 'Saving…' : token ? 'Turn on push notifications' : 'Sign in')}
      </button>
    </div>
  </CenteredDialog>
}
