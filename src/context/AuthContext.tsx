import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { api } from '../lib/api'
import { removeKey, readJson, writeJson } from '../lib/storage'
import type { AuthSession, User } from '../types'

const TOKEN_KEY = 'shop.store.token'

type AuthContextValue = {
  user: User | null
  token: string | null
  isAuthenticated: boolean
  initializing: boolean
  requestPhoneCode: typeof api.requestPhoneCode
  verifyPhoneCode: (phone: string, code: string, storeId: string) => Promise<AuthSession>
  completePhoneSignIn: (session: AuthSession) => Promise<void>
  logout: () => void
}

const AuthContext = createContext<AuthContextValue | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null)
  const [token, setToken] = useState<string | null>(() => readJson<string | null>(TOKEN_KEY, null))
  const [initializing, setInitializing] = useState(true)

  useEffect(() => {
    let cancelled = false

    const restore = async () => {
      const stored = readJson<string | null>(TOKEN_KEY, null)
      if (!stored) {
        setInitializing(false)
        return
      }

      try {
        const current = await api.getCurrentUser(stored)
        if (cancelled) return
        setToken(stored)
        setUser(current)
      } catch {
        if (cancelled) return
        removeKey(TOKEN_KEY)
        setToken(null)
        setUser(null)
      } finally {
        if (!cancelled) setInitializing(false)
      }
    }

    void restore()
    return () => {
      cancelled = true
    }
  }, [])

  const completePhoneSignIn = useCallback(async (session: AuthSession) => {
    if (session.registrationStoreId) await api.joinStore(session.registrationStoreId, session)
    writeJson(TOKEN_KEY, session.token)
    setToken(session.token)
    setUser(session.user)
  }, [])

  const logout = useCallback(() => {
    removeKey(TOKEN_KEY)
    setToken(null)
    setUser(null)
  }, [])

  const value = useMemo(
    () => ({
      user,
      token,
      isAuthenticated: Boolean(user),
      initializing,
      requestPhoneCode: api.requestPhoneCode,
      verifyPhoneCode: api.verifyPhoneCode,
      completePhoneSignIn,
      logout,
    }),
    [user, token, initializing, completePhoneSignIn, logout],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth() {
  const context = useContext(AuthContext)
  if (!context) throw new Error('useAuth must be used inside AuthProvider')
  return context
}
