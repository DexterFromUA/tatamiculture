import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { BannerSettings } from './BannerSettings'
import { ThemeSettings } from './ThemeSettings'
import { LayoutSettings } from './LayoutSettings'
import { LanguageSettings } from './LanguageSettings'
import { StorefrontSettingsSave } from './StorefrontSettingsSave'
import { ContactSettings } from './ContactSettings'
import { CatalogImportSettings } from './CatalogImportSettings'
import { PaymentSettings } from './PaymentSettings'
import { SettingsSectionHeading } from './SettingsSectionHeading'
import { SmsProviderSettings } from './SmsProviderSettings'
import { StaffPushSettings } from './StaffPushSettings'
import { NotificationChannelSettings } from './NotificationChannelSettings'
import { CrmAuditLog } from './CrmAuditLog'
import { DeliverySettingsPage } from '../pages/DeliverySettingsPage'

const sectionHeadings = {
  storefront: { number: '01', title: 'General' },
  delivery: { number: '02', title: 'Nova Poshta settings' },
  payments: { number: '03', title: 'Payments' },
  sms: { number: '04', title: 'Notifications and SMS' },
  languages: { number: '05', title: 'Languages' },
  audit: { number: '06', title: 'Activity log' },
} as const

export function SettingsWorkspace({ canManageStaffNotifications }: { canManageStaffNotifications: boolean }) {
  const { t } = useTranslation()
  const [section, setSection] = useState<keyof typeof sectionHeadings>('storefront')
  const heading = sectionHeadings[section]
  return <div className="settings-workspace">
    <nav className="settings-nav" aria-label={t('Settings sections')}>
      <button type="button" className={section === 'storefront' ? 'active' : ''} aria-current={section === 'storefront' ? 'page' : undefined} onClick={() => setSection('storefront')}><span className="settings-nav__index">{sectionHeadings.storefront.number}</span><span><strong>{t('General')}</strong></span><span className="settings-nav__arrow" aria-hidden="true">↗</span></button>
      <button type="button" className={section === 'delivery' ? 'active' : ''} aria-current={section === 'delivery' ? 'page' : undefined} onClick={() => setSection('delivery')}><span className="settings-nav__index">02</span><span><strong>{t('Delivery')}</strong><small>{t('Nova Poshta settings')}</small></span><span className="settings-nav__arrow" aria-hidden="true">↗</span></button>
      <button type="button" className={section === 'payments' ? 'active' : ''} aria-current={section === 'payments' ? 'page' : undefined} onClick={() => setSection('payments')}><span className="settings-nav__index">03</span><span><strong>{t('Payments')}</strong><small>{t('Payment methods')}</small></span><span className="settings-nav__arrow" aria-hidden="true">↗</span></button>
      <button type="button" className={section === 'sms' ? 'active' : ''} aria-current={section === 'sms' ? 'page' : undefined} onClick={() => setSection('sms')}><span className="settings-nav__index">04</span><span><strong>{t('Notifications and SMS')}</strong><small>{t('Sign-in and notifications')}</small></span><span className="settings-nav__arrow" aria-hidden="true">↗</span></button>
      <button type="button" className={section === 'languages' ? 'active' : ''} aria-current={section === 'languages' ? 'page' : undefined} onClick={() => setSection('languages')}><span className="settings-nav__index">{sectionHeadings.languages.number}</span><span><strong>{t('Languages')}</strong></span><span className="settings-nav__arrow" aria-hidden="true">↗</span></button>
      {canManageStaffNotifications && <button type="button" className={section === 'audit' ? 'active' : ''} aria-current={section === 'audit' ? 'page' : undefined} onClick={() => setSection('audit')}><span className="settings-nav__index">{sectionHeadings.audit.number}</span><span><strong>{t('Activity log')}</strong></span><span className="settings-nav__arrow" aria-hidden="true">↗</span></button>}
    </nav>
    <div className="settings-workspace__content">
      {section !== 'payments' && <SettingsSectionHeading {...heading} />}
      <div hidden={section !== 'storefront'}>
        <StorefrontSettingsSave>
          <BannerSettings />
          <ThemeSettings />
          <LayoutSettings />
          <ContactSettings />
          <CatalogImportSettings />
        </StorefrontSettingsSave>
      </div>
      <div hidden={section !== 'languages'}><LanguageSettings /></div>
      <div hidden={section !== 'delivery'}><DeliverySettingsPage embedded /></div>
      {section === 'payments' && <PaymentSettings heading={heading} />}
      {section === 'audit' && canManageStaffNotifications && <CrmAuditLog />}
      {section === 'sms' && <div className="settings-workspace__notifications">
        {canManageStaffNotifications && <><NotificationChannelSettings /><StaffPushSettings /></>}
        <SmsProviderSettings />
      </div>}
    </div>
  </div>
}
