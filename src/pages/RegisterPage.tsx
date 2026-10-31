import { useState, type FormEvent } from 'react'
import { Link, Navigate } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'

export function RegisterPage() {
  const { register, isAuthenticated, loading } = useAuth()
  const [name, setName] = useState('')
  const [email, setEmail] = useState('')
  const [phone, setPhone] = useState('')
  const [password, setPassword] = useState('')
  const [error, setError] = useState<string | null>(null)

  if (isAuthenticated) {
    return <Navigate to="/" replace />
  }

  const onSubmit = async (event: FormEvent) => {
    event.preventDefault()
    setError(null)
    try {
      await register({ name, email, phone, password })
    } catch (err) {
      setError(err instanceof Error ? err.message : 'Registration failed')
    }
  }

  return (
    <section className="form-narrow">
      <header className="page-head">
        <h1>Create account</h1>
      </header>
      <form className="form" onSubmit={(event) => void onSubmit(event)}>
        {error ? <p className="error">{error}</p> : null}
        <label className="field">
          <span>Name</span>
          <input value={name} onChange={(event) => setName(event.target.value)} required />
        </label>
        <label className="field">
          <span>Email</span>
          <input type="email" value={email} onChange={(event) => setEmail(event.target.value)} required />
        </label>
        <label className="field">
          <span>Phone</span>
          <input value={phone} onChange={(event) => setPhone(event.target.value)} required />
        </label>
        <label className="field">
          <span>Password</span>
          <input type="password" value={password} onChange={(event) => setPassword(event.target.value)} required />
        </label>
        <button type="submit" className="btn" disabled={loading}>
          {loading ? 'Creating…' : 'Create account'}
        </button>
      </form>
      <p>
        Already have an account? <Link to="/login">Sign in</Link>
      </p>
    </section>
  )
}
