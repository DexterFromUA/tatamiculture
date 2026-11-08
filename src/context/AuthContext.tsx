import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { api } from '../lib/api'
import { authSessionExpiredEvent, authSessionKey, clearAuthSession, previousSessionToken, readAuthSession, sameAuthSession, saveAuthSession } from '../lib/authSession'
import { supabaseConfigured, SupabaseError } from '../lib/supabase'
import type { AuthSession, User } from '../types'

type AuthContextValue = {
  user: User | null
  token: string | null
  isAuthenticated: boolean
  initializing: boolean
  restoreFailed: boolean
  retryRestore: () => void
  requestPhoneCode: typeof api.requestPhoneCode
  verifyPhoneCode: (phone: string, code: string, storeId: string) => Promise<AuthSession>
  completePhoneSignIn: (session: AuthSession) => Promise<void>
  logout: () => void
}

const AuthContext = createContext<AuthContextValue | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null)
  const [token, setToken] = useState<string | null>(null)
  const [initializing, setInitializing] = useState(true)
  const [restoreFailed, setRestoreFailed] = useState(false)
  const [restoreAttempt, setRestoreAttempt] = useState(0)
  const retryRestore = useCallback(() => setRestoreAttempt(value => value + 1), [])

  useEffect(() => {
    let generation = 0

    const reset = () => {
      generation++
      setToken(null)
      setUser(null)
      setRestoreFailed(false)
      setInitializing(false)
    }

    const restore = async () => {
      const attempt = ++generation
      const stored = readAuthSession()
      if (!stored) { reset(); return }
      setInitializing(true)
      setRestoreFailed(false)
      try {
        const current = await api.getCurrentUser(stored.token)
        const latest = readAuthSession()
        if (attempt !== generation || !latest || !sameAuthSession(stored.token, latest.token)) return
        setToken(latest.token)
        setUser(current)
      } catch (error) {
        const latest = readAuthSession()
        if (attempt !== generation || !latest || !sameAuthSession(stored.token, latest.token)) return
        if (!supabaseConfigured || (error instanceof SupabaseError && error.status === 401)) {
          clearAuthSession()
          reset()
        } else {
          setRestoreFailed(true)
        }
      } finally {
        if (attempt === generation) setInitializing(false)
      }
    }

    const sync = (event: StorageEvent) => {
      if (event.key !== authSessionKey && event.key !== null) return
      const previous = previousSessionToken(event.oldValue)
      const current = readAuthSession()
      if (previous && current && sameAuthSession(previous, current.token)) return
      reset()
      void restore()
    }

    window.addEventListener(authSessionExpiredEvent, reset)
    window.addEventListener('storage', sync)
    void restore()
    return () => {
      generation++
      window.removeEventListener(authSessionExpiredEvent, reset)
      window.removeEventListener('storage', sync)
    }
  }, [restoreAttempt])

  const completePhoneSignIn = useCallback(async (session: AuthSession) => {
    if (session.registrationStoreId) await api.joinStore(session.registrationStoreId, session)
    saveAuthSession(session)
    setRestoreFailed(false)
    setToken(session.token)
    setUser(session.user)
  }, [])

  const logout = useCallback(() => {
    clearAuthSession()
    setRestoreFailed(false)
    setToken(null)
    setUser(null)
  }, [])

  const value = useMemo(
    () => ({
      user,
      token,
      isAuthenticated: Boolean(user),
      initializing,
      restoreFailed,
      retryRestore,
      requestPhoneCode: api.requestPhoneCode,
      verifyPhoneCode: api.verifyPhoneCode,
      completePhoneSignIn,
      logout,
    }),
    [user, token, initializing, restoreFailed, retryRestore, completePhoneSignIn, logout],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

// eslint-disable-next-line react-refresh/only-export-components
export function useAuth() {
  const context = useContext(AuthContext)
  if (!context) throw new Error('useAuth must be used inside AuthProvider')
  return context
}
