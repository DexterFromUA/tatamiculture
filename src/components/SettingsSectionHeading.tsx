import type { ReactNode } from 'react'
import { useTranslation } from 'react-i18next'

export function SettingsSectionHeading({ number, title, action }: { number: string; title: string; action?: ReactNode }) {
  const { t } = useTranslation()
  return <header className="settings-workspace__heading">
    <div>
      <p className="eyebrow">{number} / {t('Settings')}</p>
      <h2>{t(title)}</h2>
    </div>
    {action}
  </header>
}
