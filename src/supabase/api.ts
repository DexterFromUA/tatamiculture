import { normalizePhone } from '../lib/phone'
import { supabaseRequest } from '../lib/supabase'
import type { AuthSession, CartItem, CatalogCategory, CheckoutInput, Order, OrderItem, Product, ProductOption, ShortLink, Store, User } from '../types'

type Row = Record<string, unknown>

const money = (amount: unknown) => Number(amount ?? 0) / 100
const text = (value: unknown) => String(value ?? '')
const productFields = '*,categories!products_category_id_fkey(*),product_categories(categories(*)),product_variants(*),product_images(*)'

function mapStore(row: Row): Store {
  return {
    id: text(row.id), slug: text(row.slug), name: text(row.name), description: text(row.description),
    contactEmail: text(row.contact_email), contactPhone: text(row.contact_phone),
    contactCity: text(row.contact_city), currency: text(row.currency), primaryColor: text(row.primary_color),
  }
}

function mapProduct(row: Row): Product {
  const category = row.categories as CatalogCategory | null
  const assignments = row.product_categories as Array<{ categories: CatalogCategory | null }> | undefined
  const images = (row.product_images as Row[] | undefined) ?? []
  const variants = (row.product_variants as Row[] | undefined) ?? []
  return {
    id: text(row.id), storeId: text(row.store_id), name: text(row.name), description: text(row.description), createdAt: text(row.created_at),
    name_uk: text(row.name_uk), name_en: text(row.name_en),
    description_uk: text(row.description_uk), description_en: text(row.description_en),
    sizeGuide: text(row.size_guide), sizeGuideImageUrl: text(row.size_guide_image_url), composition: text(row.composition), careInstructions: text(row.care_instructions),
    primaryCategory: category ?? undefined, isActive: Boolean(row.is_active),
    isNew: row.is_new === true,
    categories: assignments?.flatMap(link => link.categories ? [link.categories] : []),
    imgUrls: images.sort((a, b) => Number(a.position) - Number(b.position)).map((image) => text(image.public_url)),
    productOptions: variants.sort((a, b) => Number(a.position) - Number(b.position)).map((variant): ProductOption => {
      const price = money(variant.price)
      const compareAt = variant.compare_at_price === null ? null : money(variant.compare_at_price)
      const discountPercent = compareAt && compareAt > price ? Math.round((1 - price / compareAt) * 100) : 0
      const details = {
        id: text(variant.id), name: text(variant.name), price,
        isDiscount: discountPercent > 0, discountPercent,
      }
      return variant.is_preorder
        ? { ...details, isPreOrder: true, isLimited: false, quantity: null }
        : { ...details, isPreOrder: false, isLimited: true, quantity: Number(variant.stock_quantity ?? 0) }
    }),
  }
}

