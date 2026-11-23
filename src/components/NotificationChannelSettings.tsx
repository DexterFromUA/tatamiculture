import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import type { NotificationChannel, NotificationTopic } from '../types'
import { ToggleSwitch } from './ToggleSwitch'

const topics = [
  { key: 'restock', label: 'Back-in-stock notifications', push: 'restockPush', sms: 'restockSms' },
  { key: 'order', label: 'Order status notifications', push: 'orderPush', sms: 'orderSms' },
] as const
const channels = ['push', 'sms'] as const

export function NotificationChannelSettings() {
  const { t } = useTranslation()
  const { token } = useAuth()
  const { store, setNotificationChannel } = useStore()
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState(false)

  const save = async (topic: NotificationTopic, channel: NotificationChannel, enabled: boolean) => {
    if (!token || saving) return
    setSaving(true)
    setError(false)
    try { await setNotificationChannel(topic, channel, enabled, token) }
    catch { setError(true) }
    finally { setSaving(false) }
  }

  return <section className="settings-card customer-notification-settings" aria-busy={saving}>
    {topics.map(topic => <fieldset key={topic.key} disabled={!store || !token || saving}>
      <legend>{t(topic.label)}</legend>
      {channels.map(channel => <label className="notification-channel-toggle" key={channel}>
        <span>{channel === 'push' ? 'Push' : 'SMS'}</span>
        <ToggleSwitch checked={store?.notifications[topic[channel]] ?? false}
          onChange={event => void save(topic.key, channel, event.target.checked)} />
      </label>)}
    </fieldset>)}
    {error && <p className="error" role="alert">{t('Could not save notification channels.')}</p>}
  </section>
}
