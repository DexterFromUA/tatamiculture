import { useEffect, useState, type FormEvent } from 'react'
import { Link, Navigate, useLocation } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { api } from '../lib/api'
import { normalizePhone } from '../lib/phone'
import { SupabaseError, supabaseConfigured } from '../lib/supabase'
import { DEMO_SMS_CODE, demoUser } from '../mock/data'
import type { AuthSession } from '../types'

export function PhoneAuthPage({ register = false }: { register?: boolean }) {
  const { t } = useTranslation()
  const { store } = useStore()
  const { isAuthenticated, initializing, requestPhoneCode, verifyPhoneCode, completePhoneSignIn } = useAuth()
  const location = useLocation()
  const intent = location.state as { from?: string; receiptToClaim?: string; orderPhone?: string } | null
  const from = intent?.from ?? '/'
  const receiptToClaim = intent?.receiptToClaim
  const claimOrder = receiptToClaim && from === `/receipt/${encodeURIComponent(receiptToClaim)}`
  const orderPhone = claimOrder ? normalizePhone(intent?.orderPhone ?? '') : null
  const [phone, setPhone] = useState(orderPhone ?? '')
  const [name, setName] = useState('')
  const [sentTo, setSentTo] = useState<string | null>(null)
  const [code, setCode] = useState('')
  const [verified, setVerified] = useState<AuthSession | null>(null)
  const [seconds, setSeconds] = useState(0)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [claimError, setClaimError] = useState('')

  useEffect(() => {
    if (seconds <= 0) return
    const timer = window.setTimeout(() => setSeconds(value => value - 1), 1000)
    return () => window.clearTimeout(timer)
  }, [seconds])

  if (initializing) return <div className="page-status">{t('Loading…')}</div>
  if (isAuthenticated) return <Navigate to={from} replace state={claimError ? { claimError } : undefined} />

  const sendCode = async () => {
    if (busy || !store) return
    const number = normalizePhone(phone)
    if (!number) {
      setError('Enter a valid phone number.')
      return
    }
    if (orderPhone && number !== orderPhone) {
      setError('Use the phone number from this order.')
      return
    }
    const customerName = name.trim()
    if (register && !customerName) {
      setError('Enter your name.')
      return
    }

    setBusy(true)
    setError('')
    try {
      await requestPhoneCode(number, register ? { name: customerName, storeId: store.id } : undefined)
      setSentTo(number)
      setCode('')
      setSeconds(60)
    } catch (cause) {
      setError(cause instanceof SupabaseError && cause.status === 429
        ? 'Too many requests. Wait a minute and try again.'
        : 'Could not send an SMS code. Check the number or try again later.')
    } finally {
      setBusy(false)
    }
  }

  const submit = async (event: FormEvent) => {
    event.preventDefault()
    if (busy || !store) return
    if (!sentTo) {
      await sendCode()
      return
    }

    setBusy(true)
    setError('')
    let session = verified
    try {
      if (!session) {
        session = await verifyPhoneCode(sentTo, code, store.id)
        setVerified(session)
      }
      if (claimOrder) {
        try {
          const claimed = await api.claimGuestOrder(store.id, receiptToClaim, session.token)
          setClaimError(claimed ? '' : 'This order could not be linked to this account.')
        } catch {
          setClaimError('Could not save this order. Try again.')
        }
      }
      await completePhoneSignIn(session)
    } catch (cause) {
      if (session) setError('Could not finish signing in. Try again.')
      else if (cause instanceof SupabaseError && cause.status === 429) setError('Too many requests. Wait a minute and try again.')
      else if (cause instanceof SupabaseError && cause.status >= 500) setError('Could not finish signing in. Try again.')
      else setError('The code is incorrect or has expired.')
    } finally {
      setBusy(false)
    }
  }

  const action = sentTo ? 'Confirm code' : 'Send SMS code'
  return (
    <section className="auth-page auth-page--login">
      <div className={`auth-card auth-card--login${register ? ' auth-card--register' : ''}`}>
        <header className="auth-card__head login-intro">
          <p className="eyebrow">{t('Tatami.Culture account')}</p>
          <h1>{t(register ? 'Create account' : 'Welcome back')}</h1>
          <p className="muted">{t(register ? 'Keep track of your training gear and every order in one place.' : 'Sign in to view your orders and manage your details.')}</p>
          <span className="login-intro__mark" aria-hidden="true">T.</span>
        </header>
        <div className="login-form-panel">
          <p className="eyebrow">{t(sentTo ? 'Verify your phone' : register ? 'Create account' : 'Sign in')}</p>
          <form className="form auth-card__form" onSubmit={event => void submit(event)}>
            {claimOrder && !sentTo && !error && <p className="muted">{t('Use the phone number from this order.')}</p>}
            {error && <p className="error" role="alert">{t(error)}</p>}
            {sentTo ? <>
              <p className="muted" role="status">{t('Code sent to {{phone}}.', { phone: sentTo })}</p>
              <label className="field">
                <span>{t('SMS code')}</span>
                <input type="text" inputMode="numeric" autoComplete="one-time-code" maxLength={6}
                  pattern="[0-9]{6}" value={code} onChange={event => setCode(event.target.value.replace(/[^0-9]/g, ''))}
                  required disabled={busy || Boolean(verified)} />
              </label>
            </> : <>
              {register && <label className="field">
                <span>{t('Name')}</span>
                <input autoComplete="name" maxLength={100} value={name} onChange={event => setName(event.target.value)} required disabled={busy} />
              </label>}
              <label className="field">
                <span>{t('Phone')}</span>
                <input type="tel" autoComplete="tel" placeholder="+380" value={phone} onChange={event => setPhone(event.target.value)} required disabled={busy} />
              </label>
            </>}
            <button type="submit" className="btn" disabled={busy || !store || (Boolean(sentTo) && !verified && code.length !== 6)}>
              {t(busy ? sentTo ? 'Checking…' : 'Sending…' : verified ? 'Try again' : action)}
            </button>
          </form>
          {sentTo && !verified && <div className="auth-card__code-actions">
            <button type="button" className="text-btn" onClick={() => { setSentTo(null); setCode(''); setError('') }} disabled={busy}>{t('Change number')}</button>
            <button type="button" className="text-btn" onClick={() => void sendCode()} disabled={busy || seconds > 0}>
              {seconds > 0 ? t('Resend in {{seconds}} s', { seconds }) : t('Resend code')}
            </button>
          </div>}
          <p className="auth-card__footer">
            {t(register ? 'Already have an account?' : 'New here?')}{' '}
            <Link to={register ? '/login' : '/register'} state={location.state}>{t(register ? 'Sign in' : 'Create an account')}</Link>
          </p>
          {!supabaseConfigured && <p className="auth-card__demo">{t('Demo phone: {{phone}} · code: {{code}}', { phone: demoUser.phone, code: DEMO_SMS_CODE })}</p>}
        </div>
      </div>
    </section>
  )
}
