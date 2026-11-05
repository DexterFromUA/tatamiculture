import { ProductCard } from '../components/ProductCard'
import { useStore } from '../context/StoreContext'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { supabaseConfigured, supabaseRequest } from '../lib/supabase'
import type { Banner } from '../components/BannerSettings'

export function CatalogPage() {
  const { store, products } = useStore()
  const { t, i18n } = useTranslation()
  const [category, setCategory] = useState('')
  const [banner, setBanner] = useState<Banner | null | undefined>(undefined)
  useEffect(() => {
    if (!store || !supabaseConfigured) return
    let cancelled = false
    void supabaseRequest<Banner[]>(`/rest/v1/storefront_banners?store_id=eq.${encodeURIComponent(store.id)}&select=*`).then(rows => { if (!cancelled) setBanner(rows[0] ?? null) }).catch(() => { if (!cancelled) setBanner(null) })
    return () => { cancelled = true }
  }, [store])
  if (!store) return null
  const language = i18n.resolvedLanguage === 'en' ? 'en' : 'uk'
  const showBanner = !supabaseConfigured || (banner !== undefined && banner?.enabled !== false)
  const kicker = banner?.[`kicker_${language}`]?.trim()
  const title = banner?.[`title_${language}`]?.trim() || t('Everyday movement')
  const description = banner?.[`description_${language}`]?.trim()
  const bannerImage = banner?.image_url || products[0]?.imgUrls[0]
  const categories = [...new Set(products.map(product => product.category).filter(Boolean))]
  const visibleProducts = category ? products.filter(product => product.category === category) : products

  return (
    <section className="storefront">
      {showBanner && <header className="storefront-hero">
        <div className="storefront-hero__copy">
          {kicker && <span className="storefront-kicker">{kicker}</span>}
          <h1><span className="storefront-hero__brand">{store.name}</span><span> / {title}</span></h1>
          {description && <p>{description}</p>}
          <a href="#collection" className="storefront-hero__link">{t('Explore collection')} <span aria-hidden="true">↗</span></a>
        </div>
        {bannerImage ? <div className="storefront-hero__image"><img src={bannerImage} alt="" />{!banner?.image_url && products[0] ? <span>{products[0].name}</span> : null}</div> : null}
      </header>}
      <div id="collection" className="collection-head"><div><span className="storefront-kicker">{t('The collection')}</span>{showBanner
        ? <h2>{t('All products')} <sup>{visibleProducts.length}</sup></h2>
        : <h1>{t('All products')} <sup>{visibleProducts.length}</sup></h1>}</div><p>{t('Find your essentials')}</p></div>
      <div className="collection-filters" aria-label={t('Category')}><button type="button" className={!category ? 'active' : ''} aria-pressed={!category} onClick={() => setCategory('')}>{t('All products')}</button>{categories.map(item => <button type="button" key={item} className={category === item ? 'active' : ''} aria-pressed={category === item} onClick={() => setCategory(item)}>{item}</button>)}</div>
      <div className="grid storefront-grid">
        {visibleProducts.map((product) => (
          <ProductCard key={product.id} product={product} store={store} />
        ))}
      </div>
    </section>
  )
}
