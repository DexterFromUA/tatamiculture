import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { api } from '../lib/api'
import type { Product, Store } from '../types'

type StoreContextValue = {
  store: Store | null
  products: Product[]
  loading: boolean
  notFound: boolean
}

const StoreContext = createContext<StoreContextValue | null>(null)

export function StoreProvider({ slug, children }: { slug: string | undefined; children: ReactNode }) {
  const [store, setStore] = useState<Store | null>(null)
  const [products, setProducts] = useState<Product[]>([])
  const [loading, setLoading] = useState(true)
  const [notFound, setNotFound] = useState(false)

  useEffect(() => {
    let cancelled = false

    const load = async () => {
      if (!slug) {
        setNotFound(true)
        setLoading(false)
        return
      }

      setLoading(true)
      setNotFound(false)

      const nextStore = await api.getStoreBySlug(slug)
      if (cancelled) return

      if (!nextStore) {
        setStore(null)
        setProducts([])
        setNotFound(true)
        setLoading(false)
        return
      }

      const nextProducts = await api.getProducts(nextStore.id)
      if (cancelled) return

      setStore(nextStore)
      setProducts(nextProducts)
      setLoading(false)
    }

    void load()
    return () => {
      cancelled = true
    }
  }, [slug])

  const value = useMemo(
    () => ({ store, products, loading, notFound }),
    [store, products, loading, notFound],
  )

  return <StoreContext.Provider value={value}>{children}</StoreContext.Provider>
}

export function useStore() {
  const context = useContext(StoreContext)
  if (!context) throw new Error('useStore must be used inside StoreProvider')
  return context
}
