export function formatPrice(amount: number, currency = 'USD') {
  return new Intl.NumberFormat('en-US', {
    style: 'currency',
    currency,
  }).format(amount)
}

export function optionPrice(option: { price: number; isDiscount: boolean; discountPercent: number }) {
  if (!option.isDiscount) return option.price
  return option.price - (option.price * option.discountPercent) / 100
}

export function formatDate(iso: string) {
  return new Intl.DateTimeFormat('en-GB', {
    day: 'numeric',
    month: 'short',
    year: 'numeric',
  }).format(new Date(iso))
}
