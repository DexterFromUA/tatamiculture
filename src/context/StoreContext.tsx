import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { api } from '../lib/api'
import type { Store } from '../types'

type StoreContextValue = {
  store: Store | null
  catalogRevision: number
  loading: boolean
  notFound: boolean
  loadFailed: boolean
  refreshProducts: () => void
  setSmsNotificationsEnabled: (enabled: boolean, token: string) => Promise<void>
}

const StoreContext = createContext<StoreContextValue | null>(null)

export function StoreProvider({ children }: { children: ReactNode }) {
  const [store, setStore] = useState<Store | null>(null)
  const [catalogRevision, setCatalogRevision] = useState(0)
  const [loading, setLoading] = useState(true)
  const [notFound, setNotFound] = useState(false)
  const [loadFailed, setLoadFailed] = useState(false)

  useEffect(() => {
    const abort = new AbortController()
    void api.getStore(abort.signal).then(nextStore => {
      if (abort.signal.aborted) return
      setStore(nextStore)
      setNotFound(!nextStore)
      setLoading(false)
    }).catch(() => {
      if (abort.signal.aborted) return
      setLoadFailed(true)
      setLoading(false)
    })
    return () => abort.abort()
  }, [])

  const storeId = store?.id
  const refreshProducts = useCallback(() => setCatalogRevision(revision => revision + 1), [])

  const setSmsNotificationsEnabled = useCallback(async (enabled: boolean, token: string) => {
    if (!storeId) return
    const saved = await api.setSmsNotificationsEnabled(storeId, enabled, token)
    setStore(current => current?.id === storeId ? { ...current, smsNotificationsEnabled: saved } : current)
  }, [storeId])

  const value = useMemo(
    () => ({ store, catalogRevision, loading, notFound, loadFailed, refreshProducts, setSmsNotificationsEnabled }),
    [store, catalogRevision, loading, notFound, loadFailed, refreshProducts, setSmsNotificationsEnabled],
  )

  return <StoreContext.Provider value={value}>{children}</StoreContext.Provider>
}

// eslint-disable-next-line react-refresh/only-export-components
export function useStore() {
  const context = useContext(StoreContext)
  if (!context) throw new Error('useStore must be used inside StoreProvider')
  return context
}
