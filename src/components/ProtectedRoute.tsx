import type { ReactNode } from 'react'
import { Navigate, useLocation } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'

export function ProtectedRoute({ children }: { children: ReactNode }) {
  const { isAuthenticated, initializing } = useAuth()
  const location = useLocation()

  if (initializing) {
    return <div className="page-status">Loading…</div>
  }

  if (!isAuthenticated) {
    return <Navigate to="/login" replace state={{ from: location.pathname }} />
  }

  return children
}
