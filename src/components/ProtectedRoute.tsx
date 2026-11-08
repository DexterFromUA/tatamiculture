import type { ReactNode } from 'react'
import { Navigate, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'

export function ProtectedRoute({ children }: { children: ReactNode }) {
  const { isAuthenticated, initializing, restoreFailed, retryRestore } = useAuth()
  const location = useLocation()
  const { t } = useTranslation()

  if (initializing) {
    return <div className="page-status">{t('Loading…')}</div>
  }

  if (restoreFailed) {
    return <div className="page-status">
      <p role="alert">{t('Could not restore your session. Check your connection and try again.')}</p>
      <button type="button" className="btn" onClick={retryRestore}>{t('Try again')}</button>
    </div>
  }

  if (!isAuthenticated) {
    return <Navigate to="/login" replace state={{ from: location.pathname }} />
  }

  return children
}
