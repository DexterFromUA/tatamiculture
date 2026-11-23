import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { api } from '../lib/api'
import { SupabaseError } from '../lib/supabase'
import type { NotificationChannel, NotificationTopic, Store } from '../types'

type StoreContextValue = {
  store: Store | null
  catalogRevision: number
  loading: boolean
  notFound: boolean
  loadFailed: boolean
  retryStore: () => void
  refreshProducts: () => void
  setNotificationChannel: (topic: NotificationTopic, channel: NotificationChannel, enabled: boolean, token: string) => Promise<void>
}

const StoreContext = createContext<StoreContextValue | null>(null)

type StoreLoadStatus = 'loading' | 'loaded' | 'not-found' | 'failed'

export function StoreProvider({ children }: { children: ReactNode }) {
  const [store, setStore] = useState<Store | null>(null)
  const [catalogRevision, setCatalogRevision] = useState(0)
  const [{ attempt, status }, setStoreLoad] = useState<{ attempt: number; status: StoreLoadStatus }>({ attempt: 0, status: 'loading' })

  const retryStore = useCallback(() => {
    setStoreLoad(current => current.status === 'failed' ? { attempt: current.attempt + 1, status: 'loading' } : current)
  }, [])

  useEffect(() => {
    const abort = new AbortController()
    let retryTimer: number | undefined

    async function loadStore(canRetry: boolean) {
      const request = new AbortController()
      const cancelRequest = () => request.abort()
      abort.signal.addEventListener('abort', cancelRequest, { once: true })
      const timeout = window.setTimeout(cancelRequest, 8000)
      try {
        const nextStore = await api.getStore(request.signal)
        if (abort.signal.aborted) return
        setStore(nextStore)
        setStoreLoad({ attempt, status: nextStore ? 'loaded' : 'not-found' })
      } catch (error) {
        if (abort.signal.aborted) return
        const temporary = request.signal.aborted || error instanceof TypeError
          || (error instanceof SupabaseError && (error.status === 408 || error.status >= 500))
        if (canRetry && temporary && navigator.onLine && !document.hidden) {
          retryTimer = window.setTimeout(() => {
            if (navigator.onLine && !document.hidden) void loadStore(false)
            else setStoreLoad({ attempt, status: 'failed' })
          }, 750)
          return
        }
        setStoreLoad({ attempt, status: 'failed' })
      } finally {
        window.clearTimeout(timeout)
        abort.signal.removeEventListener('abort', cancelRequest)
      }
    }

    void loadStore(true)
    return () => {
      abort.abort()
      window.clearTimeout(retryTimer)
    }
  }, [attempt])

  useEffect(() => {
    const resume = () => {
      if (navigator.onLine && !document.hidden) retryStore()
    }
    document.addEventListener('visibilitychange', resume)
    window.addEventListener('pageshow', resume)
    window.addEventListener('online', resume)
    return () => {
      document.removeEventListener('visibilitychange', resume)
      window.removeEventListener('pageshow', resume)
      window.removeEventListener('online', resume)
    }
  }, [retryStore])

  const storeId = store?.id
  const refreshProducts = useCallback(() => setCatalogRevision(revision => revision + 1), [])

  const setNotificationChannel = useCallback(async (topic: NotificationTopic, channel: NotificationChannel, enabled: boolean, token: string) => {
    if (!storeId) return
    const notifications = await api.setNotificationChannel(storeId, topic, channel, enabled, token)
    setStore(current => current?.id === storeId ? { ...current, notifications } : current)
  }, [storeId])

  const value = useMemo(
    () => ({
      store,
      catalogRevision,
      loading: status === 'loading',
      notFound: status === 'not-found',
      loadFailed: status === 'failed',
      retryStore,
      refreshProducts,
      setNotificationChannel,
    }),
    [store, catalogRevision, status, retryStore, refreshProducts, setNotificationChannel],
  )

  return <StoreContext.Provider value={value}>{children}</StoreContext.Provider>
}

// eslint-disable-next-line react-refresh/only-export-components
export function useStore() {
  const context = useContext(StoreContext)
  if (!context) throw new Error('useStore must be used inside StoreProvider')
  return context
}
