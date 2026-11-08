import { LocalImagePreview } from '../components/LocalImagePreview'
import { VariantCostEditor } from '../components/VariantCostEditor'
import { VariantPriceEditor } from '../components/VariantPriceEditor'
import { StockAdjustment } from '../components/StockAdjustment'
import { useCallback, useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { useToast } from '../context/ToastContext'
import { supabaseConfigured, supabaseRequest, uploadProductImage } from '../lib/supabase'
import { fetchAll, hasStoreMembership } from '../lib/crm'

type Category = { id: string; name: string; position: number }
type Variant = {
  id?: string
  name: string
  sku: string
  price: number
  compare_at_price: number | null
  stock_quantity: number
  low_stock_threshold: number
  is_preorder: boolean
}
type ProductImage = { id: string; public_url: string; storage_path: string; position: number }
type DraftVariant = Variant & { key: string }
type CatalogProduct = {
  size_guide?: string
  composition?: string
  care_instructions?: string
  id: string
  name: string
  description: string
  category_id: string | null
  is_active: boolean
  product_images: ProductImage[]
  product_variants: Variant[]
}
type Draft = {
  key: string
  newImagesFirst: boolean
  sizeGuide: string
  composition: string
  careInstructions: string
  id?: string
  name: string
  description: string
  categoryId: string
  isActive: boolean
  images: ProductImage[]
  newImageFiles: File[]
  removedImageIds: string[]
  variants: DraftVariant[]
}

const blankVariant = (): DraftVariant => ({ key: crypto.randomUUID(), name: 'M', sku: '', price: 0, compare_at_price: null, stock_quantity: 0, low_stock_threshold: 3, is_preorder: false })
const blankDraft = (): Draft => ({ key: crypto.randomUUID(), newImagesFirst: false, sizeGuide: '', composition: '', careInstructions: '', name: '', description: '', categoryId: '', isActive: true, images: [], newImageFiles: [], removedImageIds: [], variants: [blankVariant()] })
const categorySlug = (name: string) => `${name.normalize('NFKC').toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu, '-').replace(/^-|-$/g, '') || 'category'}-${crypto.randomUUID().slice(0, 8)}`

function toDraft(product: CatalogProduct): Draft {
  return {
    key: product.id,
    newImagesFirst: false,
    sizeGuide: product.size_guide ?? '', composition: product.composition ?? '', careInstructions: product.care_instructions ?? '',
    id: product.id,
    name: product.name,
    description: product.description,
    categoryId: product.category_id ?? '',
    isActive: product.is_active,
    images: [...product.product_images].sort((a, b) => a.position - b.position),
    newImageFiles: [],
    removedImageIds: [],
    variants: product.product_variants.map((variant) => ({ ...variant, key: variant.id ?? crypto.randomUUID(), price: Number(variant.price) / 100, compare_at_price: variant.compare_at_price === null ? null : Number(variant.compare_at_price) / 100 })),
  }
}

type CatalogView = 'products' | 'stock'
type StockFilter = 'all' | 'low' | 'out'

export function CatalogAdminPage({ embedded = false, initialView = 'products' }: { embedded?: boolean; initialView?: CatalogView }) {
  const { t } = useTranslation()
  const { store } = useStore()
  const { token, user } = useAuth()
  const { addToast } = useToast()
  const [member, setMember] = useState<boolean | null>(null)
  const [stockSchemaReady, setStockSchemaReady] = useState(false)
  const [products, setProducts] = useState<CatalogProduct[]>([])
  const [categories, setCategories] = useState<Category[]>([])
  const [draft, setDraft] = useState<Draft | null>(null)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [view, setView] = useState<CatalogView>(initialView)
  const [stockFilter, setStockFilter] = useState<StockFilter>(initialView === 'stock' ? 'low' : 'all')
  const [stockSelection, setStockSelection] = useState<Record<string, string>>({})
  const [categoryFilter, setCategoryFilter] = useState('all')
  const [showCategories, setShowCategories] = useState(false)
  const [categoryName, setCategoryName] = useState('')
  const [editingCategoryId, setEditingCategoryId] = useState<string | null>(null)
  const [categoryBusy, setCategoryBusy] = useState(false)
  const [selected, setSelected] = useState<string[]>([])
  const [bulkAction, setBulkAction] = useState('')
  const [page, setPage] = useState(1)
  const query = search.trim().toLowerCase()
  const searchedProducts = products.filter(product => `${product.name} ${product.product_variants.map(variant => variant.sku).join(' ')}`.toLowerCase().includes(query))
  const lowCount = products.flatMap(product => product.product_variants).filter(variant => !variant.is_preorder && variant.stock_quantity < variant.low_stock_threshold).length
  const outCount = products.flatMap(product => product.product_variants).filter(variant => !variant.is_preorder && variant.stock_quantity === 0).length
  const productMatches = searchedProducts.filter(product => categoryFilter === 'all' || product.category_id === categoryFilter)
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
  const dirty = draft !== null && (draft.newImageFiles.length > 0 || JSON.stringify(draft) !== originalDraft)
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
  const closeEditor = () => {
    if (dirty && !window.confirm(t('Discard unsaved changes?'))) return
    setDraft(null)
    setShowCategories(false)
    setEditingCategoryId(null)
    setCategoryName('')
    setError(null)
  }
  const openProduct = (product: CatalogProduct) => beginDraft(toDraft(product))
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
        fetchAll<CatalogProduct>(`/rest/v1/products?store_id=eq.${encodeURIComponent(store.id)}&select=*,product_images(id,public_url,storage_path,position),product_variants(id,name,sku,price,compare_at_price,stock_quantity,is_preorder${includeThreshold ? ',low_stock_threshold' : ''})&order=position.asc,id.asc&product_variants.order=position.asc,id.asc`, token)
      const [catalog, nextCategories] = await Promise.all([
        productQuery(true).then(products => ({ products, hasThreshold: true })).catch(async (cause: unknown) => {
          if (!(cause instanceof Error) || !/column .*low_stock_threshold.*does not exist/i.test(cause.message)) throw cause
          return { products: await productQuery(false), hasThreshold: false }
        }),
        supabaseRequest<Category[]>(`/rest/v1/categories?store_id=eq.${encodeURIComponent(store.id)}&select=id,name,position&order=position.asc`, { token }),
      ])
      setMember(true)
      setStockSchemaReady(catalog.hasThreshold)
      setProducts(catalog.products.map(product => ({
        ...product,
        product_variants: product.product_variants.map(variant => ({
          ...variant,
          low_stock_threshold: variant.low_stock_threshold ?? 3,
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

  const updateVariant = (index: number, field: keyof Variant, value: string | number | boolean | null) => {
    setDraft((current) => current ? {
      ...current,
      variants: current.variants.map((variant, itemIndex) => itemIndex === index ? { ...variant, [field]: value } : variant),
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
    const name = categoryName.trim()
    if (!name) { setError(t('Enter a category name.')); return }
    if (categories.some(category => category.id !== editingCategoryId && category.name.toLocaleLowerCase() === name.toLocaleLowerCase())) {
      setError(t('This category already exists.'))
      return
    }
    setCategoryBusy(true)
    setError(null)
    try {
      if (editingCategoryId) {
        await supabaseRequest(`/rest/v1/categories?id=eq.${encodeURIComponent(editingCategoryId)}&store_id=eq.${encodeURIComponent(store.id)}`, { method: 'PATCH', token, body: JSON.stringify({ name }) })
        setCategories(current => current.map(category => category.id === editingCategoryId ? { ...category, name } : category))
      } else {
        const created = await supabaseRequest<Category[]>('/rest/v1/categories', {
          method: 'POST', token, headers: { Prefer: 'return=representation' },
          body: JSON.stringify({ store_id: store.id, name, slug: categorySlug(name), position: Math.max(-1, ...categories.map(category => category.position)) + 1 }),
        })
        const category = created[0]
        if (!category) throw new Error(t('Could not create category.'))
        setCategories(current => [...current, category])
        setDraft(current => current ? { ...current, categoryId: category.id } : current)
      }
      setCategoryName('')
      setEditingCategoryId(null)
      if (draft) setShowCategories(false)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('Could not save category.'))
    } finally {
      setCategoryBusy(false)
    }
  }

  const deleteCategory = async (category: Category) => {
    if (!store || !token || categoryBusy) return
    if (products.some(product => product.category_id === category.id)) { setError(t('Move products to another category first.')); return }
    if (!window.confirm(t('Delete category "{{name}}"?', { name: category.name }))) return
    setCategoryBusy(true)
    setError(null)
    try {
      await supabaseRequest(`/rest/v1/categories?id=eq.${encodeURIComponent(category.id)}&store_id=eq.${encodeURIComponent(store.id)}`, { method: 'DELETE', token })
      setCategories(current => current.filter(item => item.id !== category.id))
      if (categoryFilter === category.id) setCategoryFilter('all')
      setDraft(current => current?.categoryId === category.id ? { ...current, categoryId: '' } : current)
      if (editingCategoryId === category.id) { setEditingCategoryId(null); setCategoryName('') }
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('Could not delete category.'))
    } finally {
      setCategoryBusy(false)
    }
  }

  const save = async () => {
    if (!store || !token || !draft || saving) return
    if (!draft.name.trim()) {
      setError('Product name is required')
      return
    }
    if (draft.variants.length === 0) {
      setError('Add at least one size or variant')
      return
    }
    setSaving(true)
    setError(null)
    try {
      const payload = {
        store_id: store.id,
        name: draft.name.trim(),
        description: draft.description.trim(),
        size_guide: draft.sizeGuide, composition: draft.composition, care_instructions: draft.careInstructions,
        category_id: draft.categoryId || null,
        is_active: draft.isActive,
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
          price: Math.max(0, Math.round(Number(variant.price) * 100)),
          compare_at_price: variant.compare_at_price === null || variant.compare_at_price === 0 ? null : Math.round(Number(variant.compare_at_price) * 100),
          ...(stockSchemaReady && { low_stock_threshold: variant.low_stock_threshold }),
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
            ...fields, id: variant.key, stock_quantity: variant.stock_quantity,
          }))),
        })
        for (const row of inserted ?? []) insertedIds.add(row.id)
      }
      await Promise.all(variants.filter(({ variant }) => !insertedIds.has(variant.key)).map(({ variant, fields }) =>
        supabaseRequest(`/rest/v1/product_variants?id=eq.${encodeURIComponent(variant.key)}&product_id=eq.${encodeURIComponent(productId)}`, {
          method: 'PATCH', token,
          body: JSON.stringify({ ...fields, ...(!stockSchemaReady && { stock_quantity: variant.stock_quantity }) }),
        }),
      ))

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
      await supabaseRequest(productPath, { method: 'PATCH', token, body: JSON.stringify(payload) })
      await load()
      setDraft(null)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not save product')
    } finally {
      setSaving(false)
    }
  }

  const applyBulk = async () => {
    if (!store || !token || !bulkAction || selected.length === 0 || saving) return
    const patch = bulkAction === 'publish' || bulkAction === 'hide'
      ? { is_active: bulkAction === 'publish' }
      : { category_id: bulkAction === 'uncategorized' ? null : bulkAction }
    setSaving(true)
    setError(null)
    try {
      await supabaseRequest(`/rest/v1/products?store_id=eq.${store.id}&id=in.(${selected.join(',')})`, {
        method: 'PATCH', token, body: JSON.stringify(patch),
      })
      setSelected([])
      setBulkAction('')
      addToast(t('Bulk changes applied'))
      await load()
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

  if (!store) return null
  if (!supabaseConfigured) return <section className="page-status"><h1>{t('CRM needs Supabase')}</h1></section>
  if (loading && member === null) return <div className="page-status">{t('Loading catalogue…')}</div>
  if (member === false) return <section className="page-status"><h1>{t('Manager access required')}</h1></section>

  const categoryManager = showCategories ? <section className="category-manager" aria-label={t('Manage categories')}>
    <div className="product-editor__head"><h3>{t(draft ? 'Create category' : 'Manage categories')}</h3>{draft && <button type="button" className="text-btn" disabled={categoryBusy} onClick={() => { setShowCategories(false); setCategoryName(''); setError(null) }}>{t('Cancel')}</button>}</div>
    <form className="category-manager__form" onSubmit={event => { event.preventDefault(); void saveCategory() }}>
      <label className="field"><span>{editingCategoryId ? t('Rename category') : t('New category')}</span><input value={categoryName} maxLength={100} onChange={event => setCategoryName(event.target.value)} /></label>
      <button type="submit" className="btn" disabled={categoryBusy}>{editingCategoryId ? t('Save') : t('Create category')}</button>
      {editingCategoryId && <button type="button" className="text-btn" disabled={categoryBusy} onClick={() => { setEditingCategoryId(null); setCategoryName(''); setError(null) }}>{t('Cancel')}</button>}
    </form>
    {!draft && <ul className="category-manager__list">{categories.map(category => {
      const used = products.filter(product => product.category_id === category.id).length
      return <li key={category.id}><div><strong>{category.name}</strong><span>{t('Products')}: {used}</span></div><button type="button" className="text-btn" disabled={categoryBusy} onClick={() => { setEditingCategoryId(category.id); setCategoryName(category.name) }}>{t('Rename')}</button><button type="button" className="text-btn" disabled={categoryBusy || used > 0} title={used > 0 ? t('Move products to another category first.') : undefined} onClick={() => void deleteCategory(category)}>{t('Delete')}</button></li>
    })}</ul>}
  </section> : null

  return (
    <section>
      <header className="page-head page-head--row">
        {!embedded ? <div><p className="muted">{store.name} · {t('management')}</p><h1>{t('Catalogue')}</h1></div> : <div />}
        {!draft && <div className="catalog-header-actions"><button type="button" className="btn btn--ghost" disabled={categoryBusy} onClick={() => { setShowCategories(current => !current); setEditingCategoryId(null); setCategoryName(''); setError(null) }}>{t(showCategories ? 'Products' : 'Manage categories')}</button>{!showCategories && <button type="button" className="btn" onClick={() => beginDraft(blankDraft())}>{t('Add product')}</button>}</div>}
      </header>
      {error ? <p className="error" role="alert">{error}</p> : null}
      {!draft && (showCategories ? categoryManager : <>
      <div className="catalog-summary">
        <button type="button" className={view === 'products' ? 'active' : ''} onClick={() => changeView('products')}><span>{t('Products')}</span><strong>{products.length}</strong></button>
        <button type="button" className={view === 'stock' && stockFilter === 'all' ? 'active' : ''} onClick={() => { changeView('stock'); setStockFilter('all') }}><span>{t('Stock units')}</span><strong>{products.reduce((sum, product) => sum + product.product_variants.reduce((count, variant) => count + (variant.is_preorder ? 0 : variant.stock_quantity), 0), 0)}</strong></button>
        <button type="button" className={view === 'stock' && stockFilter === 'low' ? 'active' : ''} onClick={() => { changeView('stock'); setStockFilter('low') }}><span>{t('Low stock')}</span><strong>{lowCount}</strong></button>
        <button type="button" className={view === 'stock' && stockFilter === 'out' ? 'active' : ''} onClick={() => { changeView('stock'); setStockFilter('out') }}><span>{t('Out of stock')}</span><strong>{outCount}</strong></button>
      </div>
      <div className="catalog-toolbar">
        <input aria-label={t('Search products')} placeholder={t('Search products')} value={search} onChange={event => { setSearch(event.target.value); setPage(1) }} />
        {view === 'products' ? <select aria-label={t('Category')} value={categoryFilter} onChange={event => { setCategoryFilter(event.target.value); setPage(1) }}><option value="all">{t('All categories')}</option>{categories.map(category => <option key={category.id} value={category.id}>{category.name}</option>)}</select> : <select aria-label={t('Stock filter')} value={stockFilter} onChange={event => { setStockFilter(event.target.value as StockFilter); setPage(1) }}><option value="all">{t('All stock')}</option><option value="low">{t('Low stock')}</option><option value="out">{t('Out of stock')}</option></select>}
      </div>
        {view === 'products' && selected.length > 0 && <div className="catalog-bulk" role="group" aria-label={t('Bulk action')}>
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
            <option value="uncategorized">{t('Uncategorized')}</option>
            {categories.map(category => <option key={category.id} value={category.id}>{t('Category')} · {category.name}</option>)}
          </select>
          <button type="button" className="btn" disabled={saving || !bulkAction} onClick={() => void applyBulk()}>{t(saving ? 'Saving…' : 'Apply')}</button>
          <button type="button" className="catalog-bulk__clear" disabled={saving} onClick={() => setSelected([])}>{t('Clear selection')}</button>
          </div>
        </div>}
        <ul className="catalog-admin__list">
          {view === 'products' && pageProducts.length > 1 && <li className="catalog-admin__selection-row">
            <label>
              <input type="checkbox" checked={pageSelected} disabled={saving}
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
          </li>}
          {view === 'products' ? pageProducts.map(product => {
            const unavailable = product.product_variants.filter(variant => !variant.is_preorder && variant.stock_quantity === 0).length
            return <li key={product.id} className={selected.includes(product.id) ? 'catalog-admin__selected' : undefined}>
              {product.product_images[0] ? <img className="catalog-admin__thumb" src={product.product_images[0].public_url} alt="" /> : <div className="catalog-admin__thumb catalog-admin__thumb--empty" aria-hidden="true" />}
              <div className="catalog-admin__item"><strong>{product.name}</strong><span>{categories.find(category => category.id === product.category_id)?.name ?? t('Uncategorized')} · {product.is_active ? t('Published') : t('Hidden')}</span><span>{product.product_variants.length} {t('variants')}{unavailable ? ` · ${unavailable} ${t('out of stock')}` : ''}</span></div>
              <div className="actions">
                <input type="checkbox" aria-label={`${t('Select product')} · ${product.name}`} checked={selected.includes(product.id)} disabled={saving} onChange={event => setSelected(current => event.target.checked ? [...current, product.id] : current.filter(id => id !== product.id))} />
                <button type="button" className="text-btn" onClick={() => openProduct(product)}>{t('Edit')}</button>
                {stockSchemaReady && <button type="button" className="text-btn" disabled={saving} onClick={() => void duplicate(product)}>{t('Duplicate')}</button>}
              </div>
            </li>
          }) : stockMatches.slice((currentPage - 1) * 20, currentPage * 20).map(({ product, variants }) => {
            const variant = variants.find(item => item.id === stockSelection[product.id]) ?? variants[0]
            return <li key={product.id} className="catalog-stock-row">
              {product.product_images[0] ? <img className="catalog-admin__thumb" src={product.product_images[0].public_url} alt="" /> : <div className="catalog-admin__thumb catalog-admin__thumb--empty" aria-hidden="true" />}
              <div className="catalog-admin__item">
                <strong>{product.name}</strong>
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
                {variant.id && token && <VariantPriceEditor key={variant.price} id={variant.id} price={variant.price} compareAtPrice={variant.compare_at_price} token={token} onSaved={load} />}
                {variant.id && token && <VariantCostEditor variantId={variant.id} token={token} />}
                {stockSchemaReady && variant.id && token && <StockAdjustment variantId={variant.id} token={token} reload={load} />}
              </div>
            </li>
          })}
          {(view === 'products' ? productMatches.length : stockMatches.length) === 0 ? <li className="catalog-admin__no-results">{t('No products match these filters.')}</li> : null}
        </ul>
      {pages > 1 && <div className="crm-pagination"><button className="text-btn" disabled={currentPage === 1} onClick={() => setPage(currentPage - 1)}>{t('Previous')}</button><span>{currentPage} / {pages}</span><button className="text-btn" disabled={currentPage === pages} onClick={() => setPage(currentPage + 1)}>{t('Next')}</button></div>}
      </>)}
        {draft && <section className="product-editor catalog-product-workspace">
          <div className="product-editor__head"><h2 ref={editorHeading} tabIndex={-1}>{draft.id ? t('Edit product') : t('New product')}</h2><button type="button" className="text-btn" disabled={saving || categoryBusy} onClick={closeEditor}>{t('Close')}</button></div>
          <label className="field"><span>{t('Name')}</span><input value={draft.name} onChange={(event) => setDraft({ ...draft, name: event.target.value })} /></label>
          <label className="field"><span>{t('Description')}</span><textarea rows={3} value={draft.description} onChange={(event) => setDraft({ ...draft, description: event.target.value })} /></label>
          <details className="customer-section"><summary>{t('Product information')}</summary>
            <label className="field">{t('Size guide and measurements')}<textarea rows={5} maxLength={10000} value={draft.sizeGuide} onChange={event => setDraft({ ...draft, sizeGuide: event.target.value })} /></label>
            <label className="field">{t('Composition')}<textarea rows={3} maxLength={10000} value={draft.composition} onChange={event => setDraft({ ...draft, composition: event.target.value })} /></label>
            <label className="field">{t('Care instructions')}<textarea rows={3} maxLength={10000} value={draft.careInstructions} onChange={event => setDraft({ ...draft, careInstructions: event.target.value })} /></label>
          </details>
          <div className="category-picker"><label className="field"><span>{t('Category')}</span><select value={draft.categoryId} onChange={(event) => setDraft({ ...draft, categoryId: event.target.value })}><option value="">{t('Uncategorized')}</option>{categories.map((category) => <option key={category.id} value={category.id}>{category.name}</option>)}</select></label>{!showCategories && <button type="button" className="text-btn" disabled={saving} onClick={() => { setEditingCategoryId(null); setCategoryName(''); setShowCategories(true) }}>{t('Create category')}</button>}</div>
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
          <div className="variant-editor"><div className="product-editor__head"><h3>{t('Sizes and stock')}</h3><button type="button" className="text-btn" onClick={() => setDraft({ ...draft, variants: [...draft.variants, blankVariant()] })}>{t('Add size')}</button></div>
            {draft.variants.map((variant, index) => <div className="variant-editor__row" key={variant.key}>
              <label className="variant-field"><span>{t('Size')}</span><input value={variant.name} onChange={(event) => updateVariant(index, 'name', event.target.value)} /></label>
              <label className="variant-field"><span>{t('SKU')}</span><input value={variant.sku} onChange={(event) => updateVariant(index, 'sku', event.target.value)} /></label>
              <label className="variant-field"><span>{t('Price, UAH')}</span><input type="number" min="0" value={variant.price} onChange={(event) => updateVariant(index, 'price', Number(event.target.value))} /></label>
              <label className="variant-field"><span>{t('Stock, units')}</span><input type="number" min="0" disabled={stockSchemaReady && Boolean(variant.id)} value={variant.stock_quantity} onChange={(event) => updateVariant(index, 'stock_quantity', Number(event.target.value))} /></label>
              {stockSchemaReady && <label className="variant-field"><span>{t('Low stock threshold')}</span><input type="number" min="0" value={variant.low_stock_threshold} onChange={event => updateVariant(index, 'low_stock_threshold', Number(event.target.value))} /></label>}
              <label title={t('Pre-order')}><input type="checkbox" checked={variant.is_preorder} onChange={(event) => updateVariant(index, 'is_preorder', event.target.checked)} /> {t('Pre-order')}</label>
              <button type="button" className="text-btn" disabled={draft.variants.length === 1} onClick={() => removeVariant(index)}>{t('Remove')}</button>
            </div>)}
          </div>
          <div className="actions"><button type="button" className="btn" disabled={saving || categoryBusy} onClick={() => void save()}>{saving ? t('Saving…') : t('Save product')}</button><button type="button" className="btn btn--ghost" disabled={saving || categoryBusy} onClick={closeEditor}>{t('Cancel')}</button></div>
        </section>}
    </section>
  )
}
