import { useEffect, useState } from 'react'
import { NavLink, Outlet } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'
import { useCart } from '../context/CartContext'
import { useStore } from '../context/StoreContext'
import { useTranslation } from 'react-i18next'
import { hasStoreMembership } from '../lib/crm'
import { supabaseConfigured } from '../lib/supabase'

export function StoreLayout() {
  const { store, loading, notFound } = useStore()
  const { count } = useCart()
  const { isAuthenticated, token, user } = useAuth()
  const { t, i18n } = useTranslation()
  const storeId = store?.id
  const userId = user?.id
  const [crmAccess, setCrmAccess] = useState<{ storeId: string; userId: string; token: string } | null>(null)

  useEffect(() => {
    if (!supabaseConfigured || !storeId || !userId || !token) return

    const abort = new AbortController()
    void hasStoreMembership(storeId, userId, token, abort.signal)
      .then(isMember => {
        if (!abort.signal.aborted) setCrmAccess(isMember ? { storeId, userId, token } : null)
      })
      .catch(() => {
        if (!abort.signal.aborted) setCrmAccess(null)
      })
    return () => abort.abort()
  }, [storeId, userId, token])

  const canOpenCrm = crmAccess !== null
    && crmAccess.storeId === storeId && crmAccess.userId === userId && crmAccess.token === token

  useEffect(() => {
    if (!store) return
    document.title = store.name
    return () => {
      document.title = 'Tatami.Culture'
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
        <NavLink to="/">{t('Go to Tatami.Culture')}</NavLink>
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
              {canOpenCrm && <NavLink to="/admin">CRM</NavLink>}
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
          {store.name}
        </span>
        <span>{t('Mock payments only')}</span>
      </footer>
    </div>
  )
}
