import { useCallback, useEffect, useState } from 'react'
import { Link } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { removeProductImage, supabaseConfigured, supabaseRequest, uploadProductImage } from '../lib/supabase'

type Category = { id: string; name: string }
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

export function CatalogAdminPage() {
  const { store } = useStore()
  const { token, user } = useAuth()
  const [member, setMember] = useState<boolean | null>(null)
  const [products, setProducts] = useState<CatalogProduct[]>([])
  const [categories, setCategories] = useState<Category[]>([])
  const [draft, setDraft] = useState<Draft | null>(null)
  const [loading, setLoading] = useState(true)
  const [saving, setSaving] = useState(false)
  const [error, setError] = useState<string | null>(null)

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
        supabaseRequest<CatalogProduct[]>(`/rest/v1/products?store_id=eq.${encodeURIComponent(store.id)}&select=id,name,description,category_id,is_active,product_images(id,public_url,storage_path),product_variants(id,name,sku,price,compare_at_price,stock_quantity,is_preorder)&order=position.asc`, { token }),
        supabaseRequest<Category[]>(`/rest/v1/categories?store_id=eq.${encodeURIComponent(store.id)}&select=id,name&order=position.asc`, { token }),
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
  if (!supabaseConfigured) return <section className="page-status"><h1>CRM needs Supabase</h1></section>
  if (loading && member === null) return <div className="page-status">Loading catalogue…</div>
  if (member === false) return <section className="page-status"><h1>Manager access required</h1></section>

  return (
    <section>
      <header className="page-head page-head--row">
        <div><p className="muted">{store.name} · management</p><h1>Catalogue</h1></div>
        <button type="button" className="btn" onClick={() => { setError(null); setDraft(blankDraft()) }}>Add product</button>
      </header>
      {error ? <p className="error">{error}</p> : null}
      <div className="catalog-admin">
        <ul className="catalog-admin__list">
          {products.map((product) => (
            <li key={product.id}>
              <div><strong>{product.name}</strong><span>{product.is_active ? 'Published' : 'Hidden'} · {product.product_variants.length} variants</span></div>
              <button type="button" className="text-btn" onClick={() => { setError(null); setDraft(toDraft(product)) }}>Edit</button>
            </li>
          ))}
        </ul>
        {draft ? <section className="product-editor">
          <div className="product-editor__head"><h2>{draft.id ? 'Edit product' : 'New product'}</h2><button type="button" className="text-btn" onClick={() => setDraft(null)}>Close</button></div>
          <label className="field"><span>Name</span><input value={draft.name} onChange={(event) => setDraft({ ...draft, name: event.target.value })} /></label>
          <label className="field"><span>Description</span><textarea rows={3} value={draft.description} onChange={(event) => setDraft({ ...draft, description: event.target.value })} /></label>
          <label className="field"><span>Category</span><select value={draft.categoryId} onChange={(event) => setDraft({ ...draft, categoryId: event.target.value })}><option value="">Uncategorized</option>{categories.map((category) => <option key={category.id} value={category.id}>{category.name}</option>)}</select></label>
          <label className="field"><span>Upload images</span><input type="file" accept="image/jpeg,image/png,image/webp" multiple onChange={(event) => setDraft({ ...draft, newImageFiles: [...draft.newImageFiles, ...Array.from(event.target.files ?? [])] })} /><small>JPG, PNG or WebP · up to 5 MB per file</small></label>
          {draft.images.length > 0 || draft.newImageFiles.length > 0 ? <div className="image-manager">
            {draft.images.filter((image) => !draft.removedImageIds.includes(image.id)).map((image) => <figure key={image.id} className="image-manager__item"><img src={image.public_url} alt="Product" /><button type="button" className="text-btn" onClick={() => setDraft({ ...draft, removedImageIds: [...draft.removedImageIds, image.id] })}>Remove</button></figure>)}
            {draft.newImageFiles.map((file, index) => <figure key={`${file.name}-${index}`} className="image-manager__item image-manager__file"><figcaption>{file.name}</figcaption><button type="button" className="text-btn" onClick={() => setDraft({ ...draft, newImageFiles: draft.newImageFiles.filter((_, fileIndex) => fileIndex !== index) })}>Remove</button></figure>)}
          </div> : null}
          <label className="check"><input type="checkbox" checked={draft.isActive} onChange={(event) => setDraft({ ...draft, isActive: event.target.checked })} /> Published in storefront</label>
          <div className="variant-editor"><div className="product-editor__head"><h3>Sizes and stock</h3><button type="button" className="text-btn" onClick={() => setDraft({ ...draft, variants: [...draft.variants, blankVariant()] })}>Add size</button></div>
            {draft.variants.map((variant, index) => <div className="variant-editor__row" key={variant.id ?? `new-${index}`}>
              <input aria-label="Size" value={variant.name} onChange={(event) => updateVariant(index, 'name', event.target.value)} />
              <input aria-label="SKU" placeholder="SKU" value={variant.sku} onChange={(event) => updateVariant(index, 'sku', event.target.value)} />
              <input aria-label="Price" type="number" min="0" value={variant.price} onChange={(event) => updateVariant(index, 'price', Number(event.target.value))} />
              <input aria-label="Stock" type="number" min="0" value={variant.stock_quantity} onChange={(event) => updateVariant(index, 'stock_quantity', Number(event.target.value))} />
              <label title="Pre-order"><input type="checkbox" checked={variant.is_preorder} onChange={(event) => updateVariant(index, 'is_preorder', event.target.checked)} /> Pre</label>
              <button type="button" className="text-btn" disabled={draft.variants.length === 1} onClick={() => removeVariant(index)}>Remove</button>
            </div>)}
          </div>
          <div className="actions"><button type="button" className="btn" disabled={saving} onClick={() => void save()}>{saving ? 'Saving…' : 'Save product'}</button><button type="button" className="btn btn--ghost" onClick={() => setDraft(null)}>Cancel</button></div>
        </section> : <section className="catalog-admin__empty"><h2>Select a product</h2><p className="muted">Edit its sizes, prices, availability and main image.</p><Link to="/">Open storefront</Link></section>}
      </div>
    </section>
  )
}