function mapUser(user: Row, profile?: Row | null): User {
  const metadata = (user.user_metadata as Row | undefined) ?? {}
  return {
    id: text(user.id), name: text(profile?.name ?? metadata.name), email: text(user.email),
    phone: (user.phone ? normalizePhone('+' + text(user.phone).replace(/^\+/, '')) : null) ?? text(profile?.phone || metadata.phone), city: profile?.city ? text(profile.city) : undefined,
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
    reservedInProfile: row.reserved_in_profile === true,
    paymentTestMode: row.payment_test_mode === true,
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
    const rows = await supabaseRequest<Row[]>(`/rest/v1/products?store_id=eq.${encodeURIComponent(storeId)}&is_active=eq.true&select=${productFields}`)
    return rows.map(mapProduct)
  },

  async getProduct(storeId: string, productId: string): Promise<Product | null> {
    const rows = await supabaseRequest<Row[]>(`/rest/v1/products?id=eq.${encodeURIComponent(productId)}&store_id=eq.${encodeURIComponent(storeId)}&is_active=eq.true&select=${productFields}`)
    return rows[0] ? mapProduct(rows[0]) : null
  },

  async requestPhoneCode(phone: string, registration?: { name: string; storeId: string }) {
    await supabaseRequest('/auth/v1/otp', {
      method: 'POST',
      body: JSON.stringify({
        phone, channel: 'sms', create_user: Boolean(registration),
        ...(registration && { data: { name: registration.name, phone, registration_store_id: registration.storeId } }),
      }),
    })
  },

  async verifyPhoneCode(phone: string, code: string, storeId: string): Promise<AuthSession> {
    const session = await supabaseRequest<Row>('/auth/v1/verify', {
      method: 'POST', body: JSON.stringify({ phone, token: code, type: 'sms' }),
    })
    const token = text(session.access_token)
    const user = session.user as Row
    if (!token || !user?.id) throw new Error('Could not finish signing in. Try again.')
    const metadata = user.user_metadata as Row | undefined
    // The code is already consumed. A profile read failure should not discard the valid session.
    const profile = await profileFor(user, token).catch(() => null)
    return {
      token,
      refreshToken: typeof session.refresh_token === 'string' ? session.refresh_token : undefined,
      user: mapUser(user, profile),
      registrationStoreId: metadata?.registration_store_id === storeId ? storeId : undefined,
    }
  },

  async joinStore(storeId: string, session: AuthSession) {
    await supabaseRequest('/rest/v1/store_customers?on_conflict=store_id,user_id', {
      method: 'POST', token: session.token,
      headers: { Prefer: 'resolution=ignore-duplicates' },
      body: JSON.stringify({ store_id: storeId, user_id: session.user.id }),
    })
  },

  async getCurrentUser(token: string): Promise<User> {
    const user = await supabaseRequest<Row>('/auth/v1/user', { token })
    return mapUser(user, await profileFor(user, token).catch(() => null))
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

  async getOrders(token: string, storeId: string, userId: string): Promise<Order[]> {
    const rows = await supabaseRequest<Row[]>(`/rest/v1/orders?store_id=eq.${encodeURIComponent(storeId)}&user_id=eq.${encodeURIComponent(userId)}&select=*,order_items(*)&order=created_at.desc,id.desc`, { token })
    return rows.map(mapOrder)
  },

  async getLastDeliveryAddress(token: string, storeId: string, userId: string, signal: AbortSignal) {
    const query = new URLSearchParams({
      store_id: `eq.${storeId}`,
      user_id: `eq.${userId}`,
      delivery_city: 'neq.',
      delivery_address: 'neq.',
      select: 'delivery_city,delivery_address,delivery_city_ref,delivery_address_ref,delivery_service_type',
      order: 'created_at.desc,id.desc',
      limit: '1',
    })
    const [row] = await supabaseRequest<Row[]>(`/rest/v1/orders?${query}`, { token, signal, cache: 'no-store' })
    if (!row) return null
    const city = text(row.delivery_city).trim()
    const address = text(row.delivery_address).trim()
    if (!city || !address) return null
    return {
      city,
      address,
      cityRef: text(row.delivery_city_ref) || null,
      addressRef: text(row.delivery_address_ref) || null,
      deliveryServiceType: row.delivery_service_type === 'WarehousePostomat'
        || (!row.delivery_service_type && /поштомат|postomat/i.test(address))
        ? 'WarehousePostomat' as const : 'WarehouseWarehouse' as const,
    }
  },

  async claimGuestOrder(storeId: string, receiptCode: string, token: string): Promise<boolean> {
    return supabaseRequest<boolean>('/rest/v1/rpc/claim_guest_order', {
      method: 'POST', token,
      body: JSON.stringify({ p_store_id: storeId, p_receipt_code: receiptCode }),
    })
  },

  async getOrderByReceipt(code: string): Promise<Order | null> {
    const row = await supabaseRequest<Row | null>('/rest/v1/rpc/get_order_receipt', {
      method: 'POST', body: JSON.stringify({ p_receipt_code: code }),
    })
    return row ? mapOrder(row) : null
  },

  async getOnlineCheckoutStatus(code: string) {
    return supabaseRequest<'PENDING' | 'FAILED' | 'PAID' | null>('/rest/v1/rpc/get_online_checkout_status', {
      method: 'POST', body: JSON.stringify({ p_receipt_code: code }),
    })
  },

  async getShortLink(code: string) {
    const links = await supabaseRequest<Row[]>(`/rest/v1/short_links?code=eq.${encodeURIComponent(code)}&select=*`)
    const link = links[0]
    if (!link) return null
    const [stores, products] = await Promise.all([
      supabaseRequest<Row[]>(`/rest/v1/stores?id=eq.${encodeURIComponent(text(link.store_id))}&select=*`),
      supabaseRequest<Row[]>(`/rest/v1/products?id=eq.${encodeURIComponent(text(link.product_id))}&store_id=eq.${encodeURIComponent(text(link.store_id))}&is_active=eq.true&select=${productFields}`),
    ])
    const store = stores[0] ? mapStore(stores[0]) : null
    const product = products[0] ? mapProduct(products[0]) : null
    if (!store || !product) return null
    return { link: { id: text(link.id), code: text(link.code), storeId: text(link.store_id), productId: text(link.product_id) } satisfies ShortLink, store, product }
  },
}
