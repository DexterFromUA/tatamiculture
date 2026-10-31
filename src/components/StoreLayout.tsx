import { useEffect } from 'react'
import { NavLink, Outlet } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'
import { useCart } from '../context/CartContext'
import { useStore } from '../context/StoreContext'

export function StoreLayout() {
  const { store, loading, notFound } = useStore()
  const { count } = useCart()
  const { isAuthenticated, user } = useAuth()

  useEffect(() => {
    if (!store) return
    document.title = store.name
    return () => {
      document.title = 'Store'
    }
  }, [store])

  if (loading) {
    return <div className="page-status">Opening store…</div>
  }

  if (notFound || !store) {
    return (
      <div className="page-status">
        <h1>Store not found</h1>
        <p>The storefront is unavailable right now.</p>
        <NavLink to="/">Go to Tatami</NavLink>
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
            Shop
          </NavLink>
          <NavLink to="/cart">Cart{count > 0 ? ` (${count})` : ''}</NavLink>
          {isAuthenticated ? (
            <>
              <NavLink to="/admin">CRM</NavLink>
              <NavLink to="/account">{user?.name.split(' ')[0] ?? 'Account'}</NavLink>
            </>
          ) : (
            <NavLink to="/login">Sign in</NavLink>
          )}
        </nav>
      </header>
      <main className="main">
        <Outlet />
      </main>
      <footer className="footer">
        <span>
          {store.name} · {store.contactCity}
        </span>
        <span>Mock payments only</span>
      </footer>
    </div>
  )
}
