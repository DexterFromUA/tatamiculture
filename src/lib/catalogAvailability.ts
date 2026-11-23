import type { ProductOption } from '../types'

export const maxOrderVariantQuantity = 20
export const unavailableQuantity = 'A product is no longer available in the requested quantity.'

export function stockLabel(option: ProductOption) {
  if (option.quantity === 0 && option.allowOutOfStock) return 'Available to order'
  if (!option.isLimited) return
  if (option.quantity === 0) return 'Out of stock'
  if (option.quantity <= option.lowStockThreshold) return 'Only a few left'
}

export function purchaseQuantityLimit(option: ProductOption) {
  return option.quantity === 0 && option.allowOutOfStock
    ? maxOrderVariantQuantity
    : Math.min(maxOrderVariantQuantity, option.quantity)
}
