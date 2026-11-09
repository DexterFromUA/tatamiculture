import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react'
import { useLocation } from 'react-router-dom'
import { api } from '../lib/api'
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
  completeOnlineCheckout: (order: Order, fromPaymentProvider?: boolean) => void
}

type CheckoutMarker = true | number | { settledAt: number }

const CartContext = createContext<CartContextValue | null>(null)

function cartKey(storeId: string) {
  return `shop.store.cart.${storeId}`
}

function checkoutPrefix(storeId: string) {
  return `${cartKey(storeId)}.checkout.`
}

function pendingCheckouts(storeId: string) {
  const prefix = checkoutPrefix(storeId)
  try {
    return Object.keys(localStorage)
      .filter(key => key.startsWith(prefix))
      .filter(key => {
        const marker = readJson<CheckoutMarker | null>(key, null)
        if (marker && typeof marker === 'object') {
          if (Date.now() - marker.settledAt > 24 * 60 * 60 * 1000) removeKey(key)
          return false
        }
        return Boolean(marker)
      })
      .map(key => key.slice(prefix.length))
  } catch {
    return []
  }
}

export function CartProvider({ children }: { children: ReactNode }) {
  const { store, products } = useStore()
  const { pathname } = useLocation()
  const storeId = store?.id
  const [storedItems, setItems] = useState<CartItem[]>([])
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
    writeJson(cartKey(store.id), storedItems)
  }, [storedItems, store, ready])

  useEffect(() => {
    if (!storeId || !ready) return
    const syncCart = (event: StorageEvent) => {
      if (event.key === cartKey(storeId)) setItems(readJson<CartItem[]>(cartKey(storeId), []))
    }
    window.addEventListener('storage', syncCart)
    return () => window.removeEventListener('storage', syncCart)
  }, [storeId, ready])

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
      writeJson(checkoutPrefix(storeId) + receiptCode, Date.now())
    } catch {
      // The buyer can still continue to payment when storage is unavailable.
    }
  }, [storeId])

  const completeOnlineCheckout = useCallback((order: Order, fromPaymentProvider = false) => {
    if (!ready || !storeId || order.storeId !== storeId || order.paymentMethod !== 'ONLINE' || order.paymentStatus !== 'PAID') return
    const key = checkoutPrefix(storeId) + order.receiptCode
    const marker = readJson<CheckoutMarker | null>(key, null)
    if (marker && typeof marker === 'object') return

    const paidQuantities = new Map<string, number>()
    for (const item of order.items) {
      paidQuantities.set(item.productOptionId, (paidQuantities.get(item.productOptionId) ?? 0) + item.quantity)
    }
    const current = readJson<CartItem[]>(cartKey(storeId), [])
    if (!marker) {
      // Some payment flows reopen the shop without the original checkout marker.
      // Only recover a recent bank return if the entire cart matches that order.
      const orderAge = Date.now() - Date.parse(order.createdAt)
      const matchesOrder = current.length > 0 && current.length === paidQuantities.size
        && current.every(item => paidQuantities.get(item.optionId) === item.quantity)
      if (!fromPaymentProvider || !(orderAge >= 0 && orderAge < 2 * 60 * 60 * 1000) || !matchesOrder) return
    }
    const next = current
      .map(item => ({ ...item, quantity: item.quantity - (paidQuantities.get(item.optionId) ?? 0) }))
      .filter(item => item.quantity > 0)
    writeJson(cartKey(storeId), next)
    writeJson(key, { settledAt: Date.now() })
    setItems(next)
  }, [ready, storeId])

  useEffect(() => {
    if (!storeId || !ready || pathname.startsWith('/receipt/')) return
    let active = true
    let checking = false
    let timer: number | undefined
    let retries = 10

    const check = async () => {
      if (!active || checking || document.visibilityState === 'hidden') return
      checking = true
      const codes = pendingCheckouts(storeId)
      await Promise.allSettled(codes.map(async code => {
        const key = checkoutPrefix(storeId) + code
        const startedAt = readJson<boolean | number>(key, false)
        if (typeof startedAt === 'number' && Date.now() - startedAt > 7 * 24 * 60 * 60 * 1000) {
          removeKey(key)
          return
        }
        const order = await api.getOrderByReceipt(code)
        if (!active || !order || order.storeId !== storeId) return
        completeOnlineCheckout(order)
        if (order.paymentStatus === 'REFUNDED') removeKey(key)
      }))
      checking = false
      if (active && retries > 0 && pendingCheckouts(storeId).length > 0) {
        retries -= 1
        timer = window.setTimeout(() => void check(), 3000)
      }
    }

    const resume = () => {
      window.clearTimeout(timer)
      retries = 10
      void check()
    }
    resume()
    window.addEventListener('focus', resume)
    window.addEventListener('pageshow', resume)
    document.addEventListener('visibilitychange', resume)
    return () => {
      active = false
      window.clearTimeout(timer)
      window.removeEventListener('focus', resume)
      window.removeEventListener('pageshow', resume)
      document.removeEventListener('visibilitychange', resume)
    }
  }, [storeId, ready, pathname, completeOnlineCheckout])

  const value = useMemo(
    () => {
      const items = storedItems.filter(item => {
        const product = products.find(product => product.id === item.productId)
        return product?.productOptions.some(option => option.id === item.optionId)
      })
      return {
        items,
        count: items.reduce((sum, item) => sum + item.quantity, 0),
        addItem,
        setQuantity,
        removeItem,
        clear,
        rememberOnlineCheckout,
        completeOnlineCheckout,
      }
    },
    [storedItems, products, rememberOnlineCheckout, completeOnlineCheckout],
  )

  return <CartContext.Provider value={value}>{children}</CartContext.Provider>
}

export function useCart() {
  const context = useContext(CartContext)
  if (!context) throw new Error('useCart must be used inside CartProvider')
  return context
}
