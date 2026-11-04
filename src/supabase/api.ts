import { supabaseRequest } from '../lib/supabase'
import type { AuthSession, CartItem, CheckoutInput, Order, OrderItem, Product, ProductOption, ShortLink, Store, User } from '../types'

type Row = Record<string, unknown>

const money = (amount: unknown) => Number(amount ?? 0) / 100
const text = (value: unknown) => String(value ?? '')

function mapStore(row: Row): Store {
  return {
    id: text(row.id), slug: text(row.slug), name: text(row.name), description: text(row.description),
    contactEmail: text(row.contact_email), contactPhone: text(row.contact_phone),
    contactCity: text(row.contact_city), currency: text(row.currency), primaryColor: text(row.primary_color),
  }
}

function mapProduct(row: Row): Product {
  const category = row.categories as Row | null
  const images = (row.product_images as Row[] | undefined) ?? []
  const variants = (row.product_variants as Row[] | undefined) ?? []
  return {
    id: text(row.id), storeId: text(row.store_id), name: text(row.name), description: text(row.description),
    sizeGuide: text(row.size_guide), composition: text(row.composition), careInstructions: text(row.care_instructions),
    category: text(category?.name ?? 'Uncategorized'), isActive: Boolean(row.is_active),
    imgUrls: images.sort((a, b) => Number(a.position) - Number(b.position)).map((image) => text(image.public_url)),
    productOptions: variants.sort((a, b) => Number(a.position) - Number(b.position)).map((variant): ProductOption => {
      const price = money(variant.price)
      const compareAt = variant.compare_at_price === null ? null : money(variant.compare_at_price)
      const discountPercent = compareAt && compareAt > price ? Math.round((1 - price / compareAt) * 100) : 0
      return {
        id: text(variant.id), name: text(variant.name), price, isPreOrder: Boolean(variant.is_preorder),
        isDiscount: discountPercent > 0, discountPercent, isLimited: true, quantity: Number(variant.stock_quantity ?? 0),
      }
    }),
  }
}

function mapUser(user: Row, profile?: Row | null): User {
  const metadata = (user.user_metadata as Row | undefined) ?? {}
  return {
    id: text(user.id), name: text(profile?.name ?? metadata.name), email: text(user.email),
    phone: text(profile?.phone ?? metadata.phone), city: profile?.city ? text(profile.city) : undefined,
  }
}

function mapOrder(row: Row): Order {
  const items = ((row.order_items ?? row.items) as Row[] | undefined) ?? []
  return {
    id: text(row.id), userId: row.user_id ? text(row.user_id) : 'guest', storeId: text(row.store_id),
    items: items.map((item): OrderItem => {
      const unitPrice = money(item.unit_price)
      const compareAt = item.compare_at_price === null ? null : money(item.compare_at_price)
      const discountPercent = compareAt && compareAt > unitPrice ? Math.round((1 - unitPrice / compareAt) * 100) : 0
      return {
        id: text(item.id), productId: text(item.product_id), productOptionId: text(item.variant_id),
        productName: text(item.product_name), optionName: text(item.variant_name), quantity: Number(item.quantity),
        unitPrice: compareAt ?? unitPrice, discountPercent, finalUnitPrice: unitPrice,
        lineTotal: money(item.line_total), isPreOrder: Boolean(item.is_preorder),
      }
    }),
    totalPrice: money(row.total_price), currency: text(row.currency), status: text(row.status) as Order['status'],
    paymentStatus: text(row.payment_status) as Order['paymentStatus'], receiptCode: text(row.receipt_code),
    customerName: text(row.customer_name), customerEmail: text(row.customer_email), customerPhone: text(row.customer_phone),
    deliveryCity: text(row.delivery_city), deliveryAddress: text(row.delivery_address), note: text(row.note),
    createdAt: text(row.created_at),
    paymentMethod: row.payment_method === 'ONLINE' ? 'ONLINE' : 'CASH_ON_DELIVERY',
    novaPoshtaTtn: row.nova_poshta_ttn ? text(row.nova_poshta_ttn) : undefined,
    novaPoshtaStatus: row.nova_poshta_status ? text(row.nova_poshta_status) : undefined,
  }
}

async function profileFor(user: Row, token: string) {
  const rows = await supabaseRequest<Row[]>(`/rest/v1/profiles?id=eq.${encodeURIComponent(text(user.id))}&select=*`, { token })
  return rows[0] ?? null
}

