import type { CatalogCategory, Product } from '../types'

export function categoryGroups(categories: CatalogCategory[]) {
  const ordered = [...categories].sort((a, b) => a.position - b.position || a.name.localeCompare(b.name))
  return ordered.filter(category => !category.parent_id).map(parent => ({
    parent,
    children: ordered.filter(category => category.parent_id === parent.id),
  }))
}

export function categoryPaths(categories: CatalogCategory[], selected: string[]) {
  const ids = new Set(selected)
  return categoryGroups(categories).flatMap(({ parent, children }) => {
    if (!ids.has(parent.id)) return []
    const leaves = children.filter(child => ids.has(child.id))
    return leaves.length ? leaves.map(child => `${parent.name} / ${child.name}`) : [parent.name]
  })
}

export function categoriesForProduct(product: Product): CatalogCategory[] {
  if (product.categories) return product.categories
  return product.category && product.category !== 'Uncategorized'
    ? [{ id: product.category, name: product.category, parent_id: null, position: 0 }]
    : []
}
