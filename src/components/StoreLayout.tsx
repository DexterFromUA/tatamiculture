import { useCallback, useEffect, useLayoutEffect, useRef, useState, type Dispatch, type SetStateAction } from 'react'
import { NavLink, Outlet, useLocation } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'
import { useCart } from '../context/CartContext'
import { useStore } from '../context/StoreContext'
import { useTranslation } from 'react-i18next'
import { hasStoreMembership } from '../lib/crm'
import { supabaseConfigured } from '../lib/supabase'
import { contactsChanged, getStorefrontContacts, type StorefrontContacts } from '../lib/storefrontContacts'
import { agreementPath } from '../content/agreement'
import { ThemeSwitch } from './ThemeSwitch'
import { useStorefrontTheme } from '../hooks/useStorefrontTheme'
import { LoadingIndicator } from './LoadingIndicator'
import { useStorefrontCatalog } from '../hooks/useStorefrontCatalog'
import type { CatalogFilters } from '../lib/storefrontCatalog'
import { isStandalone, pwaLayoutPreview } from '../lib/pwa'
import { PwaInstallOffer } from './PwaInstallOffer'
import { PushNotificationsPrompt } from './PushNotificationsPrompt'
import { useCustomerPushPermissionSync } from '../hooks/useCustomerPushPermissionSync'

const tabIcons = {
  shop: 'M3 10 5 4h14l2 6M3 10v2a3 3 0 0 0 6 0 3 3 0 0 0 6 0 3 3 0 0 0 6 0v-2H3m2 5v5h14v-5',
  cart: 'M4 8h16l1 12H3L4 8Zm5 2V6a3 3 0 0 1 6 0v4',
  crm: 'M4 20V4h16v16H4Zm4-4v-3m4 3V8m4 8v-5',
  account: 'M16 8a4 4 0 1 1-8 0 4 4 0 0 1 8 0ZM4 21v-2a4 4 0 0 1 4-4h8a4 4 0 0 1 4 4v2',
}

export type CatalogNavigation = {
  filters: CatalogFilters
  setFilters: Dispatch<SetStateAction<CatalogFilters>>
  rememberProduct: (card: HTMLAnchorElement) => void
  restoreScroll: (grid: HTMLDivElement) => void
  catalog: ReturnType<typeof useStorefrontCatalog>
}

