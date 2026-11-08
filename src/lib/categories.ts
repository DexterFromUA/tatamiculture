import type { CatalogCategory, Product } from '../types'

export function categoryLabel(category: Pick<CatalogCategory, 'name' | 'name_uk' | 'name_en'>, language?: string) {
  const uk = category.name_uk?.trim()
  const en = category.name_en?.trim()
  return (language === 'en' ? en || uk : uk || en) || category.name
}

export function categoryGroups(categories: CatalogCategory[], language?: string) {
  const ordered = [...categories].sort((a, b) => a.position - b.position
    || categoryLabel(a, language).localeCompare(categoryLabel(b, language), language))
  return ordered.filter(category => !category.parent_id).map(parent => ({
    parent,
    children: ordered.filter(category => category.parent_id === parent.id),
  }))
}

export function categoryPaths(categories: CatalogCategory[], selected: string[], language?: string) {
  const ids = new Set(selected)
  return categoryGroups(categories, language).flatMap(({ parent, children }) => {
    if (!ids.has(parent.id)) return []
    const label = categoryLabel(parent, language)
    const leaves = children.filter(child => ids.has(child.id))
    return leaves.length ? leaves.map(child => `${label} / ${categoryLabel(child, language)}`) : [label]
  })
}

export function categoriesForProduct(product: Product): CatalogCategory[] {
  if (product.categories?.length) return product.categories
  return product.primaryCategory ? [product.primaryCategory] : []
}

export function productCategoryLabel(product: Product, language?: string) {
  const category = product.primaryCategory ?? product.categories?.find(item => !item.parent_id)
  return category ? categoryLabel(category, language) : undefined
}
