import { useCallback, useEffect, useLayoutEffect, useRef, useState, type Dispatch, type SetStateAction } from 'react'
import { NavLink, Outlet, useLocation } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'
import { useCart } from '../context/CartContext'
import { useStore } from '../context/StoreContext'
import { useTranslation } from 'react-i18next'
import { hasStoreMembership } from '../lib/crm'
import { supabaseConfigured } from '../lib/supabase'
import { contactsChanged, getStorefrontContacts, type StorefrontContacts } from '../lib/storefrontContacts'

type CatalogFilters = {
  category: string
  subcategory: string
  search: string
  size: string
  sort: string
}

export type CatalogNavigation = {
  filters: CatalogFilters
  setFilters: Dispatch<SetStateAction<CatalogFilters>>
  rememberProduct: (card: HTMLAnchorElement) => void
  restoreScroll: (grid: HTMLDivElement) => void
}

export function StoreLayout() {
  const { store, loading, notFound, loadFailed } = useStore()
  const { count } = useCart()
  const { isAuthenticated, token, user } = useAuth()
  const { t, i18n } = useTranslation()
  const { pathname, key } = useLocation()
  const isHome = pathname === '/'
  const homeScrollPosition = useRef<number | null>(null)
  const catalogReady = useRef(false)
  const lastProduct = useRef<{ pathname: string; top: number } | null>(null)
  const [filters, setFilters] = useState<CatalogFilters>({
    category: '', subcategory: '', search: '', size: '', sort: 'newest',
  })
  const [scrollState, setScrollState] = useState({ headerVisible: true, showTopButton: false })
  const storeId = store?.id
  const userId = user?.id
  const [crmAccess, setCrmAccess] = useState<{ storeId: string; userId: string; token: string } | null>(null)
  const [contacts, setContacts] = useState<StorefrontContacts | null>(null)

  useLayoutEffect(() => {
    const previousRestoration = window.history.scrollRestoration
    window.history.scrollRestoration = 'manual'
    return () => { window.history.scrollRestoration = previousRestoration }
  }, [])

  useLayoutEffect(() => {
    if (isHome) return
    catalogReady.current = false
    window.scrollTo({ top: 0, behavior: 'instant' })
  }, [isHome, key])

  const rememberProduct = (card: HTMLAnchorElement) => {
    homeScrollPosition.current = Math.max(0, window.scrollY)
    lastProduct.current = { pathname: card.pathname, top: card.getBoundingClientRect().top }
  }

  const restoreScroll = useCallback((grid: HTMLDivElement) => {
    if (catalogReady.current) return
    const product = lastProduct.current
    const card = product && Array.from(grid.querySelectorAll<HTMLAnchorElement>('a.product-card'))
      .find(link => link.pathname === product.pathname)
    const top = card && product
      ? window.scrollY + card.getBoundingClientRect().top - product.top
      : homeScrollPosition.current
    if (top !== null) window.scrollTo({ top, behavior: 'instant' })
    homeScrollPosition.current = window.scrollY
    lastProduct.current = null
    catalogReady.current = true
  }, [])

  useEffect(() => {
    if (!isHome) return
    let previousY = window.scrollY
    const onScroll = () => {
      const currentY = Math.max(0, window.scrollY)
      if (catalogReady.current) homeScrollPosition.current = currentY
      const delta = currentY - previousY
      setScrollState(current => ({
        headerVisible: currentY < 100 ? true : Math.abs(delta) >= 4 ? delta < 0 : current.headerVisible,
        showTopButton: currentY > 400,
      }))
      if (Math.abs(delta) >= 4 || currentY < 100) previousY = currentY
    }
    onScroll()
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [isHome])

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
      document.title = 'tatami.culture'
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
        <NavLink to="/">{t('Go to tatami.culture')}</NavLink>
      </div>
    )
  }

  return (
    <div className="shell">
      <header className={`topbar${isHome ? ' topbar--scroll' : ''}${isHome && !scrollState.headerVisible ? ' topbar--hidden' : ''}`} inert={isHome && !scrollState.headerVisible}>
        <NavLink to="/" className="brand">
          <img className="brand__mark" src="/tatami-mark-transparent.png" alt="" />
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
        <Outlet context={{ filters, setFilters, rememberProduct, restoreScroll } satisfies CatalogNavigation} />
      </main>
      {isHome && scrollState.showTopButton && <button type="button" className="back-to-top" aria-label={t('Back to top')} title={t('Back to top')} onClick={() => window.scrollTo({ top: 0, behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth' })}>↑</button>}
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
