import { optionPrice } from './format'
import type { ProductOption } from '../types'

type DiscountRule = {
  discount_percent?: number | null
  stack_customer_discount?: boolean
}

// The checkout SQL applies the same rounding per unit, in minor currency units.
function discountedMinorPrice(price: number, percent: number) {
  return Math.floor((price * (10000 - Math.round(percent * 100)) + 5000) / 10000)
}

export function catalogOffer(product: DiscountRule, variant: DiscountRule & { price: number; compare_at_price?: number | null }) {
  const hasOverride = variant.discount_percent != null
  const percent = variant.discount_percent ?? product.discount_percent
  const regularPrice = Math.max(variant.price, variant.compare_at_price ?? 0)
  const salePrice = percent == null ? variant.price : discountedMinorPrice(regularPrice, percent)
  const isDiscount = salePrice < regularPrice
  const stacking = hasOverride ? variant.stack_customer_discount : product.stack_customer_discount
  return {
    price: regularPrice / 100,
    salePrice: salePrice / 100,
    isDiscount,
    discountPercent: percent ?? (isDiscount ? Math.round(10000 * (regularPrice - salePrice) / regularPrice) / 100 : 0),
    allowsCustomerDiscount: !(isDiscount || (percent ?? 0) > 0) || stacking === true,
  }
}

export function customerUnitPrice(option: ProductOption, percent: number) {
  const price = optionPrice(option)
  if (!(option.allowsCustomerDiscount ?? !option.isDiscount)) return price
  return discountedMinorPrice(Math.round(price * 100), percent) / 100
}
