import { useEffect, useState } from 'react'
import { NavLink, Outlet } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'
import { useCart } from '../context/CartContext'
import { useStore } from '../context/StoreContext'
import { useTranslation } from 'react-i18next'
import { hasStoreMembership } from '../lib/crm'
import { supabaseConfigured } from '../lib/supabase'
import { contactsChanged, getStorefrontContacts, type StorefrontContacts } from '../lib/storefrontContacts'

export function StoreLayout() {
  const { store, loading, notFound, loadFailed } = useStore()
  const { count } = useCart()
  const { isAuthenticated, token, user } = useAuth()
  const { t, i18n } = useTranslation()
  const storeId = store?.id
  const userId = user?.id
  const [crmAccess, setCrmAccess] = useState<{ storeId: string; userId: string; token: string } | null>(null)
  const [contacts, setContacts] = useState<StorefrontContacts | null>(null)

  useEffect(() => {
    if (!storeId) return
    let active = true
    const load = () => { void getStorefrontContacts(storeId).then(value => { if (active) setContacts(value) }).catch(() => { if (active) setContacts(null) }) }
    load()
    window.addEventListener(contactsChanged, load)
    return () => { active = false; window.removeEventListener(contactsChanged, load) }
  }, [storeId])

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

  if (loadFailed) {
    return <main className="page-status"><h1>{t('Store temporarily unavailable')}</h1></main>
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
        <span className="footer__copyright">© {new Date().getFullYear()} <strong>{store.name}</strong></span>
        <div className="footer__contacts">
          {contacts?.instagram_url && <a href={contacts.instagram_url} target="_blank" rel="noopener noreferrer"><span>Instagram</span><strong>@{contacts.instagram_url.split('/').filter(Boolean).pop()}</strong> ↗</a>}
          {contacts?.email && <a href={`mailto:${contacts.email}`}><span>Email</span><strong>{contacts.email}</strong> ↗</a>}
        </div>
      </footer>
    </div>
  )
}
