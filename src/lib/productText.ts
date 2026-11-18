import type { Product, ProductText } from '../types'

export const maxSizeGuideImages = 3

export function getSizeGuideImageUrls(primary: unknown, additional: unknown): string[] {
  return [primary, ...(Array.isArray(additional) ? additional : [])]
    .filter((url): url is string => typeof url === 'string' && url.trim().length > 0)
    .slice(0, maxSizeGuideImages)
}

export function productInformation(product: Product, language?: string) {
  const localized = (uk?: string, en?: string) => {
    const preferred = language === 'en' ? en : uk
    const alternate = language === 'en' ? uk : en
    return preferred?.trim() ? preferred : alternate ?? ''
  }
  return {
    sizeGuide: localized(product.sizeGuide, product.sizeGuideEn),
    composition: localized(product.composition, product.compositionEn),
    careInstructions: localized(product.careInstructions, product.careInstructionsEn),
  }
}

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
