import { createContext, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { readJson, writeJson } from '../lib/storage'
import type { CartItem } from '../types'
import { useStore } from './StoreContext'

type CartContextValue = {
  items: CartItem[]
  count: number
  addItem: (productId: string, optionId: string, quantity?: number) => void
  setQuantity: (productId: string, optionId: string, quantity: number) => void
  removeItem: (productId: string, optionId: string) => void
  clear: () => void
}

const CartContext = createContext<CartContextValue | null>(null)

function cartKey(storeId: string) {
  return `shop.store.cart.${storeId}`
}

export function CartProvider({ children }: { children: ReactNode }) {
  const { store } = useStore()
  const [items, setItems] = useState<CartItem[]>([])
  const [ready, setReady] = useState(false)

  useEffect(() => {
    if (!store) {
      setItems([])
      setReady(false)
      return
    }
    setItems(readJson<CartItem[]>(cartKey(store.id), []))
    setReady(true)
  }, [store])

  useEffect(() => {
    if (!store || !ready) return
    writeJson(cartKey(store.id), items)
  }, [items, store, ready])

  const addItem = (productId: string, optionId: string, quantity = 1) => {
    setItems((current) => {
      const existing = current.find((item) => item.productId === productId && item.optionId === optionId)
      if (!existing) return [...current, { productId, optionId, quantity }]
      return current.map((item) =>
        item.productId === productId && item.optionId === optionId
          ? { ...item, quantity: item.quantity + quantity }
          : item,
      )
    })
  }

  const setQuantity = (productId: string, optionId: string, quantity: number) => {
    setItems((current) =>
      current
        .map((item) =>
          item.productId === productId && item.optionId === optionId ? { ...item, quantity } : item,
        )
        .filter((item) => item.quantity > 0),
    )
  }

  const removeItem = (productId: string, optionId: string) => {
    setItems((current) => current.filter((item) => !(item.productId === productId && item.optionId === optionId)))
  }

  const clear = () => setItems([])

  const value = useMemo(
    () => ({
      items,
      count: items.reduce((sum, item) => sum + item.quantity, 0),
      addItem,
      setQuantity,
      removeItem,
      clear,
    }),
    [items],
  )

  return <CartContext.Provider value={value}>{children}</CartContext.Provider>
}

export function useCart() {
  const context = useContext(CartContext)
  if (!context) throw new Error('useCart must be used inside CartProvider')
  return context
}