export function StoreLayout() {
  const { store, catalogRevision, loading, notFound, loadFailed, retryStore } = useStore()
  const { count } = useCart()
  const { isAuthenticated, token, user, initializing, restoreFailed } = useAuth()
  const { t, i18n } = useTranslation()
  const { pathname, key } = useLocation()
  const isHome = pathname === '/'
  const homeScrollPosition = useRef<number | null>(null)
  const catalogReady = useRef(false)
  const lastProduct = useRef<{ pathname: string; top: number } | null>(null)
  const [filters, setFilters] = useState<CatalogFilters>({
    category: '', subcategory: '', search: '', size: '', sort: 'recently-updated',
  })
  const [scrollState, setScrollState] = useState({ headerVisible: true, showTopButton: false })
  const [standalone, setStandalone] = useState(() => isStandalone() || pwaLayoutPreview)
  const storeId = store?.id
  const { mode, theme, showThemeSwitch, selectTheme } = useStorefrontTheme(storeId)
  const catalog = useStorefrontCatalog(storeId, filters, catalogRevision, isHome)
  const userId = user?.id
  const [crmAccess, setCrmAccess] = useState<{ storeId: string; userId: string; token: string } | null>(null)
  const [contacts, setContacts] = useState<StorefrontContacts | null>(null)
  useCustomerPushPermissionSync(standalone, token, userId)

  useEffect(() => {
    const mode = window.matchMedia('(display-mode: standalone)')
    const update = () => setStandalone(isStandalone() || pwaLayoutPreview)
    mode.addEventListener('change', update)
    return () => mode.removeEventListener('change', update)
  }, [])

  useEffect(() => {
    if (standalone && !loading && !(loadFailed && !navigator.onLine)) {
      window.dispatchEvent(new Event('tatami-app-ready'))
    }
  }, [standalone, loading, loadFailed])

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
    let requestId = 0
    const refreshAccess = () => {
      const current = ++requestId
      void hasStoreMembership(storeId, userId, token, abort.signal)
        .then(isMember => {
          if (!abort.signal.aborted && current === requestId) setCrmAccess(isMember ? { storeId, userId, token } : null)
        })
        .catch(() => {
          if (!abort.signal.aborted && current === requestId) setCrmAccess(null)
        })
    }
    refreshAccess()
    window.addEventListener('focus', refreshAccess)
    const timer = window.setInterval(refreshAccess, 30000)
    return () => { abort.abort(); window.removeEventListener('focus', refreshAccess); window.clearInterval(timer) }
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
    return <LoadingIndicator label={t('Opening store…')} />
  }

  if (loadFailed) {
    return <main className="page-status">
      <h1>{t('Store temporarily unavailable')}</h1>
      <button type="button" className="btn" onClick={retryStore}>{t('Try again')}</button>
    </main>
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

  const nextLanguage = i18n.language === 'uk' ? 'en' : 'uk'
  const nextLanguageName = nextLanguage === 'en' ? 'English' : 'Українська'
  const tabs: { to: string; icon: keyof typeof tabIcons; label: string; active?: boolean }[] = [
    { to: '/', icon: 'shop', label: t('Shop'), active: pathname.startsWith('/product/') },
    { to: '/cart', icon: 'cart', label: t('Cart'), active: pathname === '/checkout' },
  ]
  if (canOpenCrm) tabs.push({ to: '/admin', icon: 'crm', label: 'CRM' })
  tabs.push(isAuthenticated
    ? { to: '/account', icon: 'account', label: t('Account'), active: pathname === '/orders' }
    : { to: '/login', icon: 'account', label: t('Sign in'), active: pathname === '/register' })

  return (
    <div className={standalone ? 'shell shell--standalone' : 'shell'}>
      {standalone && isHome && !initializing && !restoreFailed && <PushNotificationsPrompt token={token} />}
      <header className={`topbar${isHome ? ' topbar--scroll' : ''}${isHome && !scrollState.headerVisible ? ' topbar--hidden' : ''}`} inert={isHome && !scrollState.headerVisible}>
        <NavLink to="/" className="brand">
          <img className="brand__mark" src="/tatami-mark-transparent.png" alt="" />
          {store.name}
        </NavLink>
        <nav className="nav">
          {!standalone && <>
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
          </>}
          <button type="button" className="text-btn nav__language" lang={nextLanguage} aria-label={nextLanguageName} onClick={() => void i18n.changeLanguage(nextLanguage)}>
            {nextLanguage === 'en' ? 'EN' : 'UA'}
          </button>
          {showThemeSwitch && <ThemeSwitch mode={mode} theme={theme} onChange={selectTheme} />}
        </nav>
      </header>
      <main className="main">
        <Outlet context={{ filters, setFilters, rememberProduct, restoreScroll, catalog } satisfies CatalogNavigation} />
      </main>
      {isHome && scrollState.showTopButton && <button type="button" className="back-to-top" aria-label={t('Back to top')} title={t('Back to top')} onClick={() => window.scrollTo({ top: 0, behavior: window.matchMedia('(prefers-reduced-motion: reduce)').matches ? 'instant' : 'smooth' })}>↑</button>}
      <footer className="footer">
        <NavLink to={agreementPath} className="footer__agreement">{t('User agreement')}</NavLink>
        {!standalone && !/^\/admin(?:\/|$)/.test(pathname) && <PwaInstallOffer placement="footer" />}
        <span className="footer__copyright"><strong>{store.name}</strong> © {new Date().getFullYear()}</span>
        {contacts?.instagram_url && <a className="footer__contact footer__instagram" href={contacts.instagram_url} target="_blank" rel="noopener noreferrer">
          <span><span className="sr-only">Instagram </span>@{contacts.instagram_url.split('/').filter(Boolean).pop()}</span>
          <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="1.6" aria-hidden="true">
            <rect x="3" y="3" width="18" height="18" rx="5" />
            <circle cx="12" cy="12" r="4" />
            <circle cx="17.5" cy="6.5" r="1" fill="currentColor" stroke="none" />
          </svg>
        </a>}
        {contacts?.email && <a className="footer__contact footer__email" href={`mailto:${contacts.email}`}>
          <span><span className="sr-only">{t('Email')} </span>{contacts.email}</span>
          <svg viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" strokeWidth="1.6" strokeLinejoin="round" aria-hidden="true">
            <rect x="3" y="5" width="18" height="14" rx="2" />
            <path d="m3.5 7 8.5 6 8.5-6" />
          </svg>
        </a>}
      </footer>
      {standalone && <nav className="app-tabs" aria-label={t('Store navigation')}>
        <div className="app-tabs__inner">
          {tabs.map(tab => <NavLink key={tab.icon} to={tab.to} end={tab.to === '/'}
            className={({ isActive }) => isActive || tab.active ? 'app-tabs__link active' : 'app-tabs__link'}>
            <span className="app-tabs__icon">
              <svg width="22" height="22" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="1.7" strokeLinecap="round" strokeLinejoin="round" aria-hidden="true"><path d={tabIcons[tab.icon]} /></svg>
              {tab.icon === 'cart' && count > 0 && <span className="app-tabs__count">{count > 99 ? '99+' : count}</span>}
            </span>
            <span>{tab.label}</span>
          </NavLink>)}
        </div>
      </nav>}
    </div>
  )
}
