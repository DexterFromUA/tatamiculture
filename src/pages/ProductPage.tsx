import { RestockSubscription } from '../components/RestockSubscription'
import { ProductCard } from '../components/ProductCard'
import { useEffect, useId, useMemo, useRef, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useCart } from '../context/CartContext'
import { useStore } from '../context/StoreContext'
import { useToast } from '../context/ToastContext'
import { formatPrice, optionPrice } from '../lib/format'
import { isSoldOut, purchaseQuantityLimit, stockLabel } from '../lib/catalogAvailability'
import { categoriesForProduct, categoryPaths, productCategoryLabel } from '../lib/categories'
import { productDescription, productInformation, productName } from '../lib/productText'
import { api } from '../lib/api'
import { LoadingIndicator } from '../components/LoadingIndicator'
import type { Product } from '../types'
import { useTranslation } from 'react-i18next'
import Markdown from 'react-markdown'
import remarkBreaks from 'remark-breaks'

export function ProductPage() {
  const { productId } = useParams()
  return <ProductDetails key={productId} />
}

function ProductDetails() {
  const { productId } = useParams()
  const { store, catalogRevision, refreshProducts } = useStore()
  const storeId = store?.id
  const { addItem, quantityFor } = useCart()
  const { addToast } = useToast()
  const [result, setResult] = useState<{ product: Product | null; error?: boolean }>()
  const [related, setRelated] = useState<Product[]>([])
  const product = result?.product
  const [optionId, setOptionId] = useState('')
  const [imageIndex, setImageIndex] = useState(0)
  const sizeGuideDialog = useRef<HTMLDialogElement>(null)
  const sizeGuideTitleId = useId()
  const { t, i18n } = useTranslation()

  useEffect(() => {
    if (!storeId || !productId) return
    const abort = new AbortController()
    void api.getProduct(storeId, productId, abort.signal).then(loadedProduct => {
      if (abort.signal.aborted) return
      setResult({ product: loadedProduct })
      if (loadedProduct) return api.getRelatedProducts(storeId, productId, abort.signal).then(products => {
        if (!abort.signal.aborted) setRelated(products)
      }).catch(() => {})
    }).catch(() => {
      if (!abort.signal.aborted) setResult({ product: null, error: true })
    })
    return () => abort.abort()
  }, [storeId, productId, catalogRevision])

  const option = useMemo(
    () => product?.productOptions.find((item) => item.id === optionId) ?? product?.productOptions[0],
    [optionId, product],
  )

  if (!store) return null
  if (productId && !result) return <LoadingIndicator label={t('Loading…')} />
  if (result?.error) return <section className="page-status">
    <p role="alert">{t('Could not load this product.')}</p>
    <button type="button" className="btn" onClick={refreshProducts}>{t('Try again')}</button>
  </section>

  if (!product || !option) {
    return (
      <div className="page-status">
        <h1>{t('Product not found')}</h1>
        <Link to="/">{t('Back to shop')}</Link>
      </div>
    )
  }

  const price = optionPrice(option)
  const inCart = quantityFor(product.id, option.id)
  const purchaseLimit = purchaseQuantityLimit(option)
  const soldOut = isSoldOut(product.productOptions)
  const canAdd = inCart < purchaseLimit
  const name = productName(product, i18n.resolvedLanguage)
  const description = productDescription(product, i18n.resolvedLanguage)
  const information = productInformation(product, i18n.resolvedLanguage)
  const categories = categoriesForProduct(product)
  const categoryIds = categories.map(category => category.id)
  const images = product.imgUrls
  const activeImage = images[imageIndex] ?? images[0]
  const changeImage = (direction: -1 | 1) => {
    setImageIndex((current) => (current + direction + images.length) % images.length)
  }

  const addToCart = () => {
    if (!canAdd) return
    addItem(product, option.id, 1)
    addToast(t('Added to cart'))
  }

  const copyProductLink = async () => {
    try {
      await navigator.clipboard.writeText(new URL(`/product/${product.id}`, window.location.origin).href)
      addToast(t('Product link copied'))
    } catch {
      addToast(t('Could not copy the product link'))
    }
  }

  return (
    <>
    <div className="product-page__navigation">
      <Link className="shop-back" to="/">← {t('Back to shop')}</Link>
      <button type="button" className="product-page__copy" onClick={() => void copyProductLink()}>{t('Copy product link')}</button>
    </div>
    <article className="product-view shop-detail">
      {activeImage && <div className="product-gallery">
        <div className="product-view__image">
          <img key={imageIndex} className="product-gallery__image" src={activeImage} alt={name} />
          {images.length > 1 ? <div className="gallery-controls">
            <button type="button" onClick={() => changeImage(-1)} aria-label={t('Previous image')}><span aria-hidden="true">←</span></button>
            <button type="button" onClick={() => changeImage(1)} aria-label={t('Next image')}><span aria-hidden="true">→</span></button>
          </div> : null}
        </div>
        {images.length > 1 ? <div className="gallery-thumbnails">
          {images.map((image, index) => <button type="button" className={index === imageIndex ? 'active' : ''} key={image} onClick={() => setImageIndex(index)} aria-label={t('Show image {{number}}', { number: index + 1 })}><img src={image} alt="" /></button>)}
        </div> : null}
      </div>}
      <div className="product-view__body">
        <p className="muted">{categoryPaths(categories, categoryIds, i18n.resolvedLanguage).join(' · ') || productCategoryLabel(product, i18n.resolvedLanguage) || t('Uncategorized')}</p>
        {(soldOut || product.isNew) && <div className="product-view__badges">
          {soldOut && <span className="badge badge--sold-out">{t('Sold out')}</span>}
          {product.isNew && <span className="badge badge--new">{t('New arrival')}</span>}
        </div>}
        <h1>{name}</h1>
        {description.trim() && (
          <div className="lede product-description">
            <Markdown skipHtml remarkPlugins={[remarkBreaks]}>{description}</Markdown>
          </div>
        )}
        {(information.sizeGuide || Boolean(product.sizeGuideImageUrls?.length)) && <>
          <button type="button" className="size-guide-trigger" aria-haspopup="dialog" onClick={() => sizeGuideDialog.current?.showModal()}>
            {t('Size guide and measurements')} <span aria-hidden="true">↗</span>
          </button>
          <dialog ref={sizeGuideDialog} className="size-guide-dialog" aria-labelledby={sizeGuideTitleId}
            onClick={event => {
              if (event.target !== event.currentTarget) return
              const bounds = event.currentTarget.getBoundingClientRect()
              if (event.clientX < bounds.left || event.clientX >= bounds.right || event.clientY < bounds.top || event.clientY >= bounds.bottom) event.currentTarget.close()
            }}>
            <header className="size-guide-dialog__header">
              <h2 id={sizeGuideTitleId}>{t('Size guide and measurements')}</h2>
              <button type="button" className="text-btn" autoFocus onClick={() => sizeGuideDialog.current?.close()}>{t('Close')}</button>
            </header>
            <div className="size-guide-dialog__body">
              {information.sizeGuide && <p style={{ whiteSpace: 'pre-wrap' }}>{information.sizeGuide}</p>}
              {product.sizeGuideImageUrls?.map((url, index) => <a key={`${url}-${index}`} href={url} target="_blank" rel="noopener noreferrer">
                <img src={url} alt={`${t('Size guide image')} ${index + 1}`} loading="lazy" />
              </a>)}
            </div>
          </dialog>
        </>}
        {[
          [t('Composition'), information.composition],
          [t('Care instructions'), information.careInstructions],
        ].filter(([, value]) => value).map(([label, value]) => <details key={label} className="customer-section">
          <summary>{label}</summary><p style={{ whiteSpace: 'pre-wrap' }}>{value}</p>
        </details>)}
        <p className="price">
          {option.isDiscount ? (
            <>
              <s>{formatPrice(option.price, store.currency)}</s> {formatPrice(price, store.currency)}
              <span className="badge badge--sale">−{option.discountPercent.toLocaleString(i18n.resolvedLanguage)}%</span>
            </>
          ) : (
            formatPrice(price, store.currency)
          )}
        </p>
        <label className="field">
          <span>{t('Size')}</span>
          <select value={option.id} onChange={(event) => {
            setOptionId(event.target.value)
          }}>
            {product.productOptions.map((item) => {
              const availability = stockLabel(item)
              return <option key={item.id} value={item.id}>
                {item.name}
                {item.isPreOrder && ` · ${t('pre-order')}`}
                {availability && ` · ${t(availability)}`}
              </option>
            })}
          </select>
        </label>
        {purchaseLimit > 0 && (option.isPreOrder ? (
          <p className="note product-delivery-note">
            <strong>{t('Average delivery time: 5–15 business days')}</strong>
            <small>{t('This is an estimate. Your parcel may arrive earlier or take longer.')}</small>
          </p>
        ) : (
          <p className="note product-delivery-note">{t((option.warehouseQuantity ?? option.quantity) > inCart
            ? 'Ships in 1–5 business days' : 'Available to order. Dispatch time will be confirmed.')}</p>
        ))}
        {(store.notifications.restockPush || store.notifications.restockSms) && purchaseLimit === 0 && <RestockSubscription key={option.id}
          variantId={option.id} pushEnabled={store.notifications.restockPush} smsEnabled={store.notifications.restockSms} />}
        <div className="actions">
          <button type="button" className="btn" disabled={!canAdd} onClick={addToCart}>
            {t('Add to cart')}
          </button>
          <Link to="/cart" className="btn btn--ghost">
            {t('View cart')}
          </Link>
        </div>
      </div>
    </article>
    {related.length > 0 && <section className="related-products">
      <h2>{t('Related products')}</h2>
      <div className="related-products__grid">{related.map(item => <ProductCard key={item.id} product={item} store={store} scrollToTop />)}</div>
    </section>}
    </>
  )
}
