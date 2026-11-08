export type OrderStatus =
  | 'PENDING'
  | 'PAID'
  | 'IN_PROGRESS'
  | 'READY_FOR_PICKUP'
  | 'DELIVERED'
  | 'CANCELLED_BY_USER'
  | 'CANCELLED_BY_STORE'

export type PaymentStatus = 'MOCK_PAID' | 'PENDING' | 'PAID' | 'FAILED' | 'REFUNDED'

export type Store = {
  id: string
  slug: string
  name: string
  description: string
  contactEmail: string
  contactPhone: string
  contactCity: string
  currency: string
  primaryColor: string
}

export type ProductOption = {
  id: string
  name: string
  price: number
  isPreOrder: boolean
  isDiscount: boolean
  discountPercent: number
  isLimited: boolean
  quantity: number
}

export type Product = {
  sizeGuide?: string
  composition?: string
  careInstructions?: string
  id: string
  storeId: string
  name: string
  description: string
  category: string
  imgUrls: string[]
  isActive: boolean
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
  shortLinkId?: string
  paymentMethod?: 'ONLINE' | 'CASH_ON_DELIVERY'
  novaPoshtaTtn?: string
  novaPoshtaStatus?: string
}

export type ShortLink = {
  id: string
  code: string
  storeId: string
  productId: string
}

export type CheckoutInput = {
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
