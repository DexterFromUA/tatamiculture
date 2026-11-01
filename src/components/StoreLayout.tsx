import { useEffect } from 'react'
import { NavLink, Outlet } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'
import { useCart } from '../context/CartContext'
import { useStore } from '../context/StoreContext'
import { useTranslation } from 'react-i18next'

export function StoreLayout() {
  const { store, loading, notFound } = useStore()
  const { count } = useCart()
  const { isAuthenticated, user } = useAuth()
  const { t, i18n } = useTranslation()

  useEffect(() => {
    if (!store) return
    document.title = store.name
    return () => {
      document.title = 'Store'
    }
  }, [store])

  if (loading) {
    return <div className="page-status">{t('Opening store…')}</div>
  }

  if (notFound || !store) {
    return (
      <div className="page-status">
        <h1>{t('Store not found')}</h1>
        <p>{t('The storefront is unavailable right now.')}</p>
        <NavLink to="/">{t('Go to Tatami')}</NavLink>
      </div>
    )
  }

  return (
    <div className="shell">
      <header className="topbar">
        <NavLink to="/" className="brand">
          {store.name}
        </NavLink>
        <nav className="nav">
          <NavLink to="/" end>
            {t('Shop')}
          </NavLink>
          <NavLink to="/cart">{t('Cart')}{count > 0 ? ` (${count})` : ''}</NavLink>
          {isAuthenticated ? (
            <>
              <NavLink to="/admin">CRM</NavLink>
              <NavLink to="/account">{user?.name.split(' ')[0] ?? t('Account')}</NavLink>
            </>
          ) : (
            <NavLink to="/login">{t('Sign in')}</NavLink>
          )}
          <button type="button" className="text-btn" onClick={() => void i18n.changeLanguage(i18n.language === 'uk' ? 'en' : 'uk')}>
            {i18n.language === 'uk' ? t('English') : t('Ukrainian')}
          </button>
        </nav>
      </header>
      <main className="main">
        <Outlet />
      </main>
      <footer className="footer">
        <span>
          {store.name} · {store.contactCity}
        </span>
        <span>{t('Mock payments only')}</span>
      </footer>
    </div>
  )
}
