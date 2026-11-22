export type OrderStatus =
  | 'PENDING'
  | 'PAID'
  | 'IN_PROGRESS'
  | 'WAITING_FOR_STOCK'
  | 'PREPARING_SHIPMENT'
  | 'IN_TRANSIT'
  | 'READY_FOR_PICKUP'
  | 'DELIVERED'
  | 'COMPLETED'
  | 'CANCELLED_BY_USER'
  | 'CANCELLED_BY_STORE'

export type PaymentStatus = 'MOCK_PAID' | 'PENDING' | 'PAID' | 'FAILED' | 'REFUNDED'

export type Store = {
  id: string
  name: string
  currency: string
  smsNotificationsEnabled: boolean
}

export type ProductOption = {
  allowOutOfStock?: boolean
  salePrice?: number
  sku?: string
  id: string
  name: string
  price: number
  isDiscount: boolean
  discountPercent: number
  allowsCustomerDiscount?: boolean
  isPreOrder: boolean
  isLimited: boolean
  quantity: number
}

export type CatalogCategory = {
  id: string
  name: string
  name_uk?: string | null
  name_en?: string | null
  parent_id: string | null
  position: number
}

export type ProductText = {
  name: string
  description: string
  name_uk?: string | null
  name_en?: string | null
  description_uk?: string | null
  description_en?: string | null
}

export type Product = ProductText & {
  createdAt?: string
  updatedAt?: string
  sizeGuide?: string
  sizeGuideImageUrls?: string[]
  composition?: string
  careInstructions?: string
  sizeGuideEn?: string
  compositionEn?: string
  careInstructionsEn?: string
  id: string
  storeId: string
  primaryCategory?: CatalogCategory
  categories?: CatalogCategory[]
  imgUrls: string[]
  isActive: boolean
  isNew: boolean
  productOptions: ProductOption[]
}

export type User = {
  id: string
  name: string
  email: string
  phone: string
  city?: string
}

export type CartItem = {
  productId: string
  optionId: string
  quantity: number
}

export type OrderItem = {
  id: string
  productId: string
  productOptionId: string
  productName: string
  optionName: string
  quantity: number
  unitPrice: number
  discountPercent: number
  finalUnitPrice: number
  lineTotal: number
  isPreOrder: boolean
}

export type Order = {
  id: string
  userId: string
  storeId: string
  items: OrderItem[]
  totalPrice: number
  currency: string
  status: OrderStatus
  paymentStatus: PaymentStatus
  receiptCode: string
  customerName: string
  customerEmail: string
  customerPhone: string
  deliveryCity: string
  deliveryAddress: string
  note: string
  createdAt: string
  paymentMethod?: 'ONLINE' | 'CASH_ON_DELIVERY'
  reservedInProfile?: boolean
  novaPoshtaTtn?: string
  novaPoshtaStatus?: string
}

export type CheckoutInput = {
  customerAccountId?: string
  expectedDiscountPercent?: number
  expectedTotal?: number
  name: string
  email: string
  phone: string
  city: string
  address: string
  note: string
  cityRef?: string
  addressRef?: string
  deliveryServiceType?: 'WarehouseWarehouse' | 'WarehousePostomat'
}

export type AuthSession = {
  token: string
  refreshToken?: string
  user: User
  registrationStoreId?: string
}
