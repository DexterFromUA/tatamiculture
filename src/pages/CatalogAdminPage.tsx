import { LocalImagePreview } from '../components/LocalImagePreview'
import { CatalogCostInput } from '../components/CatalogCostInput'
import { VariantCostEditor } from '../components/VariantCostEditor'
import { StockAdjustment } from '../components/StockAdjustment'
import { ConfirmationDialog } from '../components/ConfirmationDialog'
import { ImportMantoDialog } from '../components/ImportMantoDialog'
import { MantoRefreshButton } from '../components/MantoRefreshButton'
import { ToggleSwitch } from '../components/ToggleSwitch'
import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { useToast } from '../context/ToastContext'
import { SupabaseError, supabaseConfigured, supabaseRequest, uploadProductImage } from '../lib/supabase'
import { crmPageSize, fetchAll, hasStoreMembership } from '../lib/crm'
import { useCrmPage } from '../hooks/useCrmPage'
import { CrmPagination } from '../components/CrmPagination'
import { categoryGroups, categoryLabel, categoryPaths } from '../lib/categories'
import { costInputAmount, parseUnitCost, saveCatalogCosts, type CatalogCost, type CatalogExchangeRate, type CostCurrency } from '../lib/catalogCosts'
import { formatPrice } from '../lib/format'
import { getCatalogImportSettings } from '../lib/catalogImportSettings'
import { downloadMantoPhotos, getMantoDraftPricing, getMantoSourceLinks, readMantoProduct, refreshMantoSnapshot, saveMantoSnapshot, type MantoSource, type MantoSourceLink } from '../lib/mantoImport'
import { mantoProductLink } from '../../supabase/functions/crm-import-manto/product'
import { getSizeGuideImageUrls, maxSizeGuideImages, productName } from '../lib/productText'
import type { CatalogCategory, ProductText } from '../types'

type Variant = {
  id?: string
  name: string
  sku: string
  price: number
  compare_at_price: number | null
  discount_percent?: number | null
  stack_customer_discount?: boolean
  stock_quantity: number
  low_stock_threshold: number
  is_preorder: boolean
  allow_out_of_stock: boolean
  manto_variant_key?: string | null
  variant_costs: CatalogCost | null
}
type ProductImage = { id: string; public_url: string; storage_path: string; position: number }
type DraftVariant = Omit<Variant, 'price' | 'variant_costs' | 'stock_quantity' | 'low_stock_threshold'> & {
  key: string; unitCost: string; currency: CostCurrency; unitCostEdited: boolean
  discountPercent: string; stackCustomerDiscount: boolean
  stock_quantity: string; low_stock_threshold: string
}
type CatalogProduct = ProductText & {
  discount_percent?: number | null
  stack_customer_discount?: boolean
  size_guide_extra_image_urls?: string[]
  size_guide?: string
  size_guide_en?: string
  composition_en?: string
  care_instructions_en?: string
  size_guide_image_url?: string
  composition?: string
  care_instructions?: string
  id: string
  created_at: string
  updated_at: string
  category_id: string | null
  product_categories: Array<{ category_id: string }>
  is_active: boolean
  is_new: boolean
  weight_grams: number | null
  product_images: ProductImage[]
  product_variants: Variant[]
  product_costs: CatalogCost | null
}

function ProductTimestamps({ product }: { product: CatalogProduct }) {
  const { t, i18n } = useTranslation()
  const formatter = new Intl.DateTimeFormat(i18n.resolvedLanguage === 'en' ? 'en-GB' : 'uk-UA', {
    day: '2-digit', month: 'short', year: 'numeric', hour: '2-digit', minute: '2-digit', timeZone: 'Europe/Kyiv',
  })
  return <div className="catalog-product-dates">
    <span>{t('Added')} <time dateTime={product.created_at}>{formatter.format(new Date(product.created_at))}</time></span>
    <span>{t('Updated')} <time dateTime={product.updated_at}>{formatter.format(new Date(product.updated_at))}</time></span>
  </div>
}
type SizeGuideDraftImage = { key: string } & ({ file: File } | { url: string })

type Draft = {
  key: string
  imageOrder: string[]
  sizeGuide: Record<'uk' | 'en', string>
  sizeGuideImages: SizeGuideDraftImage[]
  composition: Record<'uk' | 'en', string>
  careInstructions: Record<'uk' | 'en', string>
  id?: string
  names: Record<'uk' | 'en', string>
  descriptions: Record<'uk' | 'en', string>
  price: string
  discountPercent: string
  stackCustomerDiscount: boolean
  defaultCost: string
  defaultCostCurrency: CostCurrency
  defaultCostEdited: boolean
  weightGrams: string
  categoryIds: string[]
  isActive: boolean
  isNew: boolean
  images: ProductImage[]
  newImageFiles: File[]
  removedImageIds: string[]
  variants: DraftVariant[]
  mantoSource?: MantoSource
}

const defaultLowStockThreshold = 3
const blankVariant = (): DraftVariant => ({ key: crypto.randomUUID(), name: 'M', sku: '', compare_at_price: null, stock_quantity: '0', low_stock_threshold: String(defaultLowStockThreshold), is_preorder: false, allow_out_of_stock: false, unitCost: '', currency: 'UAH', unitCostEdited: false, discountPercent: '', stackCustomerDiscount: false })
const blankDraft = (): Draft => ({ key: crypto.randomUUID(), imageOrder: [], sizeGuide: { uk: '', en: '' }, sizeGuideImages: [], composition: { uk: '', en: '' }, careInstructions: { uk: '', en: '' }, names: { uk: '', en: '' }, descriptions: { uk: '', en: '' }, price: '0', discountPercent: '', stackCustomerDiscount: false, defaultCost: '', defaultCostCurrency: 'UAH', defaultCostEdited: false, weightGrams: '', categoryIds: [], isActive: true, isNew: false, images: [], newImageFiles: [], removedImageIds: [], variants: [blankVariant()] })

function validDiscountPercent(value: string) {
  if (!value.trim()) return true
  const percent = Number(value)
  return Number.isFinite(percent) && percent >= 0 && percent <= 100 && Math.abs(percent * 100 - Math.round(percent * 100)) < 1e-8
}

