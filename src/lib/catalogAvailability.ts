import type { ProductOption } from '../types'

export const maxOrderVariantQuantity = 20
export const unavailableQuantity = 'A product is no longer available in the requested quantity.'

export function purchaseQuantityLimit(option: ProductOption) {
  return option.quantity === 0 && option.allowOutOfStock
    ? maxOrderVariantQuantity
    : Math.min(maxOrderVariantQuantity, option.quantity)
}
