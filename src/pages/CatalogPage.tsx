import { ProductCard } from '../components/ProductCard'
import { LoadingIndicator } from '../components/LoadingIndicator'
import { useStore } from '../context/StoreContext'
import { useEffect, useLayoutEffect, useRef, useState } from 'react'
import { useOutletContext } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import type { CatalogNavigation } from '../components/StoreLayout'
import { supabaseConfigured, supabaseRequest } from '../lib/supabase'
import { bannerImages, defaultBannerTitle, type Banner, type BannerImage } from '../lib/banner'
import { BannerCarousel } from '../components/BannerCarousel'
import { categoryGroups, categoryLabel } from '../lib/categories'
import { productName } from '../lib/productText'
import { discountedCategory, newArrivalsCategory } from '../lib/storefrontCatalog'

const bannerTimeout = 5000
const siteIcon = '/tatami-mark-transparent.png'

export function CatalogPage() {
  const { store } = useStore()
  const storeId = store?.id
  const { t, i18n } = useTranslation()
  const language = i18n.resolvedLanguage === 'en' ? 'en' : 'uk'
  const { filters, setFilters, rememberProduct, restoreScroll, catalog } = useOutletContext<CatalogNavigation>()
  const { category, subcategory, search, size, sort } = filters
  const [banner, setBanner] = useState<Banner | null | undefined>(undefined)
  const [imageResult, setImageResult] = useState<{ url: string; loaded: boolean }>()
  const heroImage = useRef<HTMLImageElement>(null)
  const productGrid = useRef<HTMLDivElement>(null)
  const nextPage = useRef<HTMLDivElement>(null)
  const hasMore = Boolean(catalog.page?.next_cursor)
  const catalogReady = Boolean(catalog.page)
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
  const configuredImages = bannerImages(banner)
  const images: BannerImage[] = configuredImages.length ? configuredImages : (catalog.metadata?.bannerProducts ?? [])
    .map(product => ({ url: product.url, path: '', productId: product.id, productName: productName(product, language) }))
  const waitingForFallback = showBanner && !configuredImages.length && catalog.loadingMetadata
  const firstImage = showBanner && !waitingForFallback && images[0]?.type !== 'video' ? (images[0]?.url ?? siteIcon) : undefined
  const waitingForImage = Boolean(firstImage && imageResult?.url !== firstImage)
  const imageUnavailable = imageResult?.url === firstImage && imageResult?.loaded === false
  const loading = loadingBanner || waitingForFallback || waitingForImage

  useLayoutEffect(() => {
    if (!loading && catalogReady && productGrid.current) restoreScroll(productGrid.current)
  }, [loading, catalogReady, restoreScroll])

  const { loadMore } = catalog
  useEffect(() => {
    const sentinel = nextPage.current
    if (loading || !hasMore || catalog.loadingMore || catalog.error === 'more' || !sentinel || typeof IntersectionObserver === 'undefined') return
    const observer = new IntersectionObserver(entries => {
      if (entries.some(entry => entry.isIntersecting)) loadMore()
    }, { rootMargin: '0px 0px 420px 0px' })
    observer.observe(sentinel)
    return () => observer.disconnect()
  }, [loading, hasMore, catalog.loadingMore, catalog.error, loadMore])

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
  const kicker = banner?.[`kicker_${language}`]?.trim()
  const customTitle = banner?.[`title_${language}`]?.trim()
  const description = banner?.[`description_${language}`]?.trim()
  const groups = categoryGroups(catalog.metadata?.categories ?? [], language)
  const hasNewArrivals = catalog.metadata?.hasNewArrivals ?? false
  const showingNewArrivals = category === newArrivalsCategory && hasNewArrivals
  const hasDiscountedProducts = catalog.metadata?.hasDiscountedProducts ?? false
  const showingDiscountedProducts = category === discountedCategory && hasDiscountedProducts
  const activeGroup = groups.find(({ parent }) => parent.id === category)
  const activeSubcategory = activeGroup?.children.find(child => child.id === subcategory)
  const sizes = [...(catalog.metadata?.sizes ?? [])].sort((a, b) => a.localeCompare(b, language, { numeric: true }))
  const visibleProducts = catalog.page?.rows ?? []
  const total = catalog.page?.total
  const activeCategory = activeSubcategory ?? activeGroup?.parent
  const showingAllProducts = !activeGroup && !showingNewArrivals && !showingDiscountedProducts
  const collectionName = activeCategory ? categoryLabel(activeCategory, language)
    : t(showingNewArrivals ? 'New arrivals' : showingDiscountedProducts ? 'On sale' : 'All products')
  const selectCategory = (id: string) => {
    setFilters(current => ({ ...current, category: id, subcategory: '' }))
  }

  return (
    <>
      {loading && <LoadingIndicator label={t('Opening store…')} />}
      <section className="storefront" hidden={loading}>
        {showBanner && <header className={`storefront-hero${banner?.show_text === false ? ' storefront-hero--media-only' : ''}`}>
          {banner?.show_text !== false && <div className="storefront-hero__copy">
            {kicker && <span className="storefront-kicker">{kicker}</span>}
            <h1><span className="storefront-hero__brand">{store.name}</span><span lang={customTitle ? undefined : 'en'}> / {customTitle || defaultBannerTitle}</span></h1>
            {description && <p>{description}</p>}
          </div>}
          {(images.length > 1 || (images.length === 1 && !imageUnavailable)) && (
            <BannerCarousel key={JSON.stringify(images.map(image => image.url))} images={images} imageRef={heroImage} ready={!loading} hideFirstImage={imageUnavailable} />
          )}
          {images.length === 0 && !imageUnavailable && (
            <div className="storefront-hero__image storefront-hero__image--site-icon">
              <img ref={heroImage} src={siteIcon} alt="" fetchPriority="high" />
            </div>
          )}
        </header>}
        {!loading && (
          <>
            <div id="collection" className="collection-head">
              <div>
                <span className="storefront-kicker">{t('The collection')}</span>
                {showBanner
                  ? <h2>{collectionName} {total !== undefined && <sup>{total}</sup>}</h2>
                  : <h1>{collectionName} {total !== undefined && <sup>{total}</sup>}</h1>}
              </div>
              <div className="collection-tools">
                <label><input type="search" aria-label={t('Search products')} placeholder={t('Search products')} value={search} onChange={event => setFilters({ ...filters, search: event.target.value })} /></label>
                <label><span className="sr-only">{t('Filter by size')}</span><select value={size} onChange={event => setFilters({ ...filters, size: event.target.value })}><option value="">{t('All sizes')}</option>{sizes.map(item => <option key={item} value={item}>{item}</option>)}</select></label>
                <label><span className="sr-only">{t('Sort products')}</span><select value={sort} onChange={event => setFilters({ ...filters, sort: event.target.value })}><option value="recently-updated">{t('Newest first')}</option><option value="price-low">{t('Price: low to high')}</option><option value="price-high">{t('Price: high to low')}</option></select></label>
              </div>
            </div>
            <div className="collection-filters" role="group" aria-label={t('Categories')}>
              <button type="button" className={showingAllProducts ? 'active' : ''} aria-pressed={showingAllProducts} onClick={() => selectCategory('')}>{t('All products')}</button>
              {hasNewArrivals && <button type="button" className={showingNewArrivals ? 'active' : ''} aria-pressed={showingNewArrivals} onClick={() => selectCategory(newArrivalsCategory)}>{t('New arrivals')}</button>}
              {hasDiscountedProducts && <button type="button" className={showingDiscountedProducts ? 'active' : ''} aria-pressed={showingDiscountedProducts} onClick={() => selectCategory(discountedCategory)}>{t('On sale')}</button>}
              {groups.map(({ parent }) => (
                <button type="button" key={parent.id} className={category === parent.id ? 'active' : ''} aria-pressed={category === parent.id} onClick={() => selectCategory(parent.id)}>{categoryLabel(parent, language)}</button>
              ))}
            </div>
            {!!activeGroup?.children.length && (
              <div className="collection-filters collection-filters--subcategories" role="group" aria-label={t('Subcategories')}>
                <button type="button" className={!activeSubcategory ? 'active' : ''} aria-pressed={!activeSubcategory} onClick={() => setFilters({ ...filters, subcategory: '' })}>{t('All in {{category}}', { category: categoryLabel(activeGroup.parent, language) })}</button>
                {activeGroup.children.map(child => (
                  <button type="button" key={child.id} className={subcategory === child.id ? 'active' : ''} aria-pressed={subcategory === child.id} onClick={() => setFilters({ ...filters, subcategory: child.id })}>{categoryLabel(child, language)}</button>
                ))}
              </div>
            )}
            {catalog.error && catalog.error !== 'more' && <p className="error" role="alert">
              {t('Could not load the catalogue.')} <button type="button" className="text-btn" onClick={catalog.retry}>{t('Try again')}</button>
            </p>}
            <div ref={productGrid} className="grid storefront-grid" aria-busy={catalog.loading} onClickCapture={event => {
              if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return
              const card = event.target instanceof Element ? event.target.closest('a.product-card') : null
              if (card instanceof HTMLAnchorElement) rememberProduct(card)
            }}>
              {catalog.loading && Array.from({ length: catalog.placeholderCount }, (_, index) => <div className="product-card product-card--skeleton" aria-hidden="true" key={index}>
                <div className="product-card__image skeleton-block" />
                <div className="skeleton-meta"><span className="skeleton-block" /><span className="skeleton-block" /><span className="skeleton-block" /></div>
              </div>)}
              {visibleProducts.map(product => <ProductCard key={product.id} product={product} store={store} />)}
            </div>
            {catalog.loading && <p className="sr-only" role="status">{t('Loading…')}</p>}
            {catalogReady && visibleProducts.length === 0 && <p className="muted">{t('No products match these filters.')}</p>}
            {hasMore && <div ref={nextPage} className="catalog-load-more">
              {catalog.error === 'more' && <p className="error" role="alert">{t('Could not load more products.')}</p>}
              <button type="button" className="btn btn--ghost" disabled={catalog.loadingMore} onClick={loadMore}>
                {t(catalog.loadingMore ? 'Loading…' : catalog.error === 'more' ? 'Try again' : 'Load more products')}
              </button>
            </div>}
          </>
        )}
      </section>
    </>
  )
}
