import { stableOrderId, pendingCodKey } from '../lib/orderRequestId'
import { agreementVersion } from '../content/agreement'
import { normalizePhone, normalizeUkrainianPhone } from '../lib/phone'
import { catalogOffer } from '../lib/catalogPricing'
import { fetchAll } from '../lib/crm'
import { getSizeGuideImageUrls } from '../lib/productText'
import { supabaseRequest } from '../lib/supabase'
import { discountedCategory, newArrivalsCategory, type CatalogCursor, type CatalogFilters, type CatalogMetadata, type CatalogPage } from '../lib/storefrontCatalog'
import type { AuthSession, CartItem, CatalogCategory, CheckoutInput, Order, OrderItem, Product, ProductOption, Store, User } from '../types'

type Row = Record<string, unknown>

const money = (amount: unknown) => Number(amount ?? 0) / 100
const text = (value: unknown) => String(value ?? '')
const productIdPattern = /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/i
const productFields = '*,categories!products_category_id_fkey(*),product_categories(categories(*)),product_variants(*),product_images(*)'

function mapStore(row: Row): Store {
  return {
    id: text(row.id), name: text(row.name), currency: text(row.currency),
    smsNotificationsEnabled: row.sms_notifications_enabled !== false,
  }
}

function mapProduct(row: Row): Product {
  const category = row.categories as CatalogCategory | null
  const assignments = row.product_categories as Array<{ categories: CatalogCategory | null }> | undefined
  const images = (row.product_images as Row[] | undefined) ?? []
  const variants = (row.product_variants as Row[] | undefined) ?? []
  return {
    id: text(row.id), storeId: text(row.store_id), name: text(row.name), description: text(row.description),
    createdAt: text(row.created_at), updatedAt: text(row.updated_at),
    name_uk: text(row.name_uk), name_en: text(row.name_en),
    description_uk: text(row.description_uk), description_en: text(row.description_en),
    sizeGuide: text(row.size_guide), composition: text(row.composition), careInstructions: text(row.care_instructions),
    sizeGuideImageUrls: getSizeGuideImageUrls(row.size_guide_image_url, row.size_guide_extra_image_urls),
    sizeGuideEn: text(row.size_guide_en),
    compositionEn: text(row.composition_en), careInstructionsEn: text(row.care_instructions_en),
    primaryCategory: category ?? undefined, isActive: Boolean(row.is_active),
    isNew: row.is_new === true,
    categories: assignments?.flatMap(link => link.categories ? [link.categories] : []),
    imgUrls: images.sort((a, b) => Number(a.position) - Number(b.position)).map((image) => text(image.public_url)),
    productOptions: variants.sort((a, b) => Number(a.position) - Number(b.position)).map((variant): ProductOption => {
      const details = catalogOffer({
        discount_percent: row.discount_percent == null ? null : Number(row.discount_percent),
        stack_customer_discount: row.stack_customer_discount === true,
      }, {
        price: Number(variant.price ?? 0), compare_at_price: Number(variant.compare_at_price ?? 0),
        discount_percent: variant.discount_percent == null ? null : Number(variant.discount_percent),
        stack_customer_discount: variant.stack_customer_discount === true,
      })
      return {
        ...details, id: text(variant.id), name: text(variant.name), sku: text(variant.sku),
        isPreOrder: Boolean(variant.is_preorder), isLimited: true, quantity: Number(variant.stock_quantity ?? 0),
        allowOutOfStock: variant.allow_out_of_stock === true,
      }
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
  async getStore(signal?: AbortSignal): Promise<Store | null> {
    const rows = await supabaseRequest<Row[]>('/rest/v1/shop_settings?select=id,name,currency,sms_notifications_enabled', { signal, cache: 'no-store' })
    return rows[0] ? mapStore(rows[0]) : null
  },

  setSmsNotificationsEnabled(storeId: string, enabled: boolean, token: string) {
    return supabaseRequest<boolean>('/rest/v1/rpc/set_sms_notifications_enabled', {
      method: 'POST', token, signal: AbortSignal.timeout(15000),
      body: JSON.stringify({ p_store_id: storeId, p_enabled: enabled }),
    })
  },

  async getProducts(storeId: string, token: string, signal = AbortSignal.timeout(20000)): Promise<Product[]> {
    const path = `/rest/v1/products?store_id=eq.${encodeURIComponent(storeId)}&is_active=eq.true&select=${productFields}`
    const rows = await fetchAll<Row>(`${path}&order=id`, token, signal)
    return rows.map(mapProduct)
  },

  async getProduct(storeId: string, productId: string, signal?: AbortSignal): Promise<Product | null> {
    if (!productIdPattern.test(productId)) return null
    const rows = await supabaseRequest<Row[]>(`/rest/v1/products?id=eq.${productId}&store_id=eq.${encodeURIComponent(storeId)}&is_active=eq.true&select=${productFields}`, { signal, cache: 'no-store' })
    return rows[0] ? mapProduct(rows[0]) : null
  },

  async getProductsByIds(storeId: string, productIds: string[], signal?: AbortSignal): Promise<Product[]> {
    const ids = productIds.filter(id => productIdPattern.test(id))
    const products: Product[] = []
    for (let offset = 0; offset < ids.length; offset += 50) {
      const batch = ids.slice(offset, offset + 50).join(',')
      const rows = await supabaseRequest<Row[]>(`/rest/v1/products?id=in.(${batch})&store_id=eq.${encodeURIComponent(storeId)}&is_active=eq.true&select=${productFields}`, { signal, cache: 'no-store' })
      products.push(...rows.map(mapProduct))
    }
    return products
  },

  async getCatalogPage(storeId: string, filters: CatalogFilters, cursor: CatalogCursor | null, signal: AbortSignal): Promise<CatalogPage> {
    const { category, subcategory, search, size, sort } = filters
    const collection = category === newArrivalsCategory ? 'new' : category === discountedCategory ? 'sale' : 'all'
    const result = await supabaseRequest<Omit<CatalogPage, 'rows'> & { rows: Row[] }>('/rest/v1/rpc/storefront_catalog_page', {
      method: 'POST', signal, body: JSON.stringify({
        p_store_id: storeId, p_search: search, p_size: size, p_sort: sort,
        p_collection: collection, p_category_id: collection === 'all' ? (subcategory || category || null) : null,
        p_after_price: cursor?.price, p_after_updated_at: cursor?.updatedAt, p_after_id: cursor?.id,
      }),
    })
    return { ...result, rows: result.rows.map(mapProduct) }
  },

  getCatalogMetadata(storeId: string, signal: AbortSignal) {
    return supabaseRequest<CatalogMetadata>('/rest/v1/rpc/storefront_catalog_metadata', {
      method: 'POST', signal, body: JSON.stringify({ p_store_id: storeId }),
    })
  },

  async getRelatedProducts(storeId: string, productId: string, signal: AbortSignal) {
    const rows = await supabaseRequest<Row[]>('/rest/v1/rpc/storefront_related_products', {
      method: 'POST', signal, body: JSON.stringify({ p_store_id: storeId, p_product_id: productId }),
    })
    return rows.map(mapProduct)
  },

  async requestPhoneCode(phone: string, registration?: { name: string; storeId: string; acceptedTerms: boolean }) {
    if (registration && !registration.acceptedTerms) throw new Error('Accept the user agreement to create an account.')
    const number = normalizeUkrainianPhone(phone)
    if (!number) throw new Error('Enter 9 digits after +380.')
    await supabaseRequest('/auth/v1/otp', {
      method: 'POST',
      body: JSON.stringify({
        phone: number, channel: 'sms', create_user: Boolean(registration),
        ...(registration && { data: { name: registration.name, phone: number, registration_store_id: registration.storeId, terms_accepted: true, terms_version: agreementVersion } }),
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

  async createOrder(input: { store: Store; items: CartItem[]; checkout: CheckoutInput; token: string | null }): Promise<Order> {
    if (input.items.length === 0) throw new Error('Cart is empty')
    const order = {
      p_store_id: input.store.id,
      p_expected_discount_percent: input.checkout.expectedDiscountPercent ?? null,
      p_expected_total: input.checkout.expectedTotal ?? null,
      p_items: input.items.map((item) => ({ variantId: item.optionId, quantity: item.quantity })),
      p_customer_name: input.checkout.name, p_customer_email: input.checkout.email,
      p_customer_phone: input.checkout.phone, p_delivery_city: input.checkout.city,
      p_delivery_address: input.checkout.address, p_note: input.checkout.note,
      p_delivery_city_ref: input.checkout.cityRef ?? null,
      p_delivery_address_ref: input.checkout.addressRef ?? null,
      p_delivery_service_type: input.checkout.deliveryServiceType ?? null,
    }
    const key = 'tatami.cod.' + await stableOrderId([order, input.checkout.customerAccountId ?? null])
    const getRequestId = () => {
      const id = localStorage.getItem(key) ?? crypto.randomUUID()
      localStorage.setItem(key, id)
      return id
    }
    const requestId = navigator.locks ? await navigator.locks.request(key, getRequestId) : getRequestId()
    const pendingKey = pendingCodKey(input.store.id, input.checkout.customerAccountId, input.items)
    localStorage.setItem(pendingKey, JSON.stringify({ id: requestId, fingerprintKey: key }))
    const row = await supabaseRequest<Row>('/rest/v1/rpc/place_cod_order', {
      method: 'POST', token: input.token, body: JSON.stringify({ p_request_id: requestId, p_order: order }),
    })
    localStorage.removeItem(key)
    localStorage.removeItem(pendingKey)
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
}
