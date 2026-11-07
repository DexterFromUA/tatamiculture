import { optionPrice } from '../lib/format'
import { readJson, writeJson } from '../lib/storage'
import type { AuthSession, CartItem, CheckoutInput, Order, OrderItem, Product, Store, User } from '../types'
import { normalizePhone } from '../lib/phone'
import { DEMO_SMS_CODE, demoUser, products, shortLinks, stores } from './data'

const USERS_KEY = 'shop.store.users'
const ORDERS_KEY = 'shop.store.orders'
const TOKEN_PREFIX = 'mock.'

const pendingCodes = new Map<string, { registration?: { name: string; storeId: string } }>()

function wait(ms = 280) {
  return new Promise((resolve) => setTimeout(resolve, ms))
}

function seedUsers(): User[] {
  const existing = readJson<User[]>(USERS_KEY, [])
  if (existing.length > 0) return existing
  const seeded = [demoUser]
  writeJson(USERS_KEY, seeded)
  return seeded
}

function getUsers() {
  return seedUsers()
}

function saveUsers(users: User[]) {
  writeJson(USERS_KEY, users)
}

function getOrders(): Order[] {
  return readJson<Order[]>(ORDERS_KEY, [])
}

function saveOrders(orders: Order[]) {
  writeJson(ORDERS_KEY, orders)
}

function receiptCode() {
  return Math.random().toString(36).slice(2, 8).toUpperCase()
}

function toPublicUser(user: User): User {
  return { id: user.id, name: user.name, email: user.email, phone: user.phone, city: user.city }
}

function userFromToken(token: string) {
  if (!token.startsWith(TOKEN_PREFIX)) return null
  const id = token.slice(TOKEN_PREFIX.length)
  const user = getUsers().find((item) => item.id === id)
  return user ? toPublicUser(user) : null
}

export const api = {
  async getStoreBySlug(slug: string): Promise<Store | null> {
    await wait()
    return stores.find((store) => store.slug === slug) ?? null
  },

  async getProducts(storeId: string): Promise<Product[]> {
    await wait()
    return products.filter((product) => product.storeId === storeId && product.isActive)
  },

  async getProduct(storeId: string, productId: string): Promise<Product | null> {
    await wait()
    return products.find((product) => product.storeId === storeId && product.id === productId) ?? null
  },

  async requestPhoneCode(phone: string, registration?: { name: string; storeId: string }) {
    await wait()
    if (!registration && !getUsers().some(user => normalizePhone(user.phone) === phone)) {
      throw new Error('Could not send an SMS code. Check the number or try again later.')
    }
    pendingCodes.set(phone, { registration })
  },

  async verifyPhoneCode(phone: string, code: string): Promise<AuthSession> {
    await wait()
    const pending = pendingCodes.get(phone)
    if (!pending || code !== DEMO_SMS_CODE) throw new Error('The code is incorrect or has expired.')
    const users = getUsers()
    let user = users.find(entry => normalizePhone(entry.phone) === phone)
    if (!user && pending.registration) {
      user = { id: `user_${crypto.randomUUID().slice(0, 8)}`, name: pending.registration.name, email: '', phone }
      saveUsers([...users, user])
    }
    if (!user) throw new Error('The code is incorrect or has expired.')
    pendingCodes.delete(phone)
    return { token: `${TOKEN_PREFIX}${user.id}`, user: toPublicUser(user) }
  },

  async joinStore() {},

  async getCurrentUser(token: string): Promise<User> {
    await wait(150)
    const user = userFromToken(token)
    if (!user) throw new Error('Session expired')
    return user
  },

  async createOrder(input: {
    store: Store
    items: CartItem[]
    checkout: CheckoutInput
    token: string | null
    shortLinkId?: string
  }): Promise<Order> {
    await wait(500)
    if (input.items.length === 0) throw new Error('Cart is empty')

    let userId = 'guest'
    if (input.token) {
      const user = userFromToken(input.token)
      if (user) userId = user.id
    }

    const orderItems: OrderItem[] = input.items.map((item) => {
      const product = products.find((entry) => entry.id === item.productId)
      const option = product?.productOptions.find((entry) => entry.id === item.optionId)
      if (!product || !option) throw new Error('A product in the cart is no longer available')
      const finalUnitPrice = optionPrice(option)
      return {
        id: `oi_${crypto.randomUUID().slice(0, 8)}`,
        productId: product.id,
        productOptionId: option.id,
        productName: product.name,
        optionName: option.name,
        quantity: item.quantity,
        unitPrice: option.price,
        discountPercent: option.isDiscount ? option.discountPercent : 0,
        finalUnitPrice,
        lineTotal: finalUnitPrice * item.quantity,
        isPreOrder: option.isPreOrder,
      }
    })

    const order: Order = {
      id: `ord_${crypto.randomUUID().slice(0, 8)}`,
      userId,
      storeId: input.store.id,
      items: orderItems,
      totalPrice: orderItems.reduce((sum, item) => sum + item.lineTotal, 0),
      currency: input.store.currency,
      status: 'PAID',
      paymentStatus: 'MOCK_PAID',
      receiptCode: receiptCode(),
      customerName: input.checkout.name.trim(),
      customerEmail: input.checkout.email.trim(),
      customerPhone: input.checkout.phone.trim(),
      deliveryCity: input.checkout.city.trim(),
      deliveryAddress: input.checkout.address.trim(),
      note: input.checkout.note.trim(),
      createdAt: new Date().toISOString(),
      shortLinkId: input.shortLinkId,
    }

    saveOrders([order, ...getOrders()])
    return order
  },

  async getOrders(token: string, storeId: string, userId: string): Promise<Order[]> {
    await wait()
    const user = userFromToken(token)
    if (!user || user.id !== userId) throw new Error('Sign in to view orders')
    return getOrders().filter((order) => order.userId === user.id && order.storeId === storeId)
  },

  async claimGuestOrder(storeId: string, code: string, token: string): Promise<boolean> {
    await wait()
    const user = userFromToken(token)
    const phone = user && normalizePhone(user.phone)
    if (!user || !phone) return false

    const orders = getOrders()
    const order = orders.find(entry => entry.storeId === storeId && entry.receiptCode.toLowerCase() === code.trim().toLowerCase())
    if (!order) return false
    if (order.userId === user.id) return true
    if (order.userId !== 'guest' || normalizePhone(order.customerPhone) !== phone) return false

    saveOrders(orders.map(entry => entry.id === order.id ? { ...entry, userId: user.id } : entry))
    return true
  },

  async getOrderByReceipt(code: string): Promise<Order | null> {
    await wait()
    return getOrders().find((order) => order.receiptCode.toLowerCase() === code.toLowerCase()) ?? null
  },

  async getShortLink(code: string) {
    await wait()
    const link = shortLinks.find((item) => item.code.toLowerCase() === code.toLowerCase())
    if (!link) return null
    const store = stores.find((item) => item.id === link.storeId)
    const product = products.find((item) => item.id === link.productId)
    if (!store || !product) return null
    return { link, store, product }
  },
}