export const supabaseApi = {
  async getStoreBySlug(slug: string): Promise<Store | null> {
    const rows = await supabaseRequest<Row[]>(`/rest/v1/stores?slug=eq.${encodeURIComponent(slug)}&select=*`)
    return rows[0] ? mapStore(rows[0]) : null
  },

  async getProducts(storeId: string): Promise<Product[]> {
    const rows = await supabaseRequest<Row[]>(`/rest/v1/products?store_id=eq.${encodeURIComponent(storeId)}&is_active=eq.true&select=*,categories(name),product_variants(*),product_images(*)`)
    return rows.map(mapProduct)
  },

  async getProduct(storeId: string, productId: string): Promise<Product | null> {
    const rows = await supabaseRequest<Row[]>(`/rest/v1/products?id=eq.${encodeURIComponent(productId)}&store_id=eq.${encodeURIComponent(storeId)}&is_active=eq.true&select=*,categories(name),product_variants(*),product_images(*)`)
    return rows[0] ? mapProduct(rows[0]) : null
  },

  async login(email: string, password: string): Promise<AuthSession> {
    const session = await supabaseRequest<Row>('/auth/v1/token?grant_type=password', {
      method: 'POST', body: JSON.stringify({ email, password }),
    })
    const token = text(session.access_token)
    const user = session.user as Row
    return { token, user: mapUser(user, await profileFor(user, token)) }
  },

  async register(input: { name: string; email: string; phone: string; password: string }): Promise<AuthSession> {
    const result = await supabaseRequest<Row>('/auth/v1/signup', {
      method: 'POST', body: JSON.stringify({
        email: input.email, password: input.password,
        data: { name: input.name, phone: input.phone },
      }),
    })
    const token = text(result.access_token)
    if (!token) throw new Error('Confirm your email, then sign in to continue')
    const user = result.user as Row
    return { token, user: mapUser(user, await profileFor(user, token)) }
  },

  async getCurrentUser(token: string): Promise<User> {
    const user = await supabaseRequest<Row>('/auth/v1/user', { token })
    return mapUser(user, await profileFor(user, token))
  },

  async createOrder(input: { store: Store; items: CartItem[]; checkout: CheckoutInput; token: string | null; shortLinkId?: string }): Promise<Order> {
    if (input.items.length === 0) throw new Error('Cart is empty')
    const row = await supabaseRequest<Row>('/rest/v1/rpc/create_store_order', {
      method: 'POST', token: input.token,
      body: JSON.stringify({
        p_store_id: input.store.id,
        p_items: input.items.map((item) => ({ variantId: item.optionId, quantity: item.quantity })),
        p_customer_name: input.checkout.name, p_customer_email: input.checkout.email,
        p_customer_phone: input.checkout.phone, p_delivery_city: input.checkout.city,
        p_delivery_address: input.checkout.address, p_note: input.checkout.note,
        p_delivery_city_ref: input.checkout.cityRef ?? null,
        p_delivery_address_ref: input.checkout.addressRef ?? null,
        p_delivery_service_type: input.checkout.deliveryServiceType ?? null,
      }),
    })
    return mapOrder(row)
  },

  async getOrders(token: string, storeId: string): Promise<Order[]> {
    const rows = await supabaseRequest<Row[]>(`/rest/v1/orders?store_id=eq.${encodeURIComponent(storeId)}&select=*,order_items(*)&order=created_at.desc`, { token })
    return rows.map(mapOrder)
  },

  async getOrderByReceipt(code: string): Promise<Order | null> {
    const row = await supabaseRequest<Row | null>('/rest/v1/rpc/get_order_receipt', {
      method: 'POST', body: JSON.stringify({ p_receipt_code: code }),
    })
    return row ? mapOrder(row) : null
  },

  async getShortLink(code: string) {
    const links = await supabaseRequest<Row[]>(`/rest/v1/short_links?code=eq.${encodeURIComponent(code)}&select=*`)
    const link = links[0]
    if (!link) return null
    const [stores, products] = await Promise.all([
      supabaseRequest<Row[]>(`/rest/v1/stores?id=eq.${encodeURIComponent(text(link.store_id))}&select=*`),
      supabaseRequest<Row[]>(`/rest/v1/products?id=eq.${encodeURIComponent(text(link.product_id))}&store_id=eq.${encodeURIComponent(text(link.store_id))}&is_active=eq.true&select=*,categories(name),product_variants(*),product_images(*)`),
    ])
    const store = stores[0] ? mapStore(stores[0]) : null
    const product = products[0] ? mapProduct(products[0]) : null
    if (!store || !product) return null
    return { link: { id: text(link.id), code: text(link.code), storeId: text(link.store_id), productId: text(link.product_id) } satisfies ShortLink, store, product }
  },
}
