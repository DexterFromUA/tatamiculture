import { useState, type FormEvent } from 'react'
import { Link, Navigate, useLocation } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'
import { DEMO_PASSWORD } from '../mock/data'
import { useTranslation } from 'react-i18next'

export function LoginPage() {
  const { login, isAuthenticated, loading } = useAuth()
  const location = useLocation()
  const from = (location.state as { from?: string } | null)?.from ?? '/'
  const [email, setEmail] = useState('anna@example.com')
  const [password, setPassword] = useState(DEMO_PASSWORD)
  const [error, setError] = useState<string | null>(null)
  const { t } = useTranslation()

  if (isAuthenticated) {
    return <Navigate to={from} replace />
  }

  const onSubmit = async (event: FormEvent) => {
    event.preventDefault()
    setError(null)
    try {
      await login(email, password)
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Sign in failed')
    }
  }

  return (
    <section className="auth-page">
      <div className="auth-card">
        <header className="auth-card__head">
          <p className="eyebrow">{t('Tatami account')}</p>
          <h1>{t('Welcome back')}</h1>
          <p className="muted">{t('Sign in to view your orders and manage your details.')}</p>
        </header>
        <form className="form auth-card__form" onSubmit={(event) => void onSubmit(event)}>
        {error ? <p className="error">{error}</p> : null}
        <label className="field">
          <span>{t('Email')}</span>
          <input type="email" value={email} onChange={(event) => setEmail(event.target.value)} required />
        </label>
        <label className="field">
          <span>{t('Password')}</span>
          <input type="password" value={password} onChange={(event) => setPassword(event.target.value)} required />
        </label>
        <button type="submit" className="btn" disabled={loading}>
          {loading ? t('Signing in…') : t('Sign in')}
        </button>
        </form>
        <p className="auth-card__footer">{t('New here?')} <Link to="/register">{t('Create an account')}</Link></p>
        <p className="auth-card__demo">Demo: anna@example.com / {DEMO_PASSWORD}</p>
      </div>
    </section>
  )
}
