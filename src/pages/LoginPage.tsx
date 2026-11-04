import { useState, type FormEvent } from 'react'
import { Link, Navigate, useLocation } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'
import { DEMO_PASSWORD } from '../mock/data'
import { supabaseConfigured } from '../lib/supabase'
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
    <section className="auth-page auth-page--login">
      <div className="auth-card auth-card--login">
        <header className="auth-card__head login-intro">
          <p className="eyebrow">{t('Tatami account')}</p>
          <h1>{t('Welcome back')}</h1>
          <p className="muted">{t('Sign in to view your orders and manage your details.')}</p>
          <span className="login-intro__mark" aria-hidden="true">T.</span>
        </header>
        <div className="login-form-panel">
        <p className="eyebrow">{t('Sign in')}</p>
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
        <p className="auth-card__recovery"><Link to="/forgot-password">{t('Forgot password')}</Link></p>
        <p className="auth-card__footer">{t('New here?')} <Link to="/register">{t('Create an account')}</Link></p>
        {!supabaseConfigured ? <p className="auth-card__demo">Demo: anna@example.com / {DEMO_PASSWORD}</p> : null}
        </div>
      </div>
    </section>
  )
}
