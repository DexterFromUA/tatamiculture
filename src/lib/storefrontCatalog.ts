import type { CatalogCategory, Product, ProductText } from '../types'

export const newArrivalsCategory = '__new_arrivals__'
export const discountedCategory = '__discounted__'

export type CatalogFilters = {
  category: string
  subcategory: string
  search: string
  size: string
  sort: string
  inStock: boolean
}

export type CatalogCursor = { price: number; updatedAt: string; id: string }
export type CatalogPage = { rows: Product[]; total: number; next_cursor: CatalogCursor | null }
export type CatalogMetadata = {
  categories: CatalogCategory[]
  sizes: string[]
  hasNewArrivals: boolean
  hasDiscountedProducts: boolean
  bannerProducts: (Pick<ProductText, 'name' | 'name_uk' | 'name_en'> & { id: string; url: string })[]
}
