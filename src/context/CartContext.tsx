import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { readJson, removeKey, writeJson } from '../lib/storage'
import type { CartItem, Order } from '../types'
import { useStore } from './StoreContext'

type CartContextValue = {
  items: CartItem[]
  count: number
  addItem: (productId: string, optionId: string, quantity?: number) => void
  setQuantity: (productId: string, optionId: string, quantity: number) => void
  removeItem: (productId: string, optionId: string) => void
  clear: () => void
  rememberOnlineCheckout: (receiptCode?: string) => void
  completeOnlineCheckout: (order: Order) => void
}

const CartContext = createContext<CartContextValue | null>(null)

function cartKey(storeId: string) {
  return `shop.store.cart.${storeId}`
}

function checkoutKey(storeId: string, receiptCode: string) {
  return `${cartKey(storeId)}.checkout.${receiptCode}`
}

export function CartProvider({ children }: { children: ReactNode }) {
  const { store } = useStore()
  const storeId = store?.id
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

  const rememberOnlineCheckout = useCallback((receiptCode?: string) => {
    if (!storeId || !receiptCode) return
    try {
      writeJson(checkoutKey(storeId, receiptCode), true)
    } catch {
      // The buyer can still continue to payment when storage is unavailable.
    }
  }, [storeId])

  const completeOnlineCheckout = useCallback((order: Order) => {
    if (!ready || !storeId || order.storeId !== storeId || order.paymentMethod !== 'ONLINE' || order.paymentStatus !== 'PAID') return
    const key = checkoutKey(storeId, order.receiptCode)
    if (readJson<boolean>(key, false) !== true) return
    removeKey(key)

    const paidQuantities = new Map<string, number>()
    for (const item of order.items) {
      paidQuantities.set(item.productOptionId, (paidQuantities.get(item.productOptionId) ?? 0) + item.quantity)
    }
    setItems(current => current
      .map(item => ({ ...item, quantity: item.quantity - (paidQuantities.get(item.optionId) ?? 0) }))
      .filter(item => item.quantity > 0))
  }, [ready, storeId])

  const value = useMemo(
    () => ({
      items,
      count: items.reduce((sum, item) => sum + item.quantity, 0),
      addItem,
      setQuantity,
      removeItem,
      clear,
      rememberOnlineCheckout,
      completeOnlineCheckout,
    }),
    [items, rememberOnlineCheckout, completeOnlineCheckout],
  )

  return <CartContext.Provider value={value}>{children}</CartContext.Provider>
}

export function useCart() {
  const context = useContext(CartContext)
  if (!context) throw new Error('useCart must be used inside CartProvider')
  return context
}
