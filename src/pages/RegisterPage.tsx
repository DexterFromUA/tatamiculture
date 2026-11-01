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
    <section className="auth-page">
      <div className="auth-card">
        <header className="auth-card__head">
          <p className="eyebrow">{t('Tatami account')}</p>
          <h1>{t('Create account')}</h1>
          <p className="muted">{t('Keep track of your training gear and every order in one place.')}</p>
        </header>
        <form className="form auth-card__form" onSubmit={(event) => void onSubmit(event)}>
        {error ? <p className="error">{error}</p> : null}
        <label className="field">
          <span>{t('Name')}</span>
          <input value={name} onChange={(event) => setName(event.target.value)} required />
        </label>
        <label className="field">
          <span>{t('Email')}</span>
          <input type="email" value={email} onChange={(event) => setEmail(event.target.value)} required />
        </label>
        <label className="field">
          <span>{t('Phone')}</span>
          <input value={phone} onChange={(event) => setPhone(event.target.value)} required />
        </label>
        <label className="field">
          <span>{t('Password')}</span>
          <input type="password" value={password} onChange={(event) => setPassword(event.target.value)} required />
        </label>
        <button type="submit" className="btn" disabled={loading}>
          {loading ? t('Creating…') : t('Create account')}
        </button>
        </form>
        <p className="auth-card__footer">{t('Already have an account?')} <Link to="/login">{t('Sign in')}</Link></p>
      </div>
    </section>
  )
}
