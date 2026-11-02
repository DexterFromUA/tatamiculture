import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { removeProductImage, supabaseConfigured, supabaseRequest, uploadProductImage } from '../lib/supabase'
import { fetchAll } from '../lib/crm'

type Category = { id: string; name: string; position: number }
type Variant = {
  id?: string
  name: string
  sku: string
  price: number
  compare_at_price: number | null
  stock_quantity: number
  is_preorder: boolean
}
type ProductImage = { id: string; public_url: string; storage_path: string }
type CatalogProduct = {
  id: string
  name: string
  description: string
  category_id: string | null
  is_active: boolean
  product_images: ProductImage[]
  product_variants: Variant[]
}
type Draft = {
  id?: string
  name: string
  description: string
  categoryId: string
  isActive: boolean
  images: ProductImage[]
  newImageFiles: File[]
  removedImageIds: string[]
  variants: Variant[]
}

const blankVariant = (): Variant => ({ name: 'M', sku: '', price: 0, compare_at_price: null, stock_quantity: 0, is_preorder: false })
const blankDraft = (): Draft => ({ name: '', description: '', categoryId: '', isActive: true, images: [], newImageFiles: [], removedImageIds: [], variants: [blankVariant()] })
const categorySlug = (name: string) => `${name.normalize('NFKC').toLocaleLowerCase().replace(/[^\p{L}\p{N}]+/gu, '-').replace(/^-|-$/g, '') || 'category'}-${crypto.randomUUID().slice(0, 8)}`

function toDraft(product: CatalogProduct): Draft {
  return {
    id: product.id,
    name: product.name,
    description: product.description,
    categoryId: product.category_id ?? '',
    isActive: product.is_active,
    images: product.product_images,
    newImageFiles: [],
    removedImageIds: [],
    variants: product.product_variants.map((variant) => ({ ...variant, price: Number(variant.price) / 100, compare_at_price: variant.compare_at_price === null ? null : Number(variant.compare_at_price) / 100 })),
  }
}

type CatalogView = 'products' | 'stock'
type StockFilter = 'all' | 'low' | 'out'

