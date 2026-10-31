export type AdminSection = 'overview' | 'orders' | 'customers' | 'catalogue' | 'settings'
export function AdminTabs({ active, onChange }: { active: AdminSection; onChange: (section: AdminSection) => void }) {
  return <nav className="admin-tabs" aria-label="Management sections">{(['overview', 'orders', 'customers', 'catalogue', 'settings'] as const).map((section) => <button type="button" key={section} className={active === section ? 'active' : ''} onClick={() => onChange(section)}>{section === 'overview' ? 'Overview' : section === 'orders' ? 'Orders' : section === 'customers' ? 'Customers' : section === 'catalogue' ? 'Catalogue' : 'Settings'}</button>)}</nav>
}
