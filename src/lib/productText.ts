import type { ProductText } from '../types'

export function productName(product: Pick<ProductText, 'name' | 'name_uk' | 'name_en'>, language?: string) {
  const uk = product.name_uk?.trim()
  const en = product.name_en?.trim()
  return (language === 'en' ? en || uk : uk || en) || product.name
}

export function productDescription(product: ProductText, language?: string) {
  const preferred = language === 'en' ? product.description_en : product.description_uk
  const alternate = language === 'en' ? product.description_uk : product.description_en
  // Keep Markdown whitespace in the selected description.
  if (preferred?.trim()) return preferred
  if (alternate?.trim()) return alternate
  return product.description
}