export function CatalogAdminPage({ embedded = false, initialView = 'products' }: { embedded?: boolean; initialView?: CatalogView }) {
  const { t } = useTranslation()
  const { store } = useStore()
  const { token, user } = useAuth()
  const [member, setMember] = useState<boolean | null>(null)
  const [products, setProducts] = useState<CatalogProduct[]>([])
  const [categories, setCategories] = useState<Category[]>([])
  const [draft, setDraft] = useState<Draft | null>(null)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const [search, setSearch] = useState('')
  const [view, setView] = useState<CatalogView>(initialView)
  const [stockFilter, setStockFilter] = useState<StockFilter>(initialView === 'stock' ? 'low' : 'all')
  const [categoryFilter, setCategoryFilter] = useState('all')
  const [showCategories, setShowCategories] = useState(false)
  const [categoryName, setCategoryName] = useState('')
  const [editingCategoryId, setEditingCategoryId] = useState<string | null>(null)
  const [categoryBusy, setCategoryBusy] = useState(false)
  const [page, setPage] = useState(1)
  const query = search.trim().toLowerCase()
  const searchedProducts = products.filter(product => `${product.name} ${product.product_variants.map(variant => variant.sku).join(' ')}`.toLowerCase().includes(query))
  const stockRows = searchedProducts.flatMap(product => product.product_variants.map(variant => ({ product, variant })))
  const lowCount = products.flatMap(product => product.product_variants).filter(variant => !variant.is_preorder && variant.stock_quantity < 3).length
  const outCount = products.flatMap(product => product.product_variants).filter(variant => !variant.is_preorder && variant.stock_quantity === 0).length
  const productMatches = searchedProducts.filter(product => categoryFilter === 'all' || product.category_id === categoryFilter)
  const stockMatches = stockRows.filter(({ variant }) => stockFilter === 'all' || (!variant.is_preorder && (stockFilter === 'out' ? variant.stock_quantity === 0 : variant.stock_quantity < 3)))
  const pages = Math.max(1, Math.ceil((view === 'products' ? productMatches.length : stockMatches.length) / 20))
  const currentPage = Math.min(page, pages)
  const openProduct = (product: CatalogProduct) => { setError(null); setDraft(toDraft(product)) }
  const changeView = (next: CatalogView) => { setView(next); setPage(1); setDraft(null) }

  const load = useCallback(async () => {
    if (!store || !token || !user) return
    setLoading(true)
    try {
      const memberships = await supabaseRequest<Array<{ role: string }>>(
        `/rest/v1/store_members?store_id=eq.${encodeURIComponent(store.id)}&user_id=eq.${encodeURIComponent(user.id)}&select=role`,
        { token },
      )
      if (!memberships[0]) {
        setMember(false)
        return
      }
      const [nextProducts, nextCategories] = await Promise.all([
        fetchAll<CatalogProduct>(`/rest/v1/products?store_id=eq.${encodeURIComponent(store.id)}&select=id,name,description,category_id,is_active,product_images(id,public_url,storage_path),product_variants(id,name,sku,price,compare_at_price,stock_quantity,is_preorder)&order=position.asc,id.asc`, token),
        supabaseRequest<Category[]>(`/rest/v1/categories?store_id=eq.${encodeURIComponent(store.id)}&select=id,name,position&order=position.asc`, { token }),
      ])
      setMember(true)
      setProducts(nextProducts)
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
      setShowCategories(false)
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
    if (!store || !token || !draft) return
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
        category_id: draft.categoryId || null,
        is_active: draft.isActive,
      }
      let productId = draft.id
      if (productId) {
        await supabaseRequest<CatalogProduct[]>(`/rest/v1/products?id=eq.${encodeURIComponent(productId)}`, {
          method: 'PATCH', token, headers: { Prefer: 'return=representation' }, body: JSON.stringify(payload),
        })
      } else {
        const created = await supabaseRequest<CatalogProduct[]>('/rest/v1/products', {
          method: 'POST', token, headers: { Prefer: 'return=representation' }, body: JSON.stringify(payload),
        })
        productId = created[0]?.id
        if (!productId) throw new Error('Product could not be created')
      }

      const current = products.find((product) => product.id === productId)
      const keepIds = new Set(draft.variants.flatMap((variant) => variant.id ? [variant.id] : []))
      await Promise.all((current?.product_variants ?? []).filter((variant) => variant.id && !keepIds.has(variant.id)).map((variant) =>
        supabaseRequest(`/rest/v1/product_variants?id=eq.${encodeURIComponent(variant.id ?? '')}`, { method: 'DELETE', token }),
      ))
      await Promise.all(draft.variants.map((variant, position) => {
        const variantPayload = {
          product_id: productId,
          name: variant.name.trim() || 'One size',
          sku: variant.sku.trim() || null,
          price: Math.max(0, Math.round(Number(variant.price) * 100)),
          compare_at_price: variant.compare_at_price === null || variant.compare_at_price === 0 ? null : Math.round(Number(variant.compare_at_price) * 100),
          stock_quantity: Math.max(0, Math.round(Number(variant.stock_quantity))),
          is_preorder: variant.is_preorder,
          position,
        }
        return variant.id
          ? supabaseRequest(`/rest/v1/product_variants?id=eq.${encodeURIComponent(variant.id)}`, { method: 'PATCH', token, body: JSON.stringify(variantPayload) })
          : supabaseRequest('/rest/v1/product_variants', { method: 'POST', token, body: JSON.stringify(variantPayload) })
      }))

      const removedImages = draft.images.filter((image) => draft.removedImageIds.includes(image.id))
      const retainedImages = draft.images.filter((image) => !draft.removedImageIds.includes(image.id))
      await Promise.all(removedImages.map(async (image) => {
        await supabaseRequest(`/rest/v1/product_images?id=eq.${encodeURIComponent(image.id)}`, { method: 'DELETE', token })
        await removeProductImage(image.storage_path, token)
      }))
      await Promise.all(retainedImages.map((image, position) =>
        supabaseRequest(`/rest/v1/product_images?id=eq.${encodeURIComponent(image.id)}`, { method: 'PATCH', token, body: JSON.stringify({ position }) }),
      ))
      const uploadedImages = await Promise.all(draft.newImageFiles.map((file) => uploadProductImage(productId, file, token)))
      await Promise.all(uploadedImages.map((image, index) =>
        supabaseRequest('/rest/v1/product_images', {
          method: 'POST', token,
          body: JSON.stringify({ product_id: productId, public_url: image.publicUrl, storage_path: image.storagePath, position: retainedImages.length + index }),
        }),
      ))
      await load()
      setDraft(null)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not save product')
    } finally {
      setSaving(false)
    }
  }

  if (!store) return null
  if (!supabaseConfigured) return <section className="page-status"><h1>{t('CRM needs Supabase')}</h1></section>
  if (loading && member === null) return <div className="page-status">{t('Loading catalogue…')}</div>
  if (member === false) return <section className="page-status"><h1>{t('Manager access required')}</h1></section>

  const categoryManager = showCategories ? <section className="category-manager" aria-label={t('Manage categories')}>
    <div className="product-editor__head"><h3>{t('Manage categories')}</h3><button type="button" className="text-btn" onClick={() => { setShowCategories(false); setEditingCategoryId(null); setCategoryName('') }}>{t('Close')}</button></div>
    <form className="category-manager__form" onSubmit={event => { event.preventDefault(); void saveCategory() }}>
      <label className="field"><span>{editingCategoryId ? t('Rename category') : t('New category')}</span><input value={categoryName} maxLength={100} onChange={event => setCategoryName(event.target.value)} /></label>
      <button type="submit" className="btn" disabled={categoryBusy}>{editingCategoryId ? t('Save') : t('Create category')}</button>
    </form>
    <ul className="category-manager__list">{categories.map(category => {
      const used = products.filter(product => product.category_id === category.id).length
      return <li key={category.id}><div><strong>{category.name}</strong><span>{t('Products')}: {used}</span></div><button type="button" className="text-btn" disabled={categoryBusy} onClick={() => { setEditingCategoryId(category.id); setCategoryName(category.name) }}>{t('Rename')}</button><button type="button" className="text-btn" disabled={categoryBusy || used > 0} title={used > 0 ? t('Move products to another category first.') : undefined} onClick={() => void deleteCategory(category)}>{t('Delete')}</button></li>
    })}</ul>
  </section> : null

  return (
    <section>
      <header className="page-head page-head--row">
        {!embedded ? <div><p className="muted">{store.name} · {t('management')}</p><h1>{t('Catalogue')}</h1></div> : <div />}
        <div className="catalog-header-actions"><button type="button" className="btn btn--ghost" onClick={() => { setShowCategories(current => !current); setEditingCategoryId(null); setCategoryName('') }}>{t('Manage categories')}</button><button type="button" className="btn" onClick={() => { setError(null); setDraft(blankDraft()) }}>{t('Add product')}</button></div>
      </header>
      {error ? <p className="error">{error}</p> : null}
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
      <div className="crm-pagination"><button className="text-btn" disabled={currentPage === 1} onClick={() => setPage(currentPage - 1)}>{t('Previous')}</button><span>{currentPage} / {pages}</span><button className="text-btn" disabled={currentPage === pages} onClick={() => setPage(currentPage + 1)}>{t('Next')}</button></div>
      <div className="catalog-admin">
        <ul className="catalog-admin__list">
          {view === 'products' ? productMatches.slice((currentPage - 1) * 20, currentPage * 20).map(product => {
            const unavailable = product.product_variants.filter(variant => !variant.is_preorder && variant.stock_quantity === 0).length
            return <li key={product.id} className={draft?.id === product.id ? 'active' : ''}>
              {product.product_images[0] ? <img className="catalog-admin__thumb" src={product.product_images[0].public_url} alt="" /> : <div className="catalog-admin__thumb catalog-admin__thumb--empty" aria-hidden="true" />}
              <div className="catalog-admin__item"><strong>{product.name}</strong><span>{categories.find(category => category.id === product.category_id)?.name ?? t('Uncategorized')} · {product.is_active ? t('Published') : t('Hidden')}</span><span>{product.product_variants.length} {t('variants')}{unavailable ? ` · ${unavailable} ${t('out of stock')}` : ''}</span></div>
              <button type="button" className="text-btn" onClick={() => openProduct(product)}>{t('Edit')}</button>
            </li>
          }) : stockMatches.slice((currentPage - 1) * 20, currentPage * 20).map(({ product, variant }, index) => <li key={variant.id ?? `${product.id}-${index}`} className={draft?.id === product.id ? 'active' : ''}>
            {product.product_images[0] ? <img className="catalog-admin__thumb" src={product.product_images[0].public_url} alt="" /> : <div className="catalog-admin__thumb catalog-admin__thumb--empty" aria-hidden="true" />}
            <div className="catalog-admin__item"><strong>{product.name} · {variant.name}</strong><span>{variant.sku || t('No SKU')} · {product.is_active ? t('Published') : t('Hidden')}</span><span className={!variant.is_preorder && variant.stock_quantity < 3 ? 'stock-low' : ''}>{variant.is_preorder ? t('Pre-order') : `${variant.stock_quantity} ${t('in stock')}`}</span></div>
            <button type="button" className="text-btn" onClick={() => openProduct(product)}>{t('Edit')}</button>
          </li>)}
          {(view === 'products' ? productMatches.length : stockMatches.length) === 0 ? <li className="catalog-admin__no-results">{t('No products match these filters.')}</li> : null}
        </ul>
        {draft ? <section className="product-editor">
          <div className="product-editor__head"><h2>{draft.id ? t('Edit product') : t('New product')}</h2><button type="button" className="text-btn" onClick={() => setDraft(null)}>{t('Close')}</button></div>
          <label className="field"><span>{t('Name')}</span><input value={draft.name} onChange={(event) => setDraft({ ...draft, name: event.target.value })} /></label>
          <label className="field"><span>{t('Description')}</span><textarea rows={3} value={draft.description} onChange={(event) => setDraft({ ...draft, description: event.target.value })} /></label>
          <div className="category-picker"><label className="field"><span>{t('Category')}</span><select value={draft.categoryId} onChange={(event) => setDraft({ ...draft, categoryId: event.target.value })}><option value="">{t('Uncategorized')}</option>{categories.map((category) => <option key={category.id} value={category.id}>{category.name}</option>)}</select></label><button type="button" className="text-btn" onClick={() => { setEditingCategoryId(null); setCategoryName(''); setShowCategories(true) }}>{t('Create category')}</button></div>
          {categoryManager}
          <label className="field"><span>{t('Upload images')}</span><input type="file" accept="image/jpeg,image/png,image/webp" multiple onChange={(event) => setDraft({ ...draft, newImageFiles: [...draft.newImageFiles, ...Array.from(event.target.files ?? [])] })} /><small>{t('JPG, PNG or WebP · up to 5 MB per file')}</small></label>
          {draft.images.length > 0 || draft.newImageFiles.length > 0 ? <div className="image-manager">
            {draft.images.filter((image) => !draft.removedImageIds.includes(image.id)).map((image) => <figure key={image.id} className="image-manager__item"><img src={image.public_url} alt={t('Product')} /><button type="button" className="text-btn" onClick={() => setDraft({ ...draft, removedImageIds: [...draft.removedImageIds, image.id] })}>{t('Remove')}</button></figure>)}
            {draft.newImageFiles.map((file, index) => <figure key={`${file.name}-${index}`} className="image-manager__item image-manager__file"><figcaption>{file.name}</figcaption><button type="button" className="text-btn" onClick={() => setDraft({ ...draft, newImageFiles: draft.newImageFiles.filter((_, fileIndex) => fileIndex !== index) })}>{t('Remove')}</button></figure>)}
          </div> : null}
          <label className="check"><input type="checkbox" checked={draft.isActive} onChange={(event) => setDraft({ ...draft, isActive: event.target.checked })} /> {t('Published in storefront')}</label>
          <div className="variant-editor"><div className="product-editor__head"><h3>{t('Sizes and stock')}</h3><button type="button" className="text-btn" onClick={() => setDraft({ ...draft, variants: [...draft.variants, blankVariant()] })}>{t('Add size')}</button></div>
            {draft.variants.map((variant, index) => <div className="variant-editor__row" key={variant.id ?? `new-${index}`}>
              <label className="variant-field"><span>{t('Size')}</span><input value={variant.name} onChange={(event) => updateVariant(index, 'name', event.target.value)} /></label>
              <label className="variant-field"><span>{t('SKU')}</span><input value={variant.sku} onChange={(event) => updateVariant(index, 'sku', event.target.value)} /></label>
              <label className="variant-field"><span>{t('Price, UAH')}</span><input type="number" min="0" value={variant.price} onChange={(event) => updateVariant(index, 'price', Number(event.target.value))} /></label>
              <label className="variant-field"><span>{t('Stock, units')}</span><input type="number" min="0" value={variant.stock_quantity} onChange={(event) => updateVariant(index, 'stock_quantity', Number(event.target.value))} /></label>
              <label title={t('Pre-order')}><input type="checkbox" checked={variant.is_preorder} onChange={(event) => updateVariant(index, 'is_preorder', event.target.checked)} /> {t('Pre-order')}</label>
              <button type="button" className="text-btn" disabled={draft.variants.length === 1} onClick={() => removeVariant(index)}>{t('Remove')}</button>
            </div>)}
          </div>
          <div className="actions"><button type="button" className="btn" disabled={saving} onClick={() => void save()}>{saving ? t('Saving…') : t('Save product')}</button><button type="button" className="btn btn--ghost" onClick={() => setDraft(null)}>{t('Cancel')}</button></div>
        </section> : categoryManager ?? <section className="catalog-admin__empty"><h2>{t('Select a product')}</h2><p className="muted">{t('Edit its sizes, prices, availability and main image.')}</p><Link to="/">{t('Open storefront')}</Link></section>}
      </div>
    </section>
  )
}