function CatalogDiscountFields({ percent, stacking, variant = false, disabled, onPercentChange, onStackingChange }: {
  percent: string; stacking: boolean; variant?: boolean; disabled: boolean
  onPercentChange: (value: string) => void; onStackingChange: (value: boolean) => void
}) {
  const { t } = useTranslation()
  const inherits = variant && percent === ''
  return <div className="catalog-discount-fields">
    <label className="field">
      <span>{t(variant ? 'Size discount, %' : 'Product discount, %')}</span>
      <input type="number" min="0" max="100" step="0.01" value={percent} disabled={disabled}
        onChange={event => onPercentChange(event.target.value)} />
      {variant && <small>{t('Leave blank to use the product discount. Enter 0 for no size discount.')}</small>}
    </label>
    <label className="check switch-field"><ToggleSwitch checked={!inherits && stacking} disabled={disabled || inherits}
      onChange={event => onStackingChange(event.target.checked)} />{t('Combine with personal discount')}</label>
  </div>
}
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
    imageOrder: [...product.product_images].sort((a, b) => a.position - b.position).map(image => `saved:${image.id}`),
    sizeGuide: { uk: product.size_guide ?? '', en: product.size_guide_en ?? '' },
    composition: { uk: product.composition ?? '', en: product.composition_en ?? '' },
    careInstructions: { uk: product.care_instructions ?? '', en: product.care_instructions_en ?? '' },
    sizeGuideImages: getSizeGuideImageUrls(product.size_guide_image_url, product.size_guide_extra_image_urls)
      .map((url, index) => ({ key: `saved-${index}`, url })),
    id: product.id,
    names,
    descriptions,
    price: String(Number(product.product_variants[0]?.price ?? 0) / 100),
    discountPercent: product.discount_percent == null ? '' : String(product.discount_percent),
    stackCustomerDiscount: product.stack_customer_discount === true,
    defaultCost: costInputAmount(product.product_costs),
    defaultCostCurrency: product.product_costs?.currency ?? 'UAH',
    defaultCostEdited: false,
    weightGrams: product.weight_grams == null ? '' : String(product.weight_grams),
    categoryIds: assignedCategoryIds(product),
    isActive: product.is_active,
    isNew: product.is_new === true,
    images: [...product.product_images].sort((a, b) => a.position - b.position),
    newImageFiles: [],
    removedImageIds: [],
    variants: product.product_variants.map(({ id, name, sku, compare_at_price, stock_quantity, low_stock_threshold, is_preorder, allow_out_of_stock, variant_costs, discount_percent, stack_customer_discount, manto_variant_key }) => ({
      key: id ?? crypto.randomUUID(), id, name, sku, compare_at_price, is_preorder, allow_out_of_stock, manto_variant_key,
      stock_quantity: String(stock_quantity), low_stock_threshold: String(low_stock_threshold),
      discountPercent: discount_percent == null ? '' : String(discount_percent),
      stackCustomerDiscount: stack_customer_discount === true,
      unitCost: costInputAmount(variant_costs),
      currency: variant_costs?.currency ?? (manto_variant_key ? product.product_costs?.currency : null) ?? 'UAH',
      unitCostEdited: false,
    })),
  }
}

type CatalogFilter = 'all' | 'published' | 'hidden' | 'stock' | 'low-stock' | 'out-of-stock'

