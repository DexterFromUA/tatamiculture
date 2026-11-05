import { useState, type FormEvent } from 'react'
import { Link, Navigate } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { supabaseRequest } from '../lib/supabase'
import { useTranslation } from 'react-i18next'

export function RegisterPage() {
  const { register, isAuthenticated, loading } = useAuth()
  const { store } = useStore()
  const [name, setName] = useState('')
  const [email, setEmail] = useState('')
  const [phone, setPhone] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)
  const { t } = useTranslation()

  if (isAuthenticated) {
    return <Navigate to="/" replace />
  }

  const onSubmit = async (event: FormEvent) => {
    event.preventDefault()
    setError(null)
    try {
      const session = await register({ name, email, phone, password })
      if (store) await supabaseRequest('/rest/v1/store_customers', { method: 'POST', token: session.token, body: JSON.stringify({ store_id: store.id, user_id: session.user.id }) })
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Registration failed')
    }
  }

  return (
    <section className="auth-page auth-page--login auth-page--register">
      <div className="auth-card auth-card--login auth-card--register">
        <header className="auth-card__head login-intro">
          <p className="eyebrow">{t('Tatami.Culture account')}</p>
          <h1>{t('Create account')}</h1>
          <p className="muted">{t('Keep track of your training gear and every order in one place.')}</p>
          <span className="login-intro__mark" aria-hidden="true">T.</span>
        </header>
        <div className="login-form-panel register-form-panel">
          <p className="eyebrow">{t('Create account')}</p>
          <form className="form auth-card__form register-form" onSubmit={(event) => void onSubmit(event)}>
            {error && <p className="error register-form__error" role="alert">{error}</p>}
            <label className="field">
              <span>{t('Name')}</span>
              <input autoComplete="name" value={name} onChange={(event) => setName(event.target.value)} required />
            </label>
            <label className="field">
              <span>{t('Phone')}</span>
              <input type="tel" autoComplete="tel" value={phone} onChange={(event) => setPhone(event.target.value)} required />
            </label>
            <label className="field register-form__wide">
              <span>{t('Email')}</span>
              <input type="email" autoComplete="email" value={email} onChange={(event) => setEmail(event.target.value)} required />
            </label>
            <label className="field register-form__wide">
              <span>{t('Password')}</span>
              <input type="password" autoComplete="new-password" value={password} onChange={(event) => setPassword(event.target.value)} required />
            </label>
            <button type="submit" className="btn register-form__wide" disabled={loading}>
              {loading ? t('Creating…') : t('Create account')}
            </button>
          </form>
          <p className="auth-card__footer">{t('Already have an account?')} <Link to="/login">{t('Sign in')}</Link></p>
        </div>
      </div>
    </section>
  )
}
