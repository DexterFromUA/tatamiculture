import { ProductCard } from '../components/ProductCard'
import { useStore } from '../context/StoreContext'
import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { supabaseConfigured, supabaseRequest } from '../lib/supabase'
import { bannerImages, type Banner } from '../lib/banner'
import { BannerCarousel } from '../components/BannerCarousel'
import { categoriesForProduct, categoryGroups, categoryLabel } from '../lib/categories'
import { optionPrice } from '../lib/format'

const bannerTimeout = 5000

export function CatalogPage() {
  const { store, products } = useStore()
  const storeId = store?.id
  const { t, i18n } = useTranslation()
  const [category, setCategory] = useState('')
  const [subcategory, setSubcategory] = useState('')
  const [search, setSearch] = useState('')
  const [size, setSize] = useState('')
  const [sort, setSort] = useState('newest')
  const [banner, setBanner] = useState<Banner | null | undefined>(undefined)
  const [imageResult, setImageResult] = useState<{ url: string; loaded: boolean }>()
  const heroImage = useRef<HTMLImageElement>(null)
  useEffect(() => {
    if (!storeId || !supabaseConfigured) return
    const abort = new AbortController()
    let cancelled = false
    const timeout = window.setTimeout(() => abort.abort(), bannerTimeout)
    void supabaseRequest<Banner[]>(`/rest/v1/storefront_banners?store_id=eq.${encodeURIComponent(storeId)}&select=*`, { signal: abort.signal })
      .then(rows => { if (!cancelled) setBanner(rows[0] ?? null) })
      .catch(() => { if (!cancelled) setBanner(null) })
      .finally(() => window.clearTimeout(timeout))
    return () => {
      cancelled = true
      abort.abort()
      window.clearTimeout(timeout)
    }
  }, [storeId])

  const loadingBanner = supabaseConfigured && banner === undefined
  const showBanner = !loadingBanner && banner?.enabled !== false
  const images = bannerImages(banner)
  const fallbackImage = products[0]?.imgUrls[0]
  const firstImage = showBanner ? images[0]?.url || fallbackImage : undefined
  const waitingForImage = Boolean(firstImage && imageResult?.url !== firstImage)
  const imageUnavailable = imageResult?.url === firstImage && imageResult?.loaded === false
  const loading = loadingBanner || waitingForImage

  useEffect(() => {
    // Decode the image already mounted in the hidden hero so reveal reuses it.
    const image = heroImage.current
    if (!firstImage || !image) return
    let active = true
    const finish = (loaded: boolean) => {
      if (!active) return
      active = false
      window.clearTimeout(timeout)
      setImageResult({ url: firstImage, loaded })
    }
    const timeout = window.setTimeout(() => finish(false), bannerTimeout)
    void image.decode().then(() => finish(true), () => finish(false))
    return () => {
      active = false
      window.clearTimeout(timeout)
    }
  }, [firstImage])

  if (!store) return null
  const language = i18n.resolvedLanguage === 'en' ? 'en' : 'uk'
  const kicker = banner?.[`kicker_${language}`]?.trim()
  const title = banner?.[`title_${language}`]?.trim() || t('Everyday movement')
  const description = banner?.[`description_${language}`]?.trim()
  const categories = [...new Map(products.flatMap(product =>
    categoriesForProduct(product).map(item => [item.id, item] as const))).values()]
  const groups = categoryGroups(categories, language)
  const activeGroup = groups.find(({ parent }) => parent.id === category)
  const activeSubcategory = activeGroup?.children.find(child => child.id === subcategory)
  const filterId = activeSubcategory?.id ?? activeGroup?.parent.id
  const sizes = [...new Set(products.flatMap(product => product.productOptions.map(option => option.name.trim()).filter(Boolean)))]
    .sort((a, b) => a.localeCompare(b, language, { numeric: true }))
  const query = search.trim().toLocaleLowerCase(language)
  const visibleProducts = products.filter(product =>
    (!filterId || categoriesForProduct(product).some(item => item.id === filterId))
    && (!query || product.name.toLocaleLowerCase(language).includes(query))
    && (!size || product.productOptions.some(option => option.name.trim() === size)),
  ).sort((a, b) => {
    if (sort !== 'newest') {
      const price = (options: typeof a.productOptions) => options.length ? Math.min(...options.map(optionPrice)) : Infinity
      const difference = price(a.productOptions) - price(b.productOptions)
      if (Number.isFinite(difference) && difference !== 0) return sort === 'price-low' ? difference : -difference
      if (price(a.productOptions) !== price(b.productOptions)) return price(a.productOptions) === Infinity ? 1 : -1
    }
    return (Date.parse(b.createdAt || '') || 0) - (Date.parse(a.createdAt || '') || 0)
  })
  const activeCategory = activeSubcategory ?? activeGroup?.parent
  const collectionName = activeCategory ? categoryLabel(activeCategory, language) : t('All products')
  const selectCategory = (id: string) => {
    setCategory(id)
    setSubcategory('')
  }

  return (
    <>
      {loading && <div className="page-status" role="status">{t('Opening store…')}</div>}
      <section className="storefront" hidden={loading}>
        {showBanner && <header className="storefront-hero">
          <div className="storefront-hero__copy">
            {kicker && <span className="storefront-kicker">{kicker}</span>}
            <h1><span className="storefront-hero__brand">{store.name}</span><span> / {title}</span></h1>
            {description && <p>{description}</p>}
            <a href="#collection" className="storefront-hero__link">{t('Explore collection')} <span aria-hidden="true">↗</span></a>
          </div>
          {images.length > 0
            ? (images.length > 1 || !imageUnavailable) && (
              <BannerCarousel images={images} imageRef={heroImage} ready={!loading} hideFirstImage={imageUnavailable} />
            )
            : fallbackImage && !imageUnavailable && <div className="storefront-hero__image"><img ref={heroImage} src={fallbackImage} alt="" fetchPriority="high" /><span>{products[0].name}</span></div>}
        </header>}
        {!loading && (
          <>
            <div id="collection" className="collection-head">
              <div>
                <span className="storefront-kicker">{t('The collection')}</span>
                {showBanner
                  ? <h2>{collectionName} <sup>{visibleProducts.length}</sup></h2>
                  : <h1>{collectionName} <sup>{visibleProducts.length}</sup></h1>}
              </div>
              <div className="collection-tools">
                <label><span className="sr-only">{t('Search products')}</span><input type="search" value={search} onChange={event => setSearch(event.target.value)} placeholder={t('Search products')} /></label>
                <label><span className="sr-only">{t('Filter by size')}</span><select value={size} onChange={event => setSize(event.target.value)}><option value="">{t('All sizes')}</option>{sizes.map(item => <option key={item} value={item}>{item}</option>)}</select></label>
                <label><span className="sr-only">{t('Sort products')}</span><select value={sort} onChange={event => setSort(event.target.value)}><option value="newest">{t('Newest first')}</option><option value="price-low">{t('Price: low to high')}</option><option value="price-high">{t('Price: high to low')}</option></select></label>
              </div>
            </div>
            <div className="collection-filters" role="group" aria-label={t('Categories')}>
              <button type="button" className={!activeGroup ? 'active' : ''} aria-pressed={!activeGroup} onClick={() => selectCategory('')}>{t('All products')}</button>
              {groups.map(({ parent }) => (
                <button type="button" key={parent.id} className={category === parent.id ? 'active' : ''} aria-pressed={category === parent.id} onClick={() => selectCategory(parent.id)}>{categoryLabel(parent, language)}</button>
              ))}
            </div>
            {!!activeGroup?.children.length && (
              <div className="collection-filters collection-filters--subcategories" role="group" aria-label={t('Subcategories')}>
                <button type="button" className={!activeSubcategory ? 'active' : ''} aria-pressed={!activeSubcategory} onClick={() => setSubcategory('')}>{t('All in {{category}}', { category: categoryLabel(activeGroup.parent, language) })}</button>
                {activeGroup.children.map(child => (
                  <button type="button" key={child.id} className={subcategory === child.id ? 'active' : ''} aria-pressed={subcategory === child.id} onClick={() => setSubcategory(child.id)}>{categoryLabel(child, language)}</button>
                ))}
              </div>
            )}
            <div className="grid storefront-grid">
              {visibleProducts.map(product => <ProductCard key={product.id} product={product} store={store} />)}
            </div>
            {visibleProducts.length === 0 && <p className="muted">{t('No products match these filters.')}</p>}
          </>
        )}
      </section>
    </>
  )
}