export function CatalogAdminPage({ embedded = false, initialSearch = '', initialFilter = 'all' }: {
  embedded?: boolean; initialSearch?: string; initialFilter?: CatalogFilter
}) {
  const { t, i18n } = useTranslation()
  const language = i18n.resolvedLanguage
  const { store, refreshProducts } = useStore()
  const { token, user } = useAuth()
  const { addToast } = useToast()
  const storeId = store?.id
  const [member, setMember] = useState<boolean | null>(null)
  const [rates, setRates] = useState<CatalogExchangeRate[]>([])
  const [categories, setCategories] = useState<CatalogCategory[]>([])
  const [categoryCounts, setCategoryCounts] = useState<Record<string, number> | null>(null)
  const [draft, setDraft] = useState<Draft | null>(null)
  const [mantoImportOpen, setMantoImportOpen] = useState(false)
  const [openedProduct, setOpenedProduct] = useState<CatalogProduct | null>(null)
  const [savedMantoSource, setSavedMantoSource] = useState<(MantoSource & { product_id: string }) | null>(null)
  const [pageMantoSources, setPageMantoSources] = useState<{ key: string; links: Map<string, MantoSourceLink> }>()
  const [refreshingManto, setRefreshingManto] = useState(false)
  const [mantoRefreshError, setMantoRefreshError] = useState('')
  const [saving, setSaving] = useState(false)
  const [deleting, setDeleting] = useState(false)
  const [productToDelete, setProductToDelete] = useState<CatalogProduct | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [search, setSearch] = useState(initialSearch)
  const [filter, setFilter] = useState<CatalogFilter>(initialFilter)
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
  const [catalogRevision, setCatalogRevision] = useState(0)
  const reloadCatalogue = () => setCatalogRevision(revision => revision + 1)
  const catalogue = useCrmPage<CatalogProduct>('crm_catalog_page', {
    p_store_id: storeId, p_search: search.trim(), p_filter: filter,
    p_category_id: categoryFilter === 'all' ? null : categoryFilter,
  }, page, member ? token : null, catalogRevision)
  const products = catalogue.data?.rows ?? []
  const loading = member === null || catalogue.loading
  const groups = categoryGroups(categories, language)
  const categoryOptions = groups.flatMap(({ parent, children }) => [
    { category: parent, label: categoryLabel(parent, language) },
    ...children.map(category => ({ category, label: `${categoryLabel(parent, language)} / ${categoryLabel(category, language)}` })),
  ])
  const editingCategory = categories.find(category => category.id === editingCategoryId)
  const editingProduct = products.find(product => product.id === draft?.id) ?? (openedProduct?.id === draft?.id ? openedProduct : null)
  const mantoSource = (savedMantoSource?.product_id === draft?.id ? savedMantoSource : null) ?? draft?.mantoSource
  const mantoLink = mantoProductLink(mantoSource?.snapshot.url)?.url
  const savedVariants = editingProduct?.product_variants
  const hasDifferentPrices = savedVariants?.some(variant => Number(variant.price) !== Number(savedVariants[0].price))
  const showStock = filter === 'stock' || filter === 'low-stock' || filter === 'out-of-stock'
  const stockMatches = showStock ? products.map(product => ({
    product,
    variants: product.product_variants.filter(variant =>
      filter === 'stock' || (filter === 'out-of-stock'
        ? variant.stock_quantity === 0
        : variant.stock_quantity < variant.low_stock_threshold)),
  })).filter(({ variants }) => variants.length > 0) : []
  const matchCount = catalogue.data?.total ?? 0
  const pages = Math.max(1, Math.ceil(matchCount / crmPageSize))
  const currentPage = catalogue.data?.page ?? 1
  const pageProducts = products
  const mantoPageProductIds = pageProducts.map(product => product.id).join(',')
  const mantoPageKey = `${storeId}:${mantoPageProductIds}`
  const mantoLinks = pageMantoSources?.key === mantoPageKey ? pageMantoSources.links : undefined
  useEffect(() => {
    if (!member || !storeId || !token || !mantoPageProductIds) return
    const request = new AbortController()
    void getMantoSourceLinks(storeId, mantoPageProductIds, token, request.signal).then(links => {
      if (!request.signal.aborted) setPageMantoSources({ key: mantoPageKey, links })
    }).catch(() => {})
    return () => request.abort()
  }, [member, storeId, token, mantoPageProductIds, mantoPageKey])

  const mantoRefreshButton = (productId: string) => {
    const source = mantoLinks?.get(productId)
    return source && storeId && token
      ? <MantoRefreshButton storeId={storeId} productId={productId} token={token} source={source} disabled={saving || categoryBusy} />
      : null
  }

  const pageProductIds = new Set(pageProducts.map(product => product.id))
  const selectedOutsidePage = selected.filter(id => !pageProductIds.has(id)).length
  const pageSelected = pageProducts.length > 0 && pageProducts.every(product => selected.includes(product.id))
  const draggedPhoto = useRef<number | null>(null)
  const productList = useRef<HTMLUListElement>(null)
  const addProductButton = useRef<HTMLButtonElement>(null)
  const editorHeading = useRef<HTMLHeadingElement>(null)
  const listScroll = useRef<{ productId?: string; scrollY: number; buttonTop: number } | null>(null)
  const savedStock = useRef(new Map<string, number>())
  const imageIds = useRef(new WeakMap<File, string>())
  const mantoRefresh = useRef<AbortController | null>(null)
  useEffect(() => () => mantoRefresh.current?.abort(), [])
  const editorOpen = draft !== null
  useLayoutEffect(() => {
    if (!editorOpen) return
    editorHeading.current?.focus({ preventScroll: true })
    window.scrollTo({ top: 0, behavior: 'instant' })
  }, [editorOpen])
  useLayoutEffect(() => {
    const savedScroll = listScroll.current
    if (editorOpen || loading || !savedScroll || !productList.current) return

    const button = savedScroll.productId
      ? Array.from(productList.current.querySelectorAll<HTMLButtonElement>('[data-edit-product]'))
        .find(item => item.dataset.editProduct === savedScroll.productId)
      : addProductButton.current
    const top = button
      ? window.scrollY + button.getBoundingClientRect().top - savedScroll.buttonTop
      : savedScroll.scrollY
    window.scrollTo({ top, behavior: 'instant' })
    button?.focus({ preventScroll: true })
    listScroll.current = null
  }, [editorOpen, loading])
  const [originalDraft, setOriginalDraft] = useState('')
  const dirty = draft !== null && (draft.newImageFiles.length > 0 || JSON.stringify(draft) !== originalDraft)
  useEffect(() => {
    if (!dirty) return
    const preventExit = (event: BeforeUnloadEvent) => event.preventDefault()
    const preventNavigation = (event: MouseEvent) => {
      if (!(event.target instanceof Element)) return
      if (event.target.closest('.product-workspace__source a[target="_blank"]')) return
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

  const loadDraft = (next: Draft, existingProduct: CatalogProduct | null = null) => {
    savedStock.current = new Map(next.variants.filter(variant => variant.id)
      .map(variant => [variant.key, Number(variant.stock_quantity)]))
    setOriginalDraft(next.mantoSource && !next.id ? '' : JSON.stringify(next))
    setError(null)
    setSavedMantoSource(null)
    setMantoRefreshError('')
    setOpenedProduct(existingProduct)
    setDraft(next)
  }
  const beginDraft = (next: Draft, button: HTMLButtonElement) => {
    listScroll.current = {
      productId: next.id,
      scrollY: Math.max(0, window.scrollY),
      buttonTop: button.getBoundingClientRect().top,
    }
    loadDraft(next)
  }
  const closeSavedEditor = () => {
    mantoRefresh.current?.abort()
    mantoRefresh.current = null
    setRefreshingManto(false)
    setMantoRefreshError('')
    setDraft(null)
    setOpenedProduct(null)
    setSavedMantoSource(null)
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
  const openProduct = (product: CatalogProduct, button: HTMLButtonElement) => beginDraft(toDraft(product, language), button)

  const importManto = async (link: string, signal: AbortSignal) => {
    if (!store || !token) throw new Error('Sign in required')
    const storeId = store.id
    const product = await readMantoProduct(storeId, token, link, signal)
    const source = { manto_product_id: product.id, snapshot: product.snapshot }
    const sourcePath = `/rest/v1/manto_product_sources?store_id=eq.${storeId}&manto_product_id=eq.${product.id}`
    const [linked] = await supabaseRequest<{ product_id: string }[]>(`${sourcePath}&select=product_id`, {
      token, signal, cache: 'no-store',
    })
    if (linked) {
      const [existing] = await supabaseRequest<CatalogProduct[]>(`/rest/v1/products?id=eq.${linked.product_id}&store_id=eq.${storeId}&select=*,product_categories(category_id),product_images(*),product_costs(*),product_variants(*,variant_costs(*))&product_variants.order=position.asc,id.asc`, {
        token, signal, cache: 'no-store',
      })
      if (!existing) throw new Error('Could not load catalogue')
      await saveMantoSnapshot(storeId, existing.id, source, token, signal)
      signal.throwIfAborted()
      loadDraft({ ...toDraft(existing, language), mantoSource: source }, existing)
      addToast(t('Manto snapshot updated'))
      return
    }

    const imageUrls = [...new Set([...product.imageUrls, ...(product.sizeGuide ? [product.sizeGuide] : [])])]
    const [photos, settings] = await Promise.all([
      downloadMantoPhotos(storeId, token, imageUrls, signal),
      getCatalogImportSettings(storeId, token, signal),
    ])
    signal.throwIfAborted()
    const pricing = getMantoDraftPricing(source.snapshot, store.currency, rates, settings)
    const costCurrency = source.snapshot.currency ?? 'UAH'
    const newImageFiles = product.imageUrls.flatMap(url => {
      const file = photos.get(url)
      return file ? [file] : []
    })
    const sizeGuide = product.sizeGuide ? photos.get(product.sizeGuide) : undefined
    const sourceCategory = source.snapshot.category.trim().toLowerCase()
    const matching = sourceCategory ? categories.filter(category =>
      [category.name_en, category.name].some(name => name?.trim().toLowerCase() === sourceCategory)) : []
    const category = matching.length === 1 ? matching[0] : undefined
    loadDraft({
      ...blankDraft(),
      names: { uk: '', en: product.name },
      descriptions: { uk: '', en: product.description },
      composition: { uk: '', en: product.composition },
      weightGrams: product.weightGrams ? String(product.weightGrams) : '',
      price: pricing.price,
      defaultCost: pricing.defaultCost,
      defaultCostCurrency: pricing.defaultCost ? costCurrency : 'UAH',
      defaultCostEdited: pricing.defaultCost !== '',
      isActive: false,
      categoryIds: category ? [category.id, ...(category.parent_id ? [category.parent_id] : [])] : [],
      imageOrder: newImageFiles.map((_, index) => `new:${index}`),
      newImageFiles,
      sizeGuideImages: sizeGuide ? [{ key: crypto.randomUUID(), file: sizeGuide }] : [],
      mantoSource: source,
      variants: source.snapshot.variants.map(item => {
        const unitCost = pricing.variantCosts.get(item.key) ?? ''
        return {
          ...blankVariant(), name: item.name, sku: item.sku, manto_variant_key: item.key,
          stock_quantity: String(item.quantity ?? 0),
          unitCost, unitCostEdited: unitCost !== '', currency: unitCost || pricing.defaultCost ? costCurrency : 'UAH',
        }
      }),
    })
    if (pricing.priceMessage) addToast(t(pricing.priceMessage))
    if (photos.size < imageUrls.length) addToast(t('Some Manto images could not be downloaded.'))
  }

  const refreshManto = async () => {
    if (!storeId || !token || !draft || !mantoSource || !mantoLink || saving || mantoRefresh.current) return
    const request = new AbortController()
    mantoRefresh.current = request
    setRefreshingManto(true)
    setMantoRefreshError('')
    try {
      const source = await refreshMantoSnapshot(storeId, token, mantoLink.href, mantoSource.manto_product_id, request.signal, draft.id)
      if (draft.id) setSavedMantoSource({ ...source, product_id: draft.id })
      else setDraft(current => current?.key === draft.key ? { ...current, mantoSource: source } : current)
      addToast(t('Manto snapshot updated'))
    } catch (cause) {
      if (!request.signal.aborted) {
        setMantoRefreshError(cause instanceof Error ? cause.message : 'Could not update Manto data.')
      }
    } finally {
      if (mantoRefresh.current === request) {
        mantoRefresh.current = null
        setRefreshingManto(false)
      }
    }
  }

  const draftId = draft?.id
  const importedInEditor = Boolean(draft?.mantoSource)
  useEffect(() => {
    if (!draftId || !storeId || !token || importedInEditor) return
    const abort = new AbortController()
    void supabaseRequest<(MantoSource & { product_id: string })[]>(
      `/rest/v1/manto_product_sources?store_id=eq.${storeId}&product_id=eq.${draftId}&select=product_id,manto_product_id,snapshot`,
      { token, signal: abort.signal, cache: 'no-store' },
    ).then(([source]) => {
      if (!abort.signal.aborted) setSavedMantoSource(source ?? null)
    }).catch(() => {})
    return () => abort.abort()
  }, [draftId, importedInEditor, storeId, token])

  const userId = user?.id
  useEffect(() => {
    if (!storeId || !token || !userId) return
    const abort = new AbortController()
    void hasStoreMembership(storeId, userId, token, abort.signal).then(async allowed => {
      if (abort.signal.aborted) return
      if (!allowed) { setMember(false); return }
      const [nextCategories, nextRates] = await Promise.all([
        fetchAll<CatalogCategory>(`/rest/v1/categories?store_id=eq.${storeId}&select=*&order=position.asc,id.asc`, token, abort.signal),
        supabaseRequest<CatalogExchangeRate[]>('/rest/v1/catalog_exchange_rates?select=currency,uah_rate,rate_date', {
          token, signal: abort.signal, cache: 'no-store',
        }).catch(() => []),
      ])
      if (abort.signal.aborted) return
      setCategories(nextCategories); setRates(nextRates); setMember(true)
    }).catch(cause => { if (!abort.signal.aborted) setError(cause instanceof Error ? cause.message : 'Could not load catalogue') })
    return () => abort.abort()
  }, [storeId, token, userId])

  useEffect(() => {
    if (!showCategories || !member || !token || !storeId) return
    const abort = new AbortController()
    void supabaseRequest<Array<{ category_id: string; product_count: number }>>('/rest/v1/rpc/crm_catalog_category_counts', {
      method: 'POST', token, signal: abort.signal, body: JSON.stringify({ p_store_id: storeId }),
    }).then(rows => {
      if (!abort.signal.aborted) setCategoryCounts(Object.fromEntries(rows.map(row => [row.category_id, row.product_count])))
    }).catch(cause => { if (!abort.signal.aborted) setError(cause instanceof Error ? cause.message : 'Could not load catalogue') })
    return () => abort.abort()
  }, [showCategories, member, token, storeId, catalogRevision])

  const updateVariant = (index: number, field: Exclude<keyof DraftVariant, 'unitCostEdited'>, value: string | number | boolean | null) => {
    setDraft((current) => current ? {
      ...current,
      variants: current.variants.map((variant, itemIndex) => itemIndex === index
        ? { ...variant, [field]: value, unitCostEdited: variant.unitCostEdited || field === 'unitCost' }
        : variant),
    } : current)
  }

  const movePhoto = (from: number, to: number) => {
    setDraft(current => {
      if (!current || from < 0 || to < 0 || from >= current.imageOrder.length || to >= current.imageOrder.length || from === to) return current
      const imageOrder = [...current.imageOrder]
      const [photo] = imageOrder.splice(from, 1)
      imageOrder.splice(to, 0, photo)
      return { ...current, imageOrder }
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
        refreshProducts()
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
    if (categoryCounts?.[category.id]) return 'Move products to another category first.'
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
    if (!store || !token || !draft || saving || mantoRefresh.current) return
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
    if (!validDiscountPercent(draft.discountPercent) || draft.variants.some(variant => !validDiscountPercent(variant.discountPercent))) {
      setError(t('Enter a discount from 0 to 100% with up to two decimal places.'))
      return
    }
    if (draft.variants.some(variant => [variant.stock_quantity, variant.low_stock_threshold].some(value => {
      const quantity = Number(value)
      return !Number.isInteger(quantity) || quantity < 0 || quantity > 2147483647
    }))) {
      setError(t('Enter whole, non-negative numbers for stock and its threshold.'))
      return
    }
    const weightGrams = draft.weightGrams === '' ? null : Number(draft.weightGrams)
    if (weightGrams !== null && (!Number.isInteger(weightGrams) || weightGrams <= 0 || weightGrams > 2147483647)) {
      setError(t('Enter a positive weight in whole grams.'))
      return
    }
    const defaultCost = parseUnitCost(draft.defaultCost)
    const costs = draft.variants.filter(variant => variant.unitCostEdited).map(variant => ({
      variant_id: variant.key,
      cost_amount: parseUnitCost(variant.unitCost),
      currency: variant.currency,
    }))
    if (defaultCost === undefined || costs.some(cost => cost.cost_amount === undefined)) {
      setError(t('Enter a valid unit cost.'))
      return
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
        size_guide: draft.sizeGuide.uk, size_guide_en: draft.sizeGuide.en,
        composition: draft.composition.uk, composition_en: draft.composition.en,
        care_instructions: draft.careInstructions.uk, care_instructions_en: draft.careInstructions.en,
        is_active: draft.isActive,
        is_new: draft.isNew,
        weight_grams: weightGrams,
        discount_percent: draft.discountPercent === '' ? null : Number(draft.discountPercent),
        stack_customer_discount: draft.stackCustomerDiscount,
      }
      const productId = draft.key
      const productPath = `/rest/v1/products?id=eq.${encodeURIComponent(productId)}&store_id=eq.${encodeURIComponent(store.id)}`
      if (!draft.id && draft.mantoSource) {
        await supabaseRequest('/rest/v1/rpc/reserve_manto_product', {
          method: 'POST', token, body: JSON.stringify({
            p_store_id: store.id, p_product_id: productId, p_name: name,
            p_manto_product_id: draft.mantoSource.manto_product_id, p_snapshot: draft.mantoSource.snapshot,
          }),
        })
      } else if (!draft.id) {
        // Keep an unfinished product off the storefront and reuse its ID on retry.
        await supabaseRequest('/rest/v1/products?on_conflict=id', {
          method: 'POST', token, headers: { Prefer: 'resolution=ignore-duplicates' },
          body: JSON.stringify({ ...payload, id: productId, is_active: false }),
        })
      }

      const sizeGuideImageUrls: string[] = []
      for (const image of draft.sizeGuideImages) {
        if ('url' in image) {
          sizeGuideImageUrls.push(image.url)
          continue
        }
        const { publicUrl } = await uploadProductImage(productId, image.file, token, image.key)
        sizeGuideImageUrls.push(publicUrl)
        // Keep completed uploads in the draft if a later step fails.
        setDraft(current => current?.key === productId ? {
          ...current,
          sizeGuideImages: current.sizeGuideImages.map(item => item.key === image.key ? { key: item.key, url: publicUrl } : item),
        } : current)
      }

      const current = products.find((product) => product.id === productId)
      const keepIds = new Set(draft.variants.map(variant => variant.key))
      const knownIds = new Set([
        ...(current?.product_variants ?? []).flatMap(variant => variant.id ? [variant.id] : []),
        ...savedStock.current.keys(),
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
          ...(variant.manto_variant_key ? { manto_variant_key: variant.manto_variant_key } : {}),
          price,
          compare_at_price: variant.compare_at_price && Number(variant.compare_at_price) >= price ? variant.compare_at_price : null,
          discount_percent: variant.discountPercent === '' ? null : Number(variant.discountPercent),
          stack_customer_discount: variant.discountPercent !== '' && variant.stackCustomerDiscount,
          is_preorder: variant.is_preorder,
          allow_out_of_stock: variant.allow_out_of_stock,
          position,
        },
      }))
      const newVariants = variants.filter(({ variant }) => !variant.id)
      const insertedIds = new Set<string>()
      if (newVariants.length > 0) {
        for (const { variant } of newVariants) {
          if (!savedStock.current.has(variant.key)) savedStock.current.set(variant.key, Number(variant.stock_quantity))
        }
        const inserted = await supabaseRequest<{ id: string }[]>('/rest/v1/product_variants?on_conflict=id&select=id', {
          method: 'POST', token, headers: { Prefer: 'resolution=ignore-duplicates,return=representation' },
          body: JSON.stringify(newVariants.map(({ variant, fields }) => ({
            ...fields,
            id: variant.key,
            stock_quantity: Number(variant.stock_quantity),
            low_stock_threshold: Number(variant.low_stock_threshold),
          }))),
        })
        for (const row of inserted ?? []) insertedIds.add(row.id)
        for (const { variant } of newVariants) {
          if (insertedIds.has(variant.key)) savedStock.current.set(variant.key, Number(variant.stock_quantity))
        }
      }
      await Promise.all(variants.filter(({ variant }) => !insertedIds.has(variant.key)).map(({ variant, fields }) =>
        supabaseRequest(`/rest/v1/product_variants?id=eq.${encodeURIComponent(variant.key)}&product_id=eq.${encodeURIComponent(productId)}`, {
          method: 'PATCH', token,
          body: JSON.stringify({
            ...fields,
            low_stock_threshold: Number(variant.low_stock_threshold),
          }),
        }),
      ))
      const removedImages = draft.images.filter((image) => draft.removedImageIds.includes(image.id))
      const retainedImages = draft.images.filter((image) => !draft.removedImageIds.includes(image.id))
      await Promise.all(removedImages.map(async (image) => {
        await supabaseRequest(`/rest/v1/product_images?id=eq.${encodeURIComponent(image.id)}`, { method: 'DELETE', token })
      }))
      await Promise.all(retainedImages.map(image =>
        supabaseRequest(`/rest/v1/product_images?id=eq.${encodeURIComponent(image.id)}`, { method: 'PATCH', token, body: JSON.stringify({ position: draft.imageOrder.indexOf(`saved:${image.id}`) }) }),
      ))
      const uploadedImages = await Promise.all(draft.newImageFiles.map(async file => {
        const id = imageIds.current.get(file) ?? crypto.randomUUID()
        imageIds.current.set(file, id)
        return { id, ...await uploadProductImage(productId, file, token, id) }
      }))
      await Promise.all(uploadedImages.map((image, index) =>
        supabaseRequest('/rest/v1/product_images?on_conflict=id', {
          method: 'POST', token, headers: { Prefer: 'resolution=merge-duplicates' },
          body: JSON.stringify({ id: image.id, product_id: productId, public_url: image.publicUrl, storage_path: image.storagePath, position: draft.imageOrder.indexOf(`new:${index}`) }),
        }),
      ))
      await setProductCategories([productId], draft.categoryIds, token)
      if (draft.defaultCostEdited || costs.length > 0) {
        await saveCatalogCosts(token, productId,
          draft.defaultCostEdited ? { amount: defaultCost, currency: draft.defaultCostCurrency } : null, costs)
      }
      await supabaseRequest(productPath, {
        method: 'PATCH', token, body: JSON.stringify({
          ...payload,
          size_guide_image_url: sizeGuideImageUrls[0] ?? '',
          size_guide_extra_image_urls: sizeGuideImageUrls.slice(1),
        }),
      })
      for (const { variant, fields } of variants) {
        const previousQuantity = savedStock.current.get(variant.key)
        const quantity = Number(variant.stock_quantity)
        if (previousQuantity === undefined || previousQuantity === quantity) continue

        const path = `/rest/v1/product_variants?id=eq.${encodeURIComponent(variant.key)}&product_id=eq.${encodeURIComponent(productId)}&select=stock_quantity`
        const updated = await supabaseRequest<Array<{ stock_quantity: number }>>(`${path}&stock_quantity=eq.${previousQuantity}`, {
          method: 'PATCH', token, headers: { Prefer: 'return=representation' },
          body: JSON.stringify({ stock_quantity: quantity }),
        })
        if (!updated?.length) {
          const [latest] = await supabaseRequest<Array<{ stock_quantity: number }>>(path, { token, cache: 'no-store' })
          if (!latest) throw new Error(t('This size is no longer available. Reload the catalogue.'))
          if (latest.stock_quantity !== quantity) {
            savedStock.current.set(variant.key, latest.stock_quantity)
            setDraft(current => current?.key === productId ? {
              ...current,
              variants: current.variants.map(entry => entry.key === variant.key
                ? { ...entry, stock_quantity: String(latest.stock_quantity) }
                : entry),
            } : current)
            throw new Error(t('Stock for {{size}} changed while editing. Review the current quantity and save again.', { size: fields.name }))
          }
        }
        savedStock.current.set(variant.key, quantity)
      }
      reloadCatalogue()
      refreshProducts()
      closeSavedEditor()
    } catch (cause) {
      setError(cause instanceof SupabaseError && cause.code === '23505' && !draft.id && draft.mantoSource
        ? 'This Manto product is already in the catalogue. Import the link again to open it.'
        : cause instanceof Error ? cause.message : 'Could not save product')
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
      reloadCatalogue()
      refreshProducts()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('Could not save product'))
    } finally {
      setSaving(false)
    }
  }

  const toggleProductVisibility = async (product: CatalogProduct) => {
    if (!store || !token || saving || categoryBusy) return
    const isActive = !product.is_active
    setSaving(true)
    setError(null)
    try {
      await supabaseRequest(`/rest/v1/products?store_id=eq.${store.id}&id=eq.${product.id}`, {
        method: 'PATCH', token, body: JSON.stringify({ is_active: isActive }),
      })
      addToast(t(isActive ? 'Published' : 'Hidden'))
      reloadCatalogue()
      refreshProducts()
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
      reloadCatalogue()
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('Could not save product'))
    } finally {
      setSaving(false)
    }
  }

  const requestProductDeletion = (productId: string) => {
    if (saving || categoryBusy) return
    const product = products.find(item => item.id === productId)
    if (product) setProductToDelete(product)
  }

  const deleteProduct = async (productId: string) => {
    if (!store || !token || !productId || saving || categoryBusy) return

    setSaving(true)
    setDeleting(true)
    setError(null)
    try {
      const deleted = await supabaseRequest<boolean>('/rest/v1/rpc/delete_catalog_product', {
        method: 'POST', token, body: JSON.stringify({ p_store_id: store.id, p_product_id: productId }),
      })
      setSelected(current => current.filter(id => id !== productId))
      if (draft?.id === productId) closeSavedEditor()
      addToast(t(deleted ? 'Product deleted' : 'Product no longer exists'))
      reloadCatalogue()
      refreshProducts()
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
  if (member === null) return <div className="page-status">{t(error ?? 'Loading catalogue…')}</div>
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
      const used = categoryCounts && (categoryCounts[category.id] ?? 0)
      const reason = categoryDeleteReason(category)
      return <li key={category.id} className={category.parent_id ? 'category-manager__subcategory' : undefined}>
        <div>
          <strong>{categoryLabel(category, language)}</strong>
          {(category.name_uk || category.name_en) && <span className="category-manager__translations">
            <span>UK: {category.name_uk || '—'}</span>
            <span>EN: {category.name_en || '—'}</span>
          </span>}
          <span>{t('Products')}: {used ?? '—'}</span>
        </div>
        <button type="button" className="text-btn" disabled={categoryBusy} onClick={() => {
          setEditingCategoryId(category.id)
          setCategoryNames({ uk: category.name_uk ?? '', en: category.name_en ?? '' })
          setCategoryParent(category.parent_id ?? '')
          setError(null)
        }}>{t('Edit')}</button>
        <button type="button" className="text-btn" disabled={categoryBusy || !categoryCounts || Boolean(reason)} title={reason ? t(reason) : undefined} onClick={() => void deleteCategory(category)}>{t('Delete')}</button>
      </li>
    })}</ul>}
  </section> : null

  return (
    <section>
      <header className={embedded ? 'crm-section-head catalog-section-head' : 'page-head page-head--row'}>
        {!embedded ? <div><p className="muted">{store.name} · {t('management')}</p><h1>{t('Catalogue')}</h1></div> : <div><span className="crm-section-head__label"><span>{store.name}</span> / CRM</span><h2>{t('Catalogue')}</h2></div>}
        {!draft && <div className="crm-section-actions"><button type="button" className="btn btn--ghost" disabled={categoryBusy} onClick={() => { setShowCategories(current => !current); resetCategoryForm() }}>{t(showCategories ? 'Products' : 'Manage categories')}</button>{!showCategories && <button ref={addProductButton} type="button" className="btn" onClick={event => beginDraft(blankDraft(), event.currentTarget)}>{t('Add product')}</button>}</div>}
      </header>
      {error && <p className="error" role="alert">{t(error)}</p>}
      {catalogue.error && !draft && !showCategories && <p className="error" role="alert">{t(catalogue.error)} <button type="button" className="text-btn" onClick={catalogue.retry}>{t('Try again')}</button></p>}
      {!draft && (showCategories ? categoryManager :
      <section className="crm-panel catalog-list-panel">
      <div className="catalog-toolbar">
        <input type="search" aria-label={t('Search by name or SKU')} placeholder={t('Search by name or SKU')} value={search} onChange={event => { setSearch(event.target.value); setPage(1) }} />
        <select aria-label={t('Category')} value={categoryFilter} onChange={event => { setCategoryFilter(event.target.value); setPage(1) }}>
          <option value="all">{t('All categories')}</option>
          {categoryOptions.map(({ category, label }) => <option key={category.id} value={category.id}>{label}</option>)}
        </select>
        <select aria-label={t('Catalogue filter')} value={filter} onChange={event => {
          setFilter(event.target.value as CatalogFilter)
          setPage(1)
        }}>
          <option value="all">{t('All products')}</option>
          <option value="published">{t('Published')}</option>
          <option value="hidden">{t('Hidden')}</option>
          <optgroup label={t('Inventory')}>
            <option value="stock">{t('All stock')}</option>
            <option value="low-stock">{t('Low stock')}</option>
            <option value="out-of-stock">{t('Out of stock')}</option>
          </optgroup>
        </select>
        <CrmPagination page={currentPage} pages={pages} loading={loading} onChange={setPage} />
      </div>
        {!showStock && (pageProducts.length > 0 || selected.length > 0) && <div className="order-bulk" role="group" aria-label={t('Bulk action')}>
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
        <ul ref={productList} className={`catalog-admin__list${!showStock ? ' catalog-admin__list--products' : ''}`}>
          {!showStock ? pageProducts.map(product => {
            const unavailable = product.product_variants.filter(variant => variant.stock_quantity === 0).length
            return <li key={product.id} className={selected.includes(product.id) ? 'catalog-admin__selected' : undefined}>
              <label className="order-select"><input type="checkbox" aria-label={`${t('Select product')} · ${productName(product, language)}`} checked={selected.includes(product.id)} disabled={saving} onChange={event => { const checked = event.target.checked; setSelected(current => checked ? [...current, product.id] : current.filter(id => id !== product.id)) }} /></label>
              {product.product_images[0] && <img className="catalog-admin__thumb" src={product.product_images[0].public_url} alt="" />}
              <div className="catalog-admin__item"><strong>{productName(product, language)}</strong><span>{categoryPaths(categories, assignedCategoryIds(product), language).join(' · ') || t('Uncategorized')} · {product.is_active ? t('Published') : t('Hidden')}{product.is_new && ` · ${t('New arrival')}`}</span><span>{product.product_variants.length} {t('variants')}{unavailable ? ` · ${unavailable} ${t('out of stock')}` : ''}</span><ProductTimestamps product={product} /></div>
              <div className="crm-order__actions catalog-admin__actions">
                <button type="button" className="text-btn" data-edit-product={product.id} onClick={event => openProduct(product, event.currentTarget)}>{t('Edit')}</button>
                <button type="button" className="text-btn" disabled={saving} onClick={() => void duplicate(product)}>{t('Duplicate')}</button>
                <button type="button" className="text-btn" disabled={saving || categoryBusy} onClick={() => void toggleProductVisibility(product)}>{t(product.is_active ? 'Hide' : 'Publish')}</button>
                {mantoRefreshButton(product.id)}
                <button type="button" className="text-btn product-editor__delete" disabled={saving || categoryBusy} onClick={() => requestProductDeletion(product.id)}>{t('Delete')}</button>
              </div>
            </li>
          }) : stockMatches.map(({ product, variants }) => {
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
                <span className={variant.stock_quantity < variant.low_stock_threshold ? 'stock-low' : ''}>{variant.stock_quantity} {t('in stock')}{variant.is_preorder && ` · ${t('Pre-order')}`}</span>
              </div>
              <div className="catalog-stock-row__actions" key={variant.id}>
                <button type="button" className="text-btn" data-edit-product={product.id} onClick={event => openProduct(product, event.currentTarget)}>{t('Edit')}</button>
                {mantoRefreshButton(product.id)}
                {variant.id && token && <VariantCostEditor productId={product.id} variantId={variant.id}
                  cost={variant.variant_costs} rates={rates} token={token} onSaved={reloadCatalogue} />}
                {variant.id && token && <StockAdjustment variantId={variant.id} token={token} reload={reloadCatalogue} />}
              </div>
            </li>
          })}
          {loading && !catalogue.data && <li className="catalog-admin__no-results" role="status">{t('Loading catalogue…')}</li>}
          {catalogue.data && matchCount === 0 && <li className="catalog-admin__no-results">{t('No products match these filters.')}</li>}
        </ul>
      {products.length > 0 && <CrmPagination page={currentPage} pages={pages} loading={loading} onChange={setPage} />}
      </section>)}
        {draft && <section className="product-editor catalog-product-workspace">
          <div className="product-editor__head product-workspace__header">
            <h2 ref={editorHeading} tabIndex={-1}>{draft.id ? t('Edit product') : t('New product')}</h2>
            <div className="actions">
              {!draft.id && <button type="button" className="btn btn--ghost" disabled={saving || categoryBusy || refreshingManto} onClick={() => {
                if (!dirty || window.confirm(t('Discard unsaved changes?'))) setMantoImportOpen(true)
              }}>{t('Import from Manto')}</button>}
              <button type="button" className="text-btn" disabled={saving || categoryBusy} onClick={closeEditor}>{t('Close')}</button>
            </div>
          </div>
          {editingProduct && <ProductTimestamps product={editingProduct} />}
          {mantoSource && mantoLink && <section className="product-workspace__section product-workspace__source" aria-label={t('Import source')} aria-busy={refreshingManto}>
            <div className="product-workspace__source-details">
              <h3>{t('Import source')}</h3>
              <a href={mantoLink.href} target="_blank" rel="noopener noreferrer">{mantoLink.hostname}{mantoLink.pathname}</a>
              <p className="muted">{t('Updated')} <time dateTime={mantoSource.snapshot.checkedAt}>
                {new Date(mantoSource.snapshot.checkedAt).toLocaleString(language, { dateStyle: 'short', timeStyle: 'short', timeZone: 'Europe/Kyiv' })}
              </time></p>
            </div>
            <button type="button" className="btn btn--ghost" disabled={refreshingManto || saving || !token}
              onClick={() => void refreshManto()}>{t(refreshingManto ? 'Updating…' : 'Refresh')}</button>
            {mantoRefreshError && <p className="error" role="alert">{t(mantoRefreshError)}</p>}
          </section>}
          <section className="product-workspace__section">
            <div className="product-workspace__section-heading"><span>01</span><h3>{t('Basic information')}</h3></div>
          <div className="product-editor__translations product-workspace__languages">
            {(['uk', 'en'] as const).map(locale => <div key={locale}>
              <strong className="product-workspace__language">{t(locale === 'uk' ? 'Ukrainian' : 'English')}</strong>
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
          <p className="muted product-workspace__translation-hint">{t('When a translation is blank, the store shows the text from the other language.')}</p>
          </section>
          <section className="product-workspace__section">
            <div className="product-workspace__section-heading"><span>02</span><h3>{t('Pricing and weight')}</h3></div>
          <div className="product-workspace__pricing">
          <label className="field">
            <span>{t('Price, UAH')}</span>
            <input type="number" min="0" step="0.01" value={draft.price} disabled={saving} onChange={event => setDraft({ ...draft, price: event.target.value })} />
            {hasDifferentPrices && <small>{t('Sizes currently have different prices. Saving applies this price to all sizes.')}</small>}
          </label>
          <CatalogCostInput label={t('Default unit cost')} amount={draft.defaultCost} currency={draft.defaultCostCurrency}
            rates={rates} disabled={saving} hint={t('Used for variants with an empty cost field.')}
            onChange={(amount, currency) => setDraft({ ...draft, defaultCost: amount, defaultCostCurrency: currency, defaultCostEdited: true })} />
          <label className="field">
            <span>{t('Item weight, g')}</span>
            <input type="number" min="1" max="2147483647" step="1" value={draft.weightGrams} disabled={saving}
              onChange={event => setDraft({ ...draft, weightGrams: event.target.value })} />
          </label>
          </div>
          <CatalogDiscountFields percent={draft.discountPercent} stacking={draft.stackCustomerDiscount} disabled={saving}
            onPercentChange={discountPercent => setDraft({ ...draft, discountPercent })}
            onStackingChange={stackCustomerDiscount => setDraft({ ...draft, stackCustomerDiscount })} />
          </section>
          <details className="customer-section product-workspace__section product-workspace__details"><summary>{t('Product information')}</summary>
            <div className="product-editor__translations">
              {(['uk', 'en'] as const).map(locale => <div key={locale}>
                <h3>{t(locale === 'uk' ? 'Ukrainian' : 'English')}</h3>
                <label className="field">{t('Size guide and measurements')}<textarea rows={5} maxLength={10000} value={draft.sizeGuide[locale]} onChange={event => setDraft({ ...draft, sizeGuide: { ...draft.sizeGuide, [locale]: event.target.value } })} /></label>
                <label className="field">{t('Composition')}<textarea rows={3} maxLength={10000} value={draft.composition[locale]} onChange={event => setDraft({ ...draft, composition: { ...draft.composition, [locale]: event.target.value } })} /></label>
                <label className="field">{t('Care instructions')}<textarea rows={3} maxLength={10000} value={draft.careInstructions[locale]} onChange={event => setDraft({ ...draft, careInstructions: { ...draft.careInstructions, [locale]: event.target.value } })} /></label>
              </div>)}
            </div>
            <label className="product-photo-upload size-guide-upload">
              <input className="sr-only" type="file" accept="image/jpeg,image/png,image/webp" multiple
                disabled={saving || draft.sizeGuideImages.length >= maxSizeGuideImages} onChange={event => {
                  const files = Array.from(event.target.files ?? [])
                  event.target.value = ''
                  const available = maxSizeGuideImages - draft.sizeGuideImages.length
                  if (files.length > available) addToast(t('You can add up to {{count}} size guide images.', { count: maxSizeGuideImages }))
                  const images = files.slice(0, available).map(file => ({ key: crypto.randomUUID(), file }))
                  if (images.length) setDraft(current => current?.key === draft.key ? {
                    ...current,
                    sizeGuideImages: [...current.sizeGuideImages, ...images].slice(0, maxSizeGuideImages),
                  } : current)
                }} />
              <span className="product-photo-upload__icon" aria-hidden="true">＋</span>
              <span className="product-photo-upload__copy">
                <strong>{t('Size guide images')}</strong>
                <small>{t('JPG, PNG or WebP · up to 5 MB per file')}</small>
              </span>
              <span className="size-guide-upload__count">{draft.sizeGuideImages.length} / {maxSizeGuideImages}</span>
              <span className="product-photo-upload__action" aria-hidden="true">{t('Choose files')}</span>
            </label>
            {draft.sizeGuideImages.length > 0 && <div className="image-manager product-photo-grid">
              {draft.sizeGuideImages.map((image, index) => <div key={image.key} className="size-guide-preview image-manager__item product-photo">
                <div className="product-photo__preview">
                  {'file' in image ? <LocalImagePreview file={image.file} /> : <img src={image.url} alt={`${t('Size guide image')} ${index + 1}`} />}
                  <button type="button" className="product-photo__delete" aria-label={`${t('Remove image')} ${index + 1}`} title={t('Remove image')} disabled={saving}
                    onClick={() => setDraft(current => current?.key === draft.key ? {
                      ...current, sizeGuideImages: current.sizeGuideImages.filter(item => item.key !== image.key),
                    } : current)}>×</button>
                </div>
              </div>)}
            </div>}
          </details>
          <section className="product-workspace__section">
          <div className="product-workspace__section-heading"><span>03</span><h3>{t('Categories')}</h3></div>
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
          </section>
          <section className="product-workspace__section">
          <div className="product-workspace__section-heading"><span>04</span><h3>{t('Product images')}</h3></div>
          <label className="product-photo-upload">
            <input className="sr-only" type="file" accept="image/jpeg,image/png,image/webp" multiple disabled={saving} onChange={event => {
              const files = Array.from(event.target.files ?? [])
              if (files.length) setDraft(current => current && { ...current, imageOrder: [...current.imageOrder, ...files.map((_, index) => `new:${current.newImageFiles.length + index}`)], newImageFiles: [...current.newImageFiles, ...files] })
              event.target.value = ''
            }} />
            <span className="product-photo-upload__icon" aria-hidden="true">＋</span>
            <span className="product-photo-upload__copy"><strong>{t('Add photos')}</strong><small>{t('JPG, PNG or WebP · up to 5 MB per file')}</small></span>
            <span className="product-photo-upload__action" aria-hidden="true">{t('Choose files')}</span>
          </label>
          {draft.imageOrder.length > 0 && <div className="image-manager product-photo-grid">
            {draft.imageOrder.map((photo, position) => {
              const isNew = photo.startsWith('new:')
              const fileIndex = isNew ? Number(photo.slice(4)) : -1
              const file = isNew ? draft.newImageFiles[fileIndex] : null
              const image = isNew ? null : draft.images.find(item => item.id === photo.slice(6))
              if (!file && !image) return null
              return <figure key={photo} className="image-manager__item product-photo" draggable onDragStart={() => { draggedPhoto.current = position }} onDragEnd={() => { draggedPhoto.current = null }} onDragOver={event => event.preventDefault()} onDrop={event => { event.preventDefault(); if (draggedPhoto.current !== null) movePhoto(draggedPhoto.current, position); draggedPhoto.current = null }}>
                <div className="product-photo__preview">{file ? <LocalImagePreview file={file} /> : <img src={image!.public_url} alt={t('Product')} draggable={false} />}
                  {position === 0 && <span className="product-photo__badge">{t('Main photo')}</span>}
                  <button type="button" className="product-photo__delete" aria-label={t('Remove')} title={t('Remove')} disabled={saving} onClick={() => setDraft(current => {
                    if (!current) return current
                    if (!isNew) return { ...current, imageOrder: current.imageOrder.filter(item => item !== photo), removedImageIds: [...current.removedImageIds, image!.id] }
                    return { ...current, newImageFiles: current.newImageFiles.filter((_, index) => index !== fileIndex), imageOrder: current.imageOrder.filter(item => item !== photo).map(item => {
                      if (!item.startsWith('new:')) return item
                      const index = Number(item.slice(4))
                      return `new:${index > fileIndex ? index - 1 : index}`
                    }) }
                  })}>×</button>
                </div>
                <figcaption className="product-photo__controls">
                  <span className="product-photo__reorder"><button type="button" aria-label={t('Move earlier')} title={t('Move earlier')} disabled={saving || position === 0} onClick={() => movePhoto(position, position - 1)}>←</button><button type="button" aria-label={t('Move later')} title={t('Move later')} disabled={saving || position === draft.imageOrder.length - 1} onClick={() => movePhoto(position, position + 1)}>→</button></span>
                </figcaption>
              </figure>
            })}
          </div>}

          </section>
          <section className="product-workspace__section product-workspace__visibility">
          <div className="product-workspace__section-heading"><span>05</span><h3>{t('Visibility')}</h3></div>
          <div className="product-workspace__visibility-options">
            <label className="check switch-field">
              <ToggleSwitch checked={draft.isActive} onChange={event => setDraft({ ...draft, isActive: event.target.checked })} />
              {t('Published in storefront')}
            </label>
            <label className="check switch-field">
              <ToggleSwitch checked={draft.isNew} onChange={event => setDraft({ ...draft, isNew: event.target.checked })} />
              {t('Mark as new')}
            </label>
          </div>
          </section>
          <div className="variant-editor product-workspace__section"><div className="product-editor__head"><div className="product-workspace__section-heading"><span>06</span><h3>{t('Sizes and stock')}</h3></div><button type="button" className="text-btn" onClick={() => setDraft({ ...draft, variants: [...draft.variants, blankVariant()] })}>{t('Add size')}</button></div>
            {draft.variants.map((variant, index) => <div className="variant-editor__row" key={variant.key}>
                <div className="variant-editor__fields">
                  <label className="variant-field"><span>{t('Size')}</span><input value={variant.name} onChange={event => updateVariant(index, 'name', event.target.value)} /></label>
                  <label className="variant-field"><span>{t('SKU')}</span><input value={variant.sku ?? ''} onChange={event => updateVariant(index, 'sku', event.target.value)} /></label>
                  <label className="variant-field"><span>{t('Stock, units')}</span><input type="number" min="0" disabled={saving} value={variant.stock_quantity} onChange={event => updateVariant(index, 'stock_quantity', event.target.value)} /></label>
                  <label className="variant-field"><span>{t('Low stock threshold')}</span><input type="number" min="0" value={variant.low_stock_threshold} onChange={event => updateVariant(index, 'low_stock_threshold', event.target.value)} /></label>
                </div>
                <div className="variant-editor__controls">
                  <CatalogCostInput label={t('Unit cost')} amount={variant.unitCost} currency={variant.currency}
                    rates={rates} disabled={saving} placeholder={variant.currency === draft.defaultCostCurrency ? draft.defaultCost : undefined}
                    onChange={(amount, currency) => setDraft(current => current && {
                      ...current,
                      variants: current.variants.map(item => item.key === variant.key
                        ? { ...item, unitCost: amount, currency, unitCostEdited: true }
                        : item),
                    })} />
                  <div className="variant-editor__availability">
                    <label className="check switch-field">
                      <ToggleSwitch checked={variant.is_preorder} onChange={event => updateVariant(index, 'is_preorder', event.target.checked)} />
                      <span>{t('Pre-order')}</span>
                    </label>
                    <label className="check switch-field">
                      <ToggleSwitch checked={variant.allow_out_of_stock} disabled={saving}
                        onChange={event => updateVariant(index, 'allow_out_of_stock', event.target.checked)} />
                      <span>{t('Allow purchase when out of stock')}</span>
                    </label>
                  </div>
                  <button type="button" className="variant-editor__remove" disabled={draft.variants.length === 1} onClick={() => removeVariant(index)}>{t('Remove')}</button>
                </div>
                <CatalogDiscountFields variant percent={variant.discountPercent} stacking={variant.stackCustomerDiscount} disabled={saving}
                  onPercentChange={value => updateVariant(index, 'discountPercent', value)}
                  onStackingChange={value => updateVariant(index, 'stackCustomerDiscount', value)} />
              </div>)}
          </div>
          <div className="actions product-workspace__footer">
            {draft.id && <button type="button" className="text-btn product-editor__delete product-workspace__footer-delete" disabled={saving || categoryBusy || refreshingManto} onClick={() => requestProductDeletion(draft.id!)}>
              {t(deleting ? 'Deleting…' : 'Delete product')}
            </button>}
            <button type="button" className="btn product-workspace__save" disabled={saving || categoryBusy || refreshingManto} onClick={() => void save()}>{t(saving && !deleting ? 'Saving…' : 'Save product')}</button>
            <button type="button" className="btn btn--ghost" disabled={saving || categoryBusy} onClick={closeEditor}>{t('Cancel')}</button>
          </div>
        </section>}
      {mantoImportOpen && draft && <ImportMantoDialog onClose={() => setMantoImportOpen(false)} onImport={importManto} />}
      {productToDelete && <ConfirmationDialog
        title={t('Delete product')}
        message={t('Permanently delete “{{name}}” from the catalogue?', { name: productName(productToDelete, language) })}
        details={[t('This action cannot be undone.')]}
        confirmLabel={t('Delete')}
        confirmDisabled={saving || categoryBusy}
        onClose={confirmed => {
          setProductToDelete(null)
          if (confirmed) void deleteProduct(productToDelete.id)
        }}
      />}
    </section>
  )
}
