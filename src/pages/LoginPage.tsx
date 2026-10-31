import { useState, type FormEvent } from 'react'
import { Link, Navigate, useLocation } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'
import { DEMO_PASSWORD } from '../mock/data'

export function LoginPage() {
  const { login, isAuthenticated, loading } = useAuth()
  const location = useLocation()
  const from = (location.state as { from?: string } | null)?.from ?? '/'
  const [email, setEmail] = useState('anna@example.com')
  const [password, setPassword] = useState(DEMO_PASSWORD)
  const [error, setError] = useState<string | null>(null)

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
    <section className="form-narrow">
      <header className="page-head">
        <h1>Sign in</h1>
        <p className="muted">
          Demo account: anna@example.com / {DEMO_PASSWORD}
        </p>
      </header>
      <form className="form" onSubmit={(event) => void onSubmit(event)}>
        {error ? <p className="error">{error}</p> : null}
        <label className="field">
          <span>Email</span>
          <input type="email" value={email} onChange={(event) => setEmail(event.target.value)} required />
        </label>
        <label className="field">
          <span>Password</span>
          <input type="password" value={password} onChange={(event) => setPassword(event.target.value)} required />
        </label>
        <button type="submit" className="btn" disabled={loading}>
          {loading ? 'Signing in…' : 'Sign in'}
        </button>
      </form>
      <p>
        New here? <Link to="/register">Create an account</Link>
      </p>
    </section>
  )
}
