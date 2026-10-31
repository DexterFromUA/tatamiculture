import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { api } from '../lib/api'
import { removeKey, readJson, writeJson } from '../lib/storage'
import type { User } from '../types'
import type { AuthSession } from '../types'

const TOKEN_KEY = 'shop.store.token'

type AuthContextValue = {
  user: User | null
  token: string | null
  isAuthenticated: boolean
  initializing: boolean
  loading: boolean
  login: (email: string, password: string) => Promise<void>
  register: (input: { name: string; email: string; phone: string; password: string }) => Promise<AuthSession>
  logout: () => void
}

const AuthContext = createContext<AuthContextValue | null>(null)

export function AuthProvider({ children }: { children: ReactNode }) {
  const [user, setUser] = useState<User | null>(null)
  const [token, setToken] = useState<string | null>(() => readJson<string | null>(TOKEN_KEY, null))
  const [initializing, setInitializing] = useState(true)
  const [loading, setLoading] = useState(false)

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

  const login = useCallback(async (email: string, password: string) => {
    setLoading(true)
    try {
      const session = await api.login(email, password)
      writeJson(TOKEN_KEY, session.token)
      setToken(session.token)
      setUser(session.user)
    } finally {
      setLoading(false)
    }
  }, [])

  const register = useCallback(async (input: { name: string; email: string; phone: string; password: string }) => {
    setLoading(true)
    try {
      const session = await api.register(input)
      writeJson(TOKEN_KEY, session.token)
      setToken(session.token)
      setUser(session.user)
      return session
    } finally {
      setLoading(false)
    }
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
      loading,
      login,
      register,
      logout,
    }),
    [user, token, initializing, loading, login, register, logout],
  )

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>
}

export function useAuth() {
  const context = useContext(AuthContext)
  if (!context) throw new Error('useAuth must be used inside AuthProvider')
  return context
}
