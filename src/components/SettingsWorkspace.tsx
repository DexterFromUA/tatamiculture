import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { BannerSettings } from './BannerSettings'
import { PaymentSettings } from './PaymentSettings'
import { NovaPostModeToggle } from './NovaPostModeToggle'
import { DeliverySettingsPage } from '../pages/DeliverySettingsPage'

export function SettingsWorkspace() {
  const { t } = useTranslation()
  const [section, setSection] = useState<'storefront' | 'delivery' | 'payments'>('storefront')
  return <div className="settings-workspace">
    <nav className="settings-nav" aria-label={t('Settings sections')}>
      <button type="button" className={section === 'storefront' ? 'active' : ''} aria-current={section === 'storefront' ? 'page' : undefined} onClick={() => setSection('storefront')}><span className="settings-nav__index">01</span><span><strong>{t('Storefront')}</strong><small>{t('Homepage banner')}</small></span><span className="settings-nav__arrow" aria-hidden="true">↗</span></button>
      <button type="button" className={section === 'delivery' ? 'active' : ''} aria-current={section === 'delivery' ? 'page' : undefined} onClick={() => setSection('delivery')}><span className="settings-nav__index">02</span><span><strong>{t('Delivery')}</strong><small>{t('Nova Poshta settings')}</small></span><span className="settings-nav__arrow" aria-hidden="true">↗</span></button>
      <button type="button" className={section === 'payments' ? 'active' : ''} aria-current={section === 'payments' ? 'page' : undefined} onClick={() => setSection('payments')}><span className="settings-nav__index">03</span><span><strong>{t('Payments')}</strong><small>{t('Payment methods')}</small></span><span className="settings-nav__arrow" aria-hidden="true">↗</span></button>
    </nav>
    <div className="settings-workspace__content">
      <div hidden={section !== 'storefront'}><BannerSettings /></div>
      <div hidden={section !== 'delivery'}><div className="settings-workspace__heading"><p className="eyebrow">02 / {t('Settings')}</p><h2>{t('Nova Poshta settings')}</h2></div><NovaPostModeToggle /><DeliverySettingsPage embedded /></div>
      {section === 'payments' && <PaymentSettings />}
    </div>
  </div>
}
