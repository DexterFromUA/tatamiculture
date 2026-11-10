import { LocalImagePreview } from '../components/LocalImagePreview'
import { VariantCostEditor } from '../components/VariantCostEditor'
import { StockAdjustment } from '../components/StockAdjustment'
import { useCallback, useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { useToast } from '../context/ToastContext'
import { SupabaseError, supabaseConfigured, supabaseRequest, uploadProductImage } from '../lib/supabase'
import { fetchAll, hasStoreMembership } from '../lib/crm'
import { categoryGroups, categoryLabel, categoryPaths } from '../lib/categories'
import { formatPrice } from '../lib/format'
import { productName } from '../lib/productText'
import type { CatalogCategory, ProductText } from '../types'

type Variant = {
  id?: string
  name: string
  sku: string
  price: number
  compare_at_price: number | null
  stock_quantity: number
  low_stock_threshold: number
  is_preorder: boolean
  variant_costs: { cost_amount: number } | null
}
type ProductImage = { id: string; public_url: string; storage_path: string; position: number }
type DraftVariant = Omit<Variant, 'price' | 'variant_costs'> & { key: string; unitCost: string; unitCostEdited: boolean }
type CatalogProduct = ProductText & {
  size_guide?: string
  size_guide_image_url?: string
  composition?: string
  care_instructions?: string
  id: string
  category_id: string | null
  product_categories: Array<{ category_id: string }>
  is_active: boolean
  is_new: boolean
  weight_grams: number | null
  product_images: ProductImage[]
  product_variants: Variant[]
}
type Draft = {
  key: string
  newImagesFirst: boolean
  sizeGuide: string
  sizeGuideImageUrl: string
  sizeGuideImageFile: File | null
  composition: string
  careInstructions: string
  id?: string
  names: Record<'uk' | 'en', string>
  descriptions: Record<'uk' | 'en', string>
  price: string
  weightGrams: string
  categoryIds: string[]
  isActive: boolean
  isNew: boolean
  images: ProductImage[]
  newImageFiles: File[]
  removedImageIds: string[]
  variants: DraftVariant[]
}

const defaultLowStockThreshold = 3
const blankVariant = (): DraftVariant => ({ key: crypto.randomUUID(), name: 'M', sku: '', compare_at_price: null, stock_quantity: 0, low_stock_threshold: defaultLowStockThreshold, is_preorder: false, unitCost: '', unitCostEdited: false })
const blankDraft = (): Draft => ({ key: crypto.randomUUID(), newImagesFirst: false, sizeGuide: '', sizeGuideImageUrl: '', sizeGuideImageFile: null, composition: '', careInstructions: '', names: { uk: '', en: '' }, descriptions: { uk: '', en: '' }, price: '0', weightGrams: '', categoryIds: [], isActive: true, isNew: false, images: [], newImageFiles: [], removedImageIds: [], variants: [blankVariant()] })
const categorySlug = (name: string) => `${name.normalize('NFKC').toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu, '-').replace(/^-|-$/g, '') || 'category'}-${crypto.randomUUID().slice(0, 8)}`

function assignedCategoryIds(product: CatalogProduct) {
  return [...new Set([
    ...(product.category_id ? [product.category_id] : []),
    ...(product.product_categories ?? []).map(link => link.category_id),
  ])]
}

function setProductCategories(productIds: string[], categoryIds: string[], token: string) {
  return supabaseRequest('/rest/v1/rpc/set_catalog_product_categories', {
    method: 'POST', token, body: JSON.stringify({ p_products: productIds, p_categories: categoryIds }),
  })
}

function toDraft(product: CatalogProduct, language?: string): Draft {
  const names = { uk: product.name_uk ?? '', en: product.name_en ?? '' }
  const descriptions = { uk: product.description_uk ?? '', en: product.description_en ?? '' }
  const editorLanguage = language === 'en' ? 'en' : 'uk'
  if (!names.uk.trim() && !names.en.trim()) names[editorLanguage] = product.name
  if (!descriptions.uk.trim() && !descriptions.en.trim()) descriptions[editorLanguage] = product.description
  return {
    key: product.id,
    newImagesFirst: false,
    sizeGuide: product.size_guide ?? '', composition: product.composition ?? '', careInstructions: product.care_instructions ?? '',
    sizeGuideImageUrl: product.size_guide_image_url ?? '', sizeGuideImageFile: null,
    id: product.id,
    names,
    descriptions,
    price: String(Number(product.product_variants[0]?.price ?? 0) / 100),
    weightGrams: product.weight_grams == null ? '' : String(product.weight_grams),
    categoryIds: assignedCategoryIds(product),
    isActive: product.is_active,
    isNew: product.is_new === true,
    images: [...product.product_images].sort((a, b) => a.position - b.position),
    newImageFiles: [],
    removedImageIds: [],
    variants: product.product_variants.map(({ id, name, sku, compare_at_price, stock_quantity, low_stock_threshold, is_preorder, variant_costs }) => ({
      key: id ?? crypto.randomUUID(), id, name, sku, compare_at_price, stock_quantity, low_stock_threshold, is_preorder,
      unitCost: variant_costs ? String(variant_costs.cost_amount / 100) : '',
      unitCostEdited: false,
    })),
  }
}

type CatalogView = 'products' | 'stock'
type StockFilter = 'all' | 'low' | 'out'

export function CatalogAdminPage({ embedded = false, initialView = 'products' }: { embedded?: boolean; initialView?: CatalogView }) {
  const { t, i18n } = useTranslation()
  const language = i18n.resolvedLanguage
  const { store, refreshProducts } = useStore()
  const { token, user } = useAuth()
  const { addToast } = useToast()
  const [member, setMember] = useState<boolean | null>(null)
  const [stockSchemaReady, setStockSchemaReady] = useState(false)
  const [products, setProducts] = useState<CatalogProduct[]>([])
  const [categories, setCategories] = useState<CatalogCategory[]>([])
  const [draft, setDraft] = useState<Draft | null>(null)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [deleting, setDeleting] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [view, setView] = useState<CatalogView>(initialView)
  const [stockFilter, setStockFilter] = useState<StockFilter>(initialView === 'stock' ? 'low' : 'all')
  const [stockSelection, setStockSelection] = useState<Record<string, string>>({})
  const [categoryFilter, setCategoryFilter] = useState('all')
  const [showCategories, setShowCategories] = useState(false)
  const [categoryNames, setCategoryNames] = useState({ uk: '', en: '' })
  const [categoryParent, setCategoryParent] = useState('')
  const [editingCategoryId, setEditingCategoryId] = useState<string | null>(null)
  const [categoryBusy, setCategoryBusy] = useState(false)
  const [selected, setSelected] = useState<string[]>([])
  const [bulkAction, setBulkAction] = useState('')
  const [page, setPage] = useState(1)
  const groups = categoryGroups(categories, language)
  const categoryOptions = groups.flatMap(({ parent, children }) => [
    { category: parent, label: categoryLabel(parent, language) },
    ...children.map(category => ({ category, label: `${categoryLabel(parent, language)} / ${categoryLabel(category, language)}` })),
  ])
  const editingCategory = categories.find(category => category.id === editingCategoryId)
  const savedVariants = products.find(product => product.id === draft?.id)?.product_variants
  const hasDifferentPrices = savedVariants?.some(variant => Number(variant.price) !== Number(savedVariants[0].price))
  const query = search.trim().toLowerCase()
  const searchedProducts = products.filter(product => [
    product.name, product.name_uk, product.name_en, ...product.product_variants.map(variant => variant.sku),
  ].some(value => value?.toLowerCase().includes(query)))
  const lowCount = products.flatMap(product => product.product_variants).filter(variant => !variant.is_preorder && variant.stock_quantity < variant.low_stock_threshold).length
  const outCount = products.flatMap(product => product.product_variants).filter(variant => !variant.is_preorder && variant.stock_quantity === 0).length
  const productMatches = searchedProducts.filter(product => categoryFilter === 'all' || assignedCategoryIds(product).includes(categoryFilter))
  const stockMatches = searchedProducts.map(product => ({
    product,
    variants: product.product_variants.filter(variant =>
      stockFilter === 'all' || (!variant.is_preorder && (stockFilter === 'out'
        ? variant.stock_quantity === 0
        : variant.stock_quantity < variant.low_stock_threshold))),
  })).filter(({ variants }) => variants.length > 0)
  const pages = Math.max(1, Math.ceil((view === 'products' ? productMatches.length : stockMatches.length) / 20))
  const currentPage = Math.min(page, pages)
  const pageProducts = productMatches.slice((currentPage - 1) * 20, currentPage * 20)
  const pageProductIds = new Set(pageProducts.map(product => product.id))
  const selectedOutsidePage = selected.filter(id => !pageProductIds.has(id)).length
  const pageSelected = pageProducts.length > 0 && pageProducts.every(product => selected.includes(product.id))
  const draggedFile = useRef<number | null>(null)
  const draggedImage = useRef<string | null>(null)
  const editorHeading = useRef<HTMLHeadingElement>(null)
  const attemptedVariantIds = useRef(new Set<string>())
  const editorOpen = draft !== null
  useEffect(() => {
    if (editorOpen) editorHeading.current?.focus()
  }, [editorOpen])
  const [originalDraft, setOriginalDraft] = useState('')
  const dirty = draft !== null && (draft.newImageFiles.length > 0 || draft.sizeGuideImageFile !== null || JSON.stringify(draft) !== originalDraft)
  useEffect(() => {
    if (!dirty) return
    const preventExit = (event: BeforeUnloadEvent) => event.preventDefault()
    const preventNavigation = (event: MouseEvent) => {
      if (!(event.target instanceof Element)) return
      if (!event.target.closest('a[href], .admin-tabs button')) return
      if (!window.confirm(t('Discard unsaved changes?'))) {
        event.preventDefault()
        event.stopPropagation()
      }
    }
    window.addEventListener('beforeunload', preventExit)
    document.addEventListener('click', preventNavigation, true)
    return () => {
      window.removeEventListener('beforeunload', preventExit)
      document.removeEventListener('click', preventNavigation, true)
    }
  }, [dirty, t])

  const beginDraft = (next: Draft) => {
    attemptedVariantIds.current.clear()
    setOriginalDraft(JSON.stringify(next))
    setError(null)
    setDraft(next)
  }
  const closeSavedEditor = () => {
    setDraft(null)
    setShowCategories(false)
    setEditingCategoryId(null)
    setCategoryNames({ uk: '', en: '' })
    setCategoryParent('')
    setError(null)
  }
  const closeEditor = () => {
    if (dirty && !window.confirm(t('Discard unsaved changes?'))) return
    closeSavedEditor()
  }
  const openProduct = (product: CatalogProduct) => beginDraft(toDraft(product, language))
  const changeView = (next: CatalogView) => { setView(next); setPage(1); setDraft(null) }

  const load = useCallback(async () => {
    if (!store || !token || !user) return
    setLoading(true)
    try {
      if (!(await hasStoreMembership(store.id, user.id, token))) {
        setMember(false)
        return
      }
      const productQuery = (includeThreshold: boolean) =>
        fetchAll<CatalogProduct>(`/rest/v1/products?store_id=eq.${encodeURIComponent(store.id)}&select=*,product_categories(category_id),product_images(id,public_url,storage_path,position),product_variants(id,name,sku,price,compare_at_price,stock_quantity,is_preorder,variant_costs(cost_amount)${includeThreshold ? ',low_stock_threshold' : ''})&order=position.asc,id.asc&product_variants.order=position.asc,id.asc`, token)
      const [catalog, nextCategories] = await Promise.all([
        productQuery(true).then(products => ({ products, hasThreshold: true })).catch(async (cause: unknown) => {
          if (!(cause instanceof Error) || !/column .*low_stock_threshold.*does not exist/i.test(cause.message)) throw cause
          return { products: await productQuery(false), hasThreshold: false }
        }),
        fetchAll<CatalogCategory>(`/rest/v1/categories?store_id=eq.${encodeURIComponent(store.id)}&select=*&order=position.asc,id.asc`, token),
      ])
      setMember(true)
      setStockSchemaReady(catalog.hasThreshold)
      setProducts(catalog.products.map(product => ({
        ...product,
        product_variants: product.product_variants.map(variant => ({
          ...variant,
          low_stock_threshold: variant.low_stock_threshold ?? defaultLowStockThreshold,
        })),
      })))
      setCategories(nextCategories)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not load catalogue')
    } finally {
      setLoading(false)
    }
  }, [store, token, user])

  useEffect(() => {
    const timer = window.setTimeout(() => { void load() }, 0)
    return () => window.clearTimeout(timer)
  }, [load])

  const updateVariant = (index: number, field: Exclude<keyof DraftVariant, 'unitCostEdited'>, value: string | number | boolean | null) => {
    setDraft((current) => current ? {
      ...current,
      variants: current.variants.map((variant, itemIndex) => itemIndex === index
        ? { ...variant, [field]: value, unitCostEdited: variant.unitCostEdited || field === 'unitCost' }
        : variant),
    } : current)
  }

  const moveFile = (from: number, to: number) => {
    setDraft(current => {
      if (!current) return current
      const files = [...current.newImageFiles]
      const [file] = files.splice(from, 1)
      files.splice(to, 0, file)
      return { ...current, newImageFiles: files }
    })
  }
  const moveImage = (id: string, targetId: string) => {
    setDraft(current => {
      if (!current || id === targetId) return current
      const images = [...current.images]
      const from = images.findIndex(image => image.id === id)
      const to = images.findIndex(image => image.id === targetId)
      if (from < 0 || to < 0) return current
      const [image] = images.splice(from, 1)
      images.splice(to, 0, image)
      return { ...current, images }
    })
  }

  const removeVariant = (index: number) => {
    setDraft((current) => current ? { ...current, variants: current.variants.filter((_, itemIndex) => itemIndex !== index) } : current)
  }

  const saveCategory = async () => {
    if (!store || !token || categoryBusy) return
    const name_uk = categoryNames.uk.trim() || null
    const name_en = categoryNames.en.trim() || null
    const name = name_uk ?? name_en
    if (!name) { setError(t('Enter a category name.')); return }
    const names = { name, name_uk, name_en }
    const parentId = categoryParent || null
    if (categories.some(category => category.id !== editingCategoryId && category.parent_id === parentId
      && ['uk', 'en'].some(lang => categoryLabel(category, lang).trim().toLowerCase() === categoryLabel(names, lang).toLowerCase()))) {
      setError(t('This category already exists.'))
      return
    }
    setCategoryBusy(true)
    setError(null)
    try {
      if (editingCategoryId) {
        await supabaseRequest(`/rest/v1/categories?id=eq.${encodeURIComponent(editingCategoryId)}&store_id=eq.${encodeURIComponent(store.id)}`, { method: 'PATCH', token, body: JSON.stringify(names) })
        setCategories(current => current.map(category => category.id === editingCategoryId ? { ...category, ...names } : category))
        await refreshProducts().catch(() => {})
      } else {
        const created = await supabaseRequest<CatalogCategory[]>('/rest/v1/categories', {
          method: 'POST', token, headers: { Prefer: 'return=representation' },
          body: JSON.stringify({
            store_id: store.id, ...names, slug: categorySlug(name), parent_id: parentId,
            position: Math.max(-1, ...categories.filter(category => category.parent_id === parentId).map(category => category.position)) + 1,
          }),
        })
        const category = created[0]
        if (!category) throw new Error(t('Could not create category.'))
        setCategories(current => [...current, category])
        setDraft(current => current ? {
          ...current,
          categoryIds: [...new Set([...current.categoryIds, ...(parentId ? [parentId] : []), category.id])],
        } : current)
      }
      resetCategoryForm()
      if (draft) setShowCategories(false)
    } catch (cause) {
      setError(cause instanceof SupabaseError && cause.code === '23505'
        ? t('This category already exists.')
        : cause instanceof Error ? cause.message : t('Could not save category.'))
    } finally {
      setCategoryBusy(false)
    }
  }

  const categoryDeleteReason = (category: CatalogCategory) => {
    if (categories.some(item => item.parent_id === category.id)) return 'Remove its subcategories first.'
    if (products.some(product => assignedCategoryIds(product).includes(category.id))) return 'Move products to another category first.'
    return ''
  }

  const deleteCategory = async (category: CatalogCategory) => {
    if (!store || !token || categoryBusy) return
    const reason = categoryDeleteReason(category)
    if (reason) { setError(t(reason)); return }
    if (!window.confirm(t('Delete category "{{name}}"?', { name: categoryLabel(category, language) }))) return
    setCategoryBusy(true)
    setError(null)
    try {
      await supabaseRequest(`/rest/v1/categories?id=eq.${encodeURIComponent(category.id)}&store_id=eq.${encodeURIComponent(store.id)}`, { method: 'DELETE', token })
      setCategories(current => current.filter(item => item.id !== category.id))
      if (categoryFilter === category.id) setCategoryFilter('all')
      if (categoryParent === category.id) setCategoryParent('')
      if (bulkAction === category.id) setBulkAction('')
      if (editingCategoryId === category.id) resetCategoryForm()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('Could not delete category.'))
    } finally {
      setCategoryBusy(false)
    }
  }

  const resetCategoryForm = () => {
    setEditingCategoryId(null)
    setCategoryNames({ uk: '', en: '' })
    setCategoryParent('')
    setError(null)
  }

  const toggleCategory = (category: CatalogCategory, checked: boolean) => {
    const removed = new Set([category.id, ...categories.filter(item => item.parent_id === category.id).map(item => item.id)])
    setDraft(current => current ? {
      ...current,
      categoryIds: checked ? [...current.categoryIds, category.id] : current.categoryIds.filter(id => !removed.has(id)),
    } : current)
  }

  const save = async () => {
    if (!store || !token || !draft || saving) return
    const name_uk = draft.names.uk.trim() || null
    const name_en = draft.names.en.trim() || null
    const name = name_uk ?? name_en
    if (!name) {
      setError(t('Enter a product name in at least one language.'))
      return
    }
    if (draft.variants.length === 0) {
      setError('Add at least one size or variant')
      return
    }
    const price = Math.round(Number(draft.price) * 100)
    if (!draft.price.trim() || !Number.isSafeInteger(price) || Number(draft.price) < 0) {
      setError('Enter a valid price')
      return
    }
    const weightGrams = draft.weightGrams === '' ? null : Number(draft.weightGrams)
    if (weightGrams !== null && (!Number.isInteger(weightGrams) || weightGrams <= 0 || weightGrams > 2147483647)) {
      setError(t('Enter a positive weight in whole grams.'))
      return
    }
    const costs: { variant_id: string; cost_amount: number }[] = []
    const clearedCostIds: string[] = []
    for (const variant of draft.variants.filter(variant => variant.unitCostEdited)) {
      if (!variant.unitCost.trim()) {
        clearedCostIds.push(variant.key)
        continue
      }
      const amount = Number(variant.unitCost)
      const cost = Math.round(amount * 100)
      if (!Number.isSafeInteger(cost) || amount < 0 || cost > 2147483647) {
        setError(t('Enter a valid unit cost.'))
        return
      }
      costs.push({ variant_id: variant.key, cost_amount: cost })
    }
    setSaving(true)
    setError(null)
    try {
      const description_uk = draft.descriptions.uk.trim() ? draft.descriptions.uk : null
      const description_en = draft.descriptions.en.trim() ? draft.descriptions.en : null
      const payload = {
        store_id: store.id,
        name, name_uk, name_en,
        description: description_uk ?? description_en ?? '', description_uk, description_en,
        size_guide: draft.sizeGuide, composition: draft.composition, care_instructions: draft.careInstructions,
        is_active: draft.isActive,
        is_new: draft.isNew,
        weight_grams: weightGrams,
      }
      const productId = draft.key
      const productPath = `/rest/v1/products?id=eq.${encodeURIComponent(productId)}&store_id=eq.${encodeURIComponent(store.id)}`
      if (!draft.id) {
        // Keep an unfinished product off the storefront and reuse its ID on retry.
        await supabaseRequest('/rest/v1/products?on_conflict=id', {
          method: 'POST', token, headers: { Prefer: 'resolution=ignore-duplicates' },
          body: JSON.stringify({ ...payload, id: productId, is_active: false }),
        })
      }

      let sizeGuideImageUrl = draft.sizeGuideImageUrl
      if (draft.sizeGuideImageFile) {
        const image = await uploadProductImage(productId, draft.sizeGuideImageFile, token)
        sizeGuideImageUrl = image.publicUrl
        setDraft(current => current?.key === productId
          ? { ...current, sizeGuideImageUrl, sizeGuideImageFile: null }
          : current)
      }

      const current = products.find((product) => product.id === productId)
      const keepIds = new Set(draft.variants.map(variant => variant.key))
      const knownIds = new Set([
        ...(current?.product_variants ?? []).flatMap(variant => variant.id ? [variant.id] : []),
        ...attemptedVariantIds.current,
      ])
      await Promise.all([...knownIds].filter(id => !keepIds.has(id)).map(id =>
        supabaseRequest(`/rest/v1/product_variants?id=eq.${encodeURIComponent(id)}&product_id=eq.${encodeURIComponent(productId)}`, { method: 'DELETE', token }),
      ))
      const variants = draft.variants.map((variant, position) => ({
        variant,
        fields: {
          product_id: productId,
          name: variant.name.trim() || 'One size',
          sku: variant.sku?.trim() || null,
          price,
          compare_at_price: variant.compare_at_price && Number(variant.compare_at_price) >= price ? variant.compare_at_price : null,
          is_preorder: variant.is_preorder,
          position,
        },
      }))
      const newVariants = variants.filter(({ variant }) => !variant.id)
      const insertedIds = new Set<string>()
      if (newVariants.length > 0) {
        for (const { variant } of newVariants) attemptedVariantIds.current.add(variant.key)
        const inserted = await supabaseRequest<{ id: string }[]>('/rest/v1/product_variants?on_conflict=id&select=id', {
          method: 'POST', token, headers: { Prefer: 'resolution=ignore-duplicates,return=representation' },
          body: JSON.stringify(newVariants.map(({ variant, fields }) => ({
            ...fields,
            id: variant.key,
            stock_quantity: variant.is_preorder ? 0 : variant.stock_quantity,
            ...(stockSchemaReady && {
              low_stock_threshold: variant.is_preorder ? defaultLowStockThreshold : variant.low_stock_threshold,
            }),
          }))),
        })
        for (const row of inserted ?? []) insertedIds.add(row.id)
      }
      await Promise.all(variants.filter(({ variant }) => !insertedIds.has(variant.key)).map(({ variant, fields }) =>
        supabaseRequest(`/rest/v1/product_variants?id=eq.${encodeURIComponent(variant.key)}&product_id=eq.${encodeURIComponent(productId)}`, {
          method: 'PATCH', token,
          body: JSON.stringify({
            ...fields,
            ...(!variant.is_preorder && (stockSchemaReady
              ? { low_stock_threshold: variant.low_stock_threshold }
              : { stock_quantity: variant.stock_quantity })),
          }),
        }),
      ))
      if (costs.length > 0) {
        await supabaseRequest('/rest/v1/variant_costs?on_conflict=variant_id', {
          method: 'POST', token, headers: { Prefer: 'resolution=merge-duplicates' }, body: JSON.stringify(costs),
        })
      }
      if (clearedCostIds.length > 0) {
        await supabaseRequest(`/rest/v1/variant_costs?variant_id=in.(${clearedCostIds.join(',')})`, { method: 'DELETE', token })
      }

      const removedImages = draft.images.filter((image) => draft.removedImageIds.includes(image.id))
      const retainedImages = draft.images.filter((image) => !draft.removedImageIds.includes(image.id))
      await Promise.all(removedImages.map(async (image) => {
        await supabaseRequest(`/rest/v1/product_images?id=eq.${encodeURIComponent(image.id)}`, { method: 'DELETE', token })
      }))
      await Promise.all(retainedImages.map((image, position) =>
        supabaseRequest(`/rest/v1/product_images?id=eq.${encodeURIComponent(image.id)}`, { method: 'PATCH', token, body: JSON.stringify({ position: position + (draft.newImagesFirst ? draft.newImageFiles.length : 0) }) }),
      ))
      const uploadedImages = await Promise.all(draft.newImageFiles.map((file) => uploadProductImage(productId, file, token)))
      await Promise.all(uploadedImages.map((image, index) =>
        supabaseRequest('/rest/v1/product_images', {
          method: 'POST', token,
          body: JSON.stringify({ product_id: productId, public_url: image.publicUrl, storage_path: image.storagePath, position: (draft.newImagesFirst ? 0 : retainedImages.length) + index }),
        }),
      ))
      await setProductCategories([productId], draft.categoryIds, token)
      await supabaseRequest(productPath, { method: 'PATCH', token, body: JSON.stringify({ ...payload, size_guide_image_url: sizeGuideImageUrl }) })
      await Promise.all([load(), refreshProducts().catch(() => {})])
      closeSavedEditor()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not save product')
    } finally {
      setSaving(false)
    }
  }

  const applyBulk = async () => {
    if (!store || !token || !bulkAction || selected.length === 0 || saving) return
    setSaving(true)
    setError(null)
    try {
      if (bulkAction === 'publish' || bulkAction === 'hide') {
        await supabaseRequest(`/rest/v1/products?store_id=eq.${store.id}&id=in.(${selected.join(',')})`, {
          method: 'PATCH', token, body: JSON.stringify({ is_active: bulkAction === 'publish' }),
        })
      } else {
        const category = categories.find(item => item.id === bulkAction)
        if (!category && bulkAction !== 'uncategorized') return
        const ids = category ? [...(category.parent_id ? [category.parent_id] : []), category.id] : []
        await setProductCategories(selected, ids, token)
      }
      setSelected([])
      setBulkAction('')
      addToast(t('Bulk changes applied'))
      await Promise.all([load(), refreshProducts().catch(() => {})])
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('Could not save product'))
    } finally {
      setSaving(false)
    }
  }

  const duplicate = async (product: CatalogProduct) => {
    if (!token || saving) return
    setSaving(true)
    setError(null)
    try {
      await supabaseRequest('/rest/v1/rpc/duplicate_catalog_product', {
        method: 'POST', token, body: JSON.stringify({ p_product: product.id }),
      })
      await load()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('Could not save product'))
    } finally {
      setSaving(false)
    }
  }

  const deleteProduct = async () => {
    const productId = draft?.id
    if (!store || !token || !productId || saving || categoryBusy) return
    const product = products.find(item => item.id === productId)
    const name = product ? productName(product, language) : draft.names.uk || draft.names.en
    if (!window.confirm(t('Permanently delete “{{name}}” from the catalogue?', { name }))) return

    setSaving(true)
    setDeleting(true)
    setError(null)
    try {
      const deleted = await supabaseRequest<boolean>('/rest/v1/rpc/delete_catalog_product', {
        method: 'POST', token, body: JSON.stringify({ p_store_id: store.id, p_product_id: productId }),
      })
      setSelected(current => current.filter(id => id !== productId))
      closeSavedEditor()
      addToast(t(deleted ? 'Product deleted' : 'Product no longer exists'))
      await Promise.all([load(), refreshProducts().catch(() => {})])
    } catch (cause) {
      setError(cause instanceof SupabaseError && cause.code === '23503'
        ? t('This product is linked to orders or stock history. Hide it from the storefront instead.')
        : cause instanceof Error ? cause.message : t('Could not delete product'))
    } finally {
      setDeleting(false)
      setSaving(false)
    }
  }

  if (!store) return null
  if (!supabaseConfigured) return <section className="page-status"><h1>{t('CRM needs Supabase')}</h1></section>
  if (loading && member === null) return <div className="page-status">{t('Loading catalogue…')}</div>
  if (member === false) return <section className="page-status"><h1>{t('Manager access required')}</h1></section>

  const categoryManager = showCategories ? <section className="category-manager" aria-label={t('Manage categories')}>
    <div className="product-editor__head">
      <h3>{t(editingCategoryId ? 'Edit category' : draft ? 'Create category or subcategory' : 'Manage categories')}</h3>
      {draft && <button type="button" className="text-btn" disabled={categoryBusy} onClick={() => {
        setShowCategories(false)
        resetCategoryForm()
      }}>{t('Cancel')}</button>}
    </div>
    <form className="category-manager__form" onSubmit={event => { event.preventDefault(); void saveCategory() }}>
      <div className="category-manager__names">
        <label className="field">
          <span>{t('Name in Ukrainian')}</span>
          <input lang="uk" value={categoryNames.uk} maxLength={100} disabled={categoryBusy} onChange={event => setCategoryNames({ ...categoryNames, uk: event.target.value })} />
        </label>
        <label className="field">
          <span>{t('Name in English')}</span>
          <input lang="en" value={categoryNames.en} maxLength={100} disabled={categoryBusy} onChange={event => setCategoryNames({ ...categoryNames, en: event.target.value })} />
        </label>
      </div>
      <p className="muted category-manager__hint">{t('If one name is blank, the other is used for both languages.')}</p>
      {editingCategory && !editingCategory.name_uk && !editingCategory.name_en && <p className="muted category-manager__hint">{t('Current name: {{name}}', { name: editingCategory.name })}</p>}
      <div className="category-manager__actions">
        <label className="field">
          <span>{t('Parent category')}</span>
          <select value={categoryParent} disabled={categoryBusy || Boolean(editingCategoryId)} onChange={event => setCategoryParent(event.target.value)}>
            <option value="">{t('None (main category)')}</option>
            {groups.map(({ parent }) => <option key={parent.id} value={parent.id}>{categoryLabel(parent, language)}</option>)}
          </select>
        </label>
        <button type="submit" className="btn" disabled={categoryBusy}>{t(editingCategoryId ? 'Save' : categoryParent ? 'Create subcategory' : 'Create category')}</button>
        {editingCategoryId && <button type="button" className="text-btn" disabled={categoryBusy} onClick={resetCategoryForm}>{t('Cancel')}</button>}
      </div>
    </form>
    {!draft && <ul className="category-manager__list">{categoryOptions.map(({ category }) => {
      const used = products.filter(product => assignedCategoryIds(product).includes(category.id)).length
      const reason = categoryDeleteReason(category)
      return <li key={category.id} className={category.parent_id ? 'category-manager__subcategory' : undefined}>
        <div>
          <strong>{categoryLabel(category, language)}</strong>
          {(category.name_uk || category.name_en) && <span className="category-manager__translations">
            <span>UK: {category.name_uk || '—'}</span>
            <span>EN: {category.name_en || '—'}</span>
          </span>}
          <span>{t('Products')}: {used}</span>
        </div>
        <button type="button" className="text-btn" disabled={categoryBusy} onClick={() => {
          setEditingCategoryId(category.id)
          setCategoryNames({ uk: category.name_uk ?? '', en: category.name_en ?? '' })
          setCategoryParent(category.parent_id ?? '')
          setError(null)
        }}>{t('Edit')}</button>
        <button type="button" className="text-btn" disabled={categoryBusy || Boolean(reason)} title={reason ? t(reason) : undefined} onClick={() => void deleteCategory(category)}>{t('Delete')}</button>
      </li>
    })}</ul>}
  </section> : null

  return (
    <section>
      <header className={embedded ? 'crm-section-head catalog-section-head' : 'page-head page-head--row'}>
        {!embedded ? <div><p className="muted">{store.name} · {t('management')}</p><h1>{t('Catalogue')}</h1></div> : <div><span className="crm-section-head__label"><span>{store.name}</span> / CRM</span><h2>{t('Catalogue')}</h2></div>}
        {!draft && <div className="catalog-header-actions"><button type="button" className="btn btn--ghost" disabled={categoryBusy} onClick={() => { setShowCategories(current => !current); resetCategoryForm() }}>{t(showCategories ? 'Products' : 'Manage categories')}</button>{!showCategories && <button type="button" className="btn" onClick={() => beginDraft(blankDraft())}>{t('Add product')}</button>}</div>}
      </header>
      {error ? <p className="error" role="alert">{error}</p> : null}
      {!draft && (showCategories ? categoryManager : <>
      <div className="catalog-summary">
        <button type="button" className={view === 'products' ? 'active' : ''} onClick={() => changeView('products')}><span>{t('Products')}</span><strong>{products.length}</strong></button>
        <button type="button" className={view === 'stock' && stockFilter === 'all' ? 'active' : ''} onClick={() => { changeView('stock'); setStockFilter('all') }}><span>{t('Stock units')}</span><strong>{products.reduce((sum, product) => sum + product.product_variants.reduce((count, variant) => count + (variant.is_preorder ? 0 : variant.stock_quantity), 0), 0)}</strong></button>
        <button type="button" className={view === 'stock' && stockFilter === 'low' ? 'active' : ''} onClick={() => { changeView('stock'); setStockFilter('low') }}><span>{t('Low stock')}</span><strong>{lowCount}</strong></button>
        <button type="button" className={view === 'stock' && stockFilter === 'out' ? 'active' : ''} onClick={() => { changeView('stock'); setStockFilter('out') }}><span>{t('Out of stock')}</span><strong>{outCount}</strong></button>
      </div>
      <section className="crm-panel catalog-list-panel">
      <div className="catalog-toolbar">
        <input type="search" aria-label={t('Search by name or SKU')} placeholder={t('Search by name or SKU')} value={search} onChange={event => { setSearch(event.target.value); setPage(1) }} />
        {view === 'products' ? <select aria-label={t('Category')} value={categoryFilter} onChange={event => { setCategoryFilter(event.target.value); setPage(1) }}><option value="all">{t('All categories')}</option>{categoryOptions.map(({ category, label }) => <option key={category.id} value={category.id}>{label}</option>)}</select> : <select aria-label={t('Stock filter')} value={stockFilter} onChange={event => { setStockFilter(event.target.value as StockFilter); setPage(1) }}><option value="all">{t('All stock')}</option><option value="low">{t('Low stock')}</option><option value="out">{t('Out of stock')}</option></select>}
        <div className="crm-pagination"><button className="text-btn" disabled={currentPage === 1} onClick={() => setPage(currentPage - 1)}>{t('Previous')}</button><span>{currentPage} / {pages}</span><button className="text-btn" disabled={currentPage === pages} onClick={() => setPage(currentPage + 1)}>{t('Next')}</button></div>
      </div>
        {view === 'products' && (pageProducts.length > 0 || selected.length > 0) && <div className="order-bulk" role="group" aria-label={t('Bulk action')}>
          <label className="order-select-all">
            <input type="checkbox" checked={pageSelected} disabled={saving || !pageProducts.length}
              ref={input => { if (input) input.indeterminate = !pageSelected && selected.length > selectedOutsidePage }}
              onChange={event => {
                const checked = event.target.checked
                setSelected(current => checked
                  ? [...new Set([...current, ...pageProductIds])]
                  : current.filter(id => !pageProductIds.has(id)))
              }}
            />
            {t('Select all on this page')}
          </label>
          <div className="order-bulk__actions" aria-hidden={!selected.length} inert={!selected.length}>
            <div className="catalog-bulk__selection" aria-live="polite">
              <span className="catalog-bulk__count">{selected.length}</span>
              <div className="catalog-bulk__selection-label">
                <span>{t('Selected products')}</span>
                {selectedOutsidePage > 0 && <small>{t('Outside this page: {{count}}', { count: selectedOutsidePage })}</small>}
              </div>
            </div>
            <div className="catalog-bulk__controls">
              <select aria-label={t('Bulk action')} disabled={saving} value={bulkAction} onChange={event => setBulkAction(event.target.value)}>
                <option value="">{t('Bulk action')}</option>
                <option value="publish">{t('Publish')}</option>
                <option value="hide">{t('Hide')}</option>
                <option value="uncategorized">{t('Clear categories')}</option>
                {categoryOptions.map(({ category, label }) => <option key={category.id} value={category.id}>{t('Replace categories with {{category}}', { category: label })}</option>)}
              </select>
              <button type="button" className="btn" disabled={saving || !bulkAction} onClick={() => void applyBulk()}>{t(saving ? 'Saving…' : 'Apply')}</button>
              <button type="button" className="catalog-bulk__clear" disabled={saving} onClick={() => setSelected([])}>{t('Clear selection')}</button>
            </div>
          </div>
        </div>}
        <ul className="catalog-admin__list">
          {view === 'products' ? pageProducts.map(product => {
            const unavailable = product.product_variants.filter(variant => !variant.is_preorder && variant.stock_quantity === 0).length
            return <li key={product.id} className={selected.includes(product.id) ? 'catalog-admin__selected' : undefined}>
              <label className="order-select"><input type="checkbox" aria-label={`${t('Select product')} · ${productName(product, language)}`} checked={selected.includes(product.id)} disabled={saving} onChange={event => { const checked = event.target.checked; setSelected(current => checked ? [...current, product.id] : current.filter(id => id !== product.id)) }} /></label>
              {product.product_images[0] && <img className="catalog-admin__thumb" src={product.product_images[0].public_url} alt="" />}
              <div className="catalog-admin__item"><strong>{productName(product, language)}</strong><span>{categoryPaths(categories, assignedCategoryIds(product), language).join(' · ') || t('Uncategorized')} · {product.is_active ? t('Published') : t('Hidden')}{product.is_new && ` · ${t('New arrival')}`}</span><span>{product.product_variants.length} {t('variants')}{unavailable ? ` · ${unavailable} ${t('out of stock')}` : ''}</span></div>
              <div className="crm-order__actions catalog-admin__actions">
                <button type="button" className="text-btn" onClick={() => openProduct(product)}>{t('Edit')}</button>
                {stockSchemaReady && <button type="button" className="text-btn" disabled={saving} onClick={() => void duplicate(product)}>{t('Duplicate')}</button>}
              </div>
            </li>
          }) : stockMatches.slice((currentPage - 1) * 20, currentPage * 20).map(({ product, variants }) => {
            const variant = variants.find(item => item.id === stockSelection[product.id]) ?? variants[0]
            return <li key={product.id} className="catalog-stock-row">
              {product.product_images[0] && <img className="catalog-admin__thumb" src={product.product_images[0].public_url} alt="" />}
              <div className="catalog-admin__item">
                <strong>{productName(product, language)}</strong>
                <span>{formatPrice(Number(product.product_variants[0].price) / 100, store.currency)}</span>
                <label className="catalog-stock-row__size">
                  <span>{t('Size')}</span>
                  <select value={variant.id} onChange={event => {
                    const id = event.target.value
                    setStockSelection(current => ({ ...current, [product.id]: id }))
                  }}>
                    {variants.map(item => <option value={item.id} key={item.id}>{item.name}</option>)}
                  </select>
                </label>
                <span>{variant.sku || t('No SKU')} · {product.is_active ? t('Published') : t('Hidden')}</span>
                <span className={!variant.is_preorder && variant.stock_quantity < variant.low_stock_threshold ? 'stock-low' : ''}>{variant.is_preorder ? t('Pre-order') : `${variant.stock_quantity} ${t('in stock')}`}</span>
              </div>
              <div className="catalog-stock-row__actions" key={variant.id}>
                <button type="button" className="text-btn" onClick={() => openProduct(product)}>{t('Edit')}</button>
                {variant.id && token && <VariantCostEditor variantId={variant.id} token={token} onSaved={cost_amount => {
                  setProducts(current => current.map(item => item.id === product.id ? {
                    ...item,
                    product_variants: item.product_variants.map(size => size.id === variant.id ? { ...size, variant_costs: { cost_amount } } : size),
                  } : item))
                }} />}
                {stockSchemaReady && !variant.is_preorder && variant.id && token && <StockAdjustment variantId={variant.id} token={token} reload={load} />}
              </div>
            </li>
          })}
          {(view === 'products' ? productMatches.length : stockMatches.length) === 0 ? <li className="catalog-admin__no-results">{t('No products match these filters.')}</li> : null}
        </ul>
      <div className="crm-pagination"><button className="text-btn" disabled={currentPage === 1} onClick={() => setPage(currentPage - 1)}>{t('Previous')}</button><span>{currentPage} / {pages}</span><button className="text-btn" disabled={currentPage === pages} onClick={() => setPage(currentPage + 1)}>{t('Next')}</button></div>
      </section>
      </>)}
        {draft && <section className="product-editor catalog-product-workspace">
          <div className="product-editor__head">
            <h2 ref={editorHeading} tabIndex={-1}>{draft.id ? t('Edit product') : t('New product')}</h2>
            <div className="actions">
              {draft.id && <button type="button" className="text-btn product-editor__delete" disabled={saving || categoryBusy} onClick={() => void deleteProduct()}>
                {t(deleting ? 'Deleting…' : 'Delete product')}
              </button>}
              <button type="button" className="text-btn" disabled={saving || categoryBusy} onClick={closeEditor}>{t('Close')}</button>
            </div>
          </div>
          <div className="product-editor__translations">
            {(['uk', 'en'] as const).map(locale => <div key={locale}>
              <label className="field">
                <span>{t(locale === 'uk' ? 'Name in Ukrainian' : 'Name in English')}</span>
                <input value={draft.names[locale]} onChange={event => setDraft({ ...draft, names: { ...draft.names, [locale]: event.target.value } })} />
              </label>
              <label className="field">
                <span>{t(locale === 'uk' ? 'Description in Ukrainian' : 'Description in English')}</span>
                <textarea rows={3} value={draft.descriptions[locale]} onChange={event => setDraft({ ...draft, descriptions: { ...draft.descriptions, [locale]: event.target.value } })} />
              </label>
            </div>)}
          </div>
          <p className="muted">{t('When a translation is blank, the store shows the text from the other language.')}</p>
          <label className="field">
            <span>{t('Price, UAH')}</span>
            <input type="number" min="0" step="0.01" value={draft.price} disabled={saving} onChange={event => setDraft({ ...draft, price: event.target.value })} />
            {hasDifferentPrices && <small>{t('Sizes currently have different prices. Saving applies this price to all sizes.')}</small>}
          </label>
          <label className="field">
            <span>{t('Item weight, g')}</span>
            <input type="number" min="1" max="2147483647" step="1" value={draft.weightGrams} disabled={saving}
              onChange={event => setDraft({ ...draft, weightGrams: event.target.value })} />
          </label>
          <details className="customer-section"><summary>{t('Product information')}</summary>
            <label className="field">{t('Size guide and measurements')}<textarea rows={5} maxLength={10000} value={draft.sizeGuide} onChange={event => setDraft({ ...draft, sizeGuide: event.target.value })} /></label>
            <label className="field"><span>{t('Size guide image')}</span><input type="file" accept="image/jpeg,image/png,image/webp" disabled={saving} onChange={event => {
              const file = event.target.files?.[0]
              if (file) setDraft({ ...draft, sizeGuideImageFile: file })
              event.target.value = ''
            }} /><small>{t('JPG, PNG or WebP · up to 5 MB per file')}</small></label>
            {(draft.sizeGuideImageFile || draft.sizeGuideImageUrl) && <div className="size-guide-editor">
              {draft.sizeGuideImageFile ? <LocalImagePreview file={draft.sizeGuideImageFile} /> : <img src={draft.sizeGuideImageUrl} alt={t('Size guide image')} />}
              <button type="button" className="text-btn" disabled={saving} onClick={() => setDraft({ ...draft, sizeGuideImageFile: null, sizeGuideImageUrl: '' })}>{t('Remove image')}</button>
            </div>}
            <label className="field">{t('Composition')}<textarea rows={3} maxLength={10000} value={draft.composition} onChange={event => setDraft({ ...draft, composition: event.target.value })} /></label>
            <label className="field">{t('Care instructions')}<textarea rows={3} maxLength={10000} value={draft.careInstructions} onChange={event => setDraft({ ...draft, careInstructions: event.target.value })} /></label>
          </details>
          <fieldset className="catalog-category-picker" disabled={saving || categoryBusy}>
            <legend>{t('Categories')}</legend>
            {groups.length === 0 && <p className="muted">{t('No categories yet.')}</p>}
            {groups.map(({ parent, children }) => {
              const checked = draft.categoryIds.includes(parent.id)
              return <div className="catalog-category-picker__branch" key={parent.id}>
                <label className="check">
                  <input type="checkbox" checked={checked} onChange={event => toggleCategory(parent, event.target.checked)} />
                  {categoryLabel(parent, language)}
                </label>
                {checked && children.length > 0 && <div className="catalog-category-picker__children">
                  {children.map(child => <label className="check" key={child.id}>
                    <input type="checkbox" checked={draft.categoryIds.includes(child.id)} onChange={event => toggleCategory(child, event.target.checked)} />
                    {categoryLabel(child, language)}
                  </label>)}
                </div>}
              </div>
            })}
            {!showCategories && <button type="button" className="text-btn" onClick={() => {
              resetCategoryForm()
              setShowCategories(true)
            }}>{t('Create category or subcategory')}</button>}
          </fieldset>
          {categoryManager}
          <label className="field"><span>{t('Upload images')}</span><input type="file" accept="image/jpeg,image/png,image/webp" multiple onChange={(event) => setDraft({ ...draft, newImageFiles: [...draft.newImageFiles, ...Array.from(event.target.files ?? [])] })} /><small>{t('JPG, PNG or WebP · up to 5 MB per file')}</small></label>
          {draft.images.length > 0 || draft.newImageFiles.length > 0 ? <div className="image-manager">
            {draft.images.filter((image) => !draft.removedImageIds.includes(image.id)).map((image) => <figure key={image.id} style={{ order: draft.newImagesFirst ? 1 : 0 }} className="image-manager__item" draggable onDragStart={() => { draggedImage.current = image.id }} onDragEnd={() => { draggedImage.current = null }} onDragOver={event => event.preventDefault()} onDrop={event => { event.preventDefault(); if (draggedImage.current) moveImage(draggedImage.current, image.id); draggedImage.current = null }}><img src={image.public_url} alt={t('Product')} draggable={false} />
              <button type="button" className="text-btn" onClick={() => { setDraft(current => current ? { ...current, newImagesFirst: false } : current); moveImage(image.id, draft.images.find(item => !draft.removedImageIds.includes(item.id))?.id ?? image.id) }}>{t('Set as main image')}</button><button type="button" className="text-btn" onClick={() => setDraft({ ...draft, removedImageIds: [...draft.removedImageIds, image.id] })}>{t('Remove')}</button></figure>)}
            {draft.newImageFiles.map((file, index) => <figure key={`${file.name}-${index}`} style={{ order: draft.newImagesFirst ? 0 : 1 }} className="image-manager__item" draggable onDragStart={() => { draggedFile.current = index }} onDragEnd={() => { draggedFile.current = null }} onDragOver={event => event.preventDefault()} onDrop={event => { event.preventDefault(); if (draggedFile.current !== null) moveFile(draggedFile.current, index); draggedFile.current = null }}>
              <LocalImagePreview file={file} />
              <button type="button" className="text-btn" onClick={() => { setDraft(current => current ? { ...current, newImagesFirst: true } : current); moveFile(index, 0) }}>{t('Set as main image')}</button>
              <button type="button" className="text-btn" disabled={index === 0} onClick={() => moveFile(index, index - 1)}>{t('Move earlier')}</button>
              <button type="button" className="text-btn" disabled={index === draft.newImageFiles.length - 1} onClick={() => moveFile(index, index + 1)}>{t('Move later')}</button>
              <button type="button" className="text-btn" onClick={() => setDraft({ ...draft, newImageFiles: draft.newImageFiles.filter((_, fileIndex) => fileIndex !== index) })}>{t('Remove')}</button>
            </figure>)}
          </div> : null}
          <label className="check"><input type="checkbox" checked={draft.isActive} onChange={(event) => setDraft({ ...draft, isActive: event.target.checked })} /> {t('Published in storefront')}</label>
          <label className="check"><input type="checkbox" checked={draft.isNew} onChange={event => setDraft({ ...draft, isNew: event.target.checked })} /> {t('Mark as new')}</label>
          <div className="variant-editor"><div className="product-editor__head"><h3>{t('Sizes and stock')}</h3><button type="button" className="text-btn" onClick={() => setDraft({ ...draft, variants: [...draft.variants, blankVariant()] })}>{t('Add size')}</button></div>
            {draft.variants.map((variant, index) => <div className="variant-editor__row" key={variant.key}>
              <label className="variant-field"><span>{t('Size')}</span><input value={variant.name} onChange={(event) => updateVariant(index, 'name', event.target.value)} /></label>
              <label className="variant-field"><span>{t('SKU')}</span><input value={variant.sku} onChange={(event) => updateVariant(index, 'sku', event.target.value)} /></label>
              {!variant.is_preorder && <>
                <label className="variant-field"><span>{t('Stock, units')}</span><input type="number" min="0" disabled={stockSchemaReady && Boolean(variant.id)} value={variant.stock_quantity} onChange={event => updateVariant(index, 'stock_quantity', Number(event.target.value))} /></label>
                {stockSchemaReady && <label className="variant-field"><span>{t('Low stock threshold')}</span><input type="number" min="0" value={variant.low_stock_threshold} onChange={event => updateVariant(index, 'low_stock_threshold', Number(event.target.value))} /></label>}
              </>}
              <label className="variant-field"><span>{t('Unit cost, UAH')}</span><input type="number" min="0" max="21474836.47" step="0.01"
                value={variant.unitCost} disabled={saving} onChange={event => updateVariant(index, 'unitCost', event.target.value)} /></label>
              <label title={t('Pre-order')}><input type="checkbox" checked={variant.is_preorder} onChange={(event) => updateVariant(index, 'is_preorder', event.target.checked)} /> {t('Pre-order')}</label>
              <button type="button" className="text-btn" disabled={draft.variants.length === 1} onClick={() => removeVariant(index)}>{t('Remove')}</button>
            </div>)}
          </div>
          <div className="actions">
            <button type="button" className="btn" disabled={saving || categoryBusy} onClick={() => void save()}>{t(saving && !deleting ? 'Saving…' : 'Save product')}</button>
            <button type="button" className="btn btn--ghost" disabled={saving || categoryBusy} onClick={closeEditor}>{t('Cancel')}</button>
          </div>
        </section>}
    </section>
  )
}
