import { ProductCard } from '../components/ProductCard'
import { useStore } from '../context/StoreContext'
import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { supabaseConfigured, supabaseRequest } from '../lib/supabase'
import { bannerImages, type Banner } from '../lib/banner'
import { BannerCarousel } from '../components/BannerCarousel'

const bannerTimeout = 5000

export function CatalogPage() {
  const { store, products } = useStore()
  const storeId = store?.id
  const { t, i18n } = useTranslation()
  const [category, setCategory] = useState('')
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
  const categories = [...new Set(products.map(product => product.category).filter(Boolean))]
  const visibleProducts = category ? products.filter(product => product.category === category) : products

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
                  ? <h2>{t('All products')} <sup>{visibleProducts.length}</sup></h2>
                  : <h1>{t('All products')} <sup>{visibleProducts.length}</sup></h1>}
              </div>
              <p>{t('Find your essentials')}</p>
            </div>
            <div className="collection-filters" aria-label={t('Category')}>
              <button type="button" className={!category ? 'active' : ''} aria-pressed={!category} onClick={() => setCategory('')}>{t('All products')}</button>
              {categories.map(item => (
                <button type="button" key={item} className={category === item ? 'active' : ''} aria-pressed={category === item} onClick={() => setCategory(item)}>{item}</button>
              ))}
            </div>
            <div className="grid storefront-grid">
              {visibleProducts.map(product => <ProductCard key={product.id} product={product} store={store} />)}
            </div>
          </>
        )}
      </section>
    </>
  )
}
