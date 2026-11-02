import { useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { supabaseConfigured, supabaseRequest } from '../lib/supabase'
import { useAuth } from '../context/AuthContext'

// Recovery credentials are kept only in this component, never in localStorage.
export function PasswordRecoveryPage({ reset = false }: { reset?: boolean }) {
  const { t } = useTranslation()
  const { logout } = useAuth()
  const [email, setEmail] = useState('')
  const [password, setPassword] = useState('')
  const [confirmation, setConfirmation] = useState('')
  const [token, setToken] = useState(() => {
    const hash = new URLSearchParams(window.location.hash.slice(1))
    return reset && hash.get('type') === 'recovery' ? hash.get('access_token') ?? '' : ''
  })
  const [busy, setBusy] = useState(false)
  const [done, setDone] = useState(false)
  const [error, setError] = useState('')
  useEffect(() => {
    if (!reset) return
    window.history.replaceState(null, '', window.location.pathname)
  }, [reset])
  const submit = async () => {
    setError('')
    if (reset && password !== confirmation) { setError(t('Passwords do not match')); return }
    setBusy(true)
    try {
      if (reset) {
        await supabaseRequest('/auth/v1/user', { method: 'PUT', token, body: JSON.stringify({ password }) })
        logout()
      }
      else await supabaseRequest(`/auth/v1/recover?redirect_to=${encodeURIComponent(`${window.location.origin}/reset-password`)}`, { method: 'POST', body: JSON.stringify({ email }) })
      setDone(true); setToken(''); setPassword(''); setConfirmation('')
    } catch (cause) { setError(cause instanceof Error ? cause.message : t('Action failed')) } finally { setBusy(false) }
  }
  return <section className="auth-page"><div className="auth-card"><h1>{t(reset ? 'New password' : 'Forgot password')}</h1>
    {!supabaseConfigured ? <p>{t('Recovery requires Supabase')}</p> : done ? <p role="status">{t(reset ? 'Password updated' : 'Recovery email sent')}</p> : <form className="form auth-card__form" onSubmit={event => { event.preventDefault(); void submit() }}>
      {(error || (reset && !token)) && <p className="error" role="alert">{error || t('Recovery link invalid')}</p>}
      {reset ? <><label className="field">{t('Password')}<input type="password" autoComplete="new-password" required minLength={8} value={password} onChange={event => setPassword(event.target.value)} /></label><label className="field">{t('Confirm password')}<input type="password" autoComplete="new-password" required minLength={8} value={confirmation} onChange={event => setConfirmation(event.target.value)} /></label></> : <label className="field">{t('Email')}<input type="email" autoComplete="email" required value={email} onChange={event => setEmail(event.target.value)} /></label>}
      <button className="btn" disabled={busy || (reset && !token)}>{t(busy ? 'Saving…' : reset ? 'Save password' : 'Send recovery email')}</button>
    </form>}<Link to="/login">{t('Sign in')}</Link></div></section>
}
