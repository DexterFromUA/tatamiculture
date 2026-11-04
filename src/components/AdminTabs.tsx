export type AdminSection = 'overview' | 'orders' | 'customers' | 'catalogue' | 'settings'
import { useTranslation } from 'react-i18next'
export function AdminTabs({ active, onChange }: { active: AdminSection; onChange: (section: AdminSection) => void }) {
  const { t } = useTranslation()
  return <nav className="admin-tabs" aria-label={t('Management sections')}>{(['overview', 'orders', 'customers', 'catalogue', 'settings'] as const).map((section, index) => <button type="button" key={section} className={active === section ? 'active' : ''} aria-current={active === section ? 'page' : undefined} onClick={() => onChange(section)}><span className="admin-tabs__number" aria-hidden="true">0{index + 1}</span>{section === 'overview' ? t('Overview') : section === 'orders' ? t('Orders') : section === 'customers' ? t('Customers') : section === 'catalogue' ? t('Catalogue') : t('Settings')}</button>)}</nav>
}
