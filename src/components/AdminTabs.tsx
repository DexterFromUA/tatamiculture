export type AdminSection = 'overview' | 'orders' | 'customers' | 'catalogue' | 'settings'
import { useTranslation } from 'react-i18next'
export function AdminTabs({ active, onChange }: { active: AdminSection; onChange: (section: AdminSection) => void }) {
  const { t } = useTranslation()
  return <nav className="admin-tabs" aria-label={t('Management sections')}>{(['overview', 'orders', 'customers', 'catalogue', 'settings'] as const).map((section) => <button type="button" key={section} className={active === section ? 'active' : ''} onClick={() => onChange(section)}>{section === 'overview' ? t('Overview') : section === 'orders' ? t('Orders') : section === 'customers' ? t('Customers') : section === 'catalogue' ? t('Catalogue') : t('Settings')}</button>)}</nav>
}
