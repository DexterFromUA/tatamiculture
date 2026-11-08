import { RestockSubscription } from '../components/RestockSubscription'
import { ProductCard } from '../components/ProductCard'
import { useMemo, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useCart } from '../context/CartContext'
import { useStore } from '../context/StoreContext'
import { useToast } from '../context/ToastContext'
import { formatPrice, optionPrice } from '../lib/format'
import { categoriesForProduct, categoryPaths, productCategoryLabel } from '../lib/categories'
import { useTranslation } from 'react-i18next'

export function ProductPage() {
  const { productId } = useParams()
  const { store, products } = useStore()
  const { addItem } = useCart()
  const { addToast } = useToast()
  const product = products.find((item) => item.id === productId)
  const [optionId, setOptionId] = useState(product?.productOptions[0]?.id ?? '')
  const [quantity, setQuantity] = useState(1)
  const [imageIndex, setImageIndex] = useState(0)
  const { t, i18n } = useTranslation()

  const option = useMemo(
    () => product?.productOptions.find((item) => item.id === optionId) ?? product?.productOptions[0],
    [optionId, product],
  )

  if (!store) return null

  if (!product || !option) {
    return (
      <div className="page-status">
        <h1>{t('Product not found')}</h1>
        <Link to="/">{t('Back to shop')}</Link>
      </div>
    )
  }

  const price = optionPrice(option)
  const categories = categoriesForProduct(product)
  const categoryIds = categories.map(category => category.id)
  const related = products.filter(item => item.id !== product.id
    && categoriesForProduct(item).some(category => categoryIds.includes(category.id))).slice(0, 4)
  const images = product.imgUrls
  const activeImage = images[imageIndex] ?? images[0]
  const changeImage = (direction: -1 | 1) => {
    setImageIndex((current) => (current + direction + images.length) % images.length)
  }

  const addToCart = () => {
    addItem(product.id, option.id, quantity)
    addToast(t('Added to cart'))
  }

  return (
    <>
    <article className="product-view shop-detail">
      {activeImage && <div className="product-gallery">
        <div className="product-view__image">
          <img src={activeImage} alt={product.name} />
          {images.length > 1 ? <div className="gallery-controls">
            <button type="button" onClick={() => changeImage(-1)} aria-label={t('Previous image')}>←</button>
            <span>{imageIndex + 1} / {images.length}</span>
            <button type="button" onClick={() => changeImage(1)} aria-label={t('Next image')}>→</button>
          </div> : null}
        </div>
        {images.length > 1 ? <div className="gallery-thumbnails">
          {images.map((image, index) => <button type="button" className={index === imageIndex ? 'active' : ''} key={image} onClick={() => setImageIndex(index)} aria-label={t('Show image {{number}}', { number: index + 1 })}><img src={image} alt="" /></button>)}
        </div> : null}
      </div>}
      <div className="product-view__body">
        <Link className="shop-back" to="/">← {t('Back to shop')}</Link>
        <p className="muted">{categoryPaths(categories, categoryIds, i18n.resolvedLanguage).join(' · ') || productCategoryLabel(product, i18n.resolvedLanguage) || t('Uncategorized')}</p>
        <h1>{product.name}</h1>
        <p className="lede">{product.description}</p>
        {[
          [t('Size guide and measurements'), product.sizeGuide],
          [t('Composition'), product.composition],
          [t('Care instructions'), product.careInstructions],
        ].filter(([, value]) => value).map(([label, value]) => <details key={label} className="customer-section">
          <summary>{label}</summary><p style={{ whiteSpace: 'pre-wrap' }}>{value}</p>
        </details>)}
        <p className="price">
          {option.isDiscount ? (
            <>
              <s>{formatPrice(option.price, store.currency)}</s> {formatPrice(price, store.currency)}
              <span className="badge">−{option.discountPercent}%</span>
            </>
          ) : (
            formatPrice(price, store.currency)
          )}
        </p>
        <label className="field">
          <span>{t('Size')}</span>
          <select value={option.id} onChange={(event) => {
            setOptionId(event.target.value)
            setQuantity(1)
          }}>
            {product.productOptions.map((item) => (
              <option key={item.id} value={item.id}>
                {item.name}
                {item.isPreOrder
                  ? ` · ${t('pre-order')}`
                  : item.isLimited ? ` · ${t('{{count}} available', { count: item.quantity })}` : ''}
              </option>
            ))}
          </select>
        </label>
        <label className="field">
          <span>{t('Quantity')}</span>
          <input
            type="number"
            min={1}
            max={option.isPreOrder ? undefined : option.isLimited ? option.quantity : 10}
            value={quantity}
            onChange={(event) => setQuantity(Math.max(1, Number(event.target.value) || 1))}
          />
        </label>
        {option.isPreOrder ? <p className="note">{t('This option is a pre-order. Production starts after checkout.')}</p> : null}
        {!option.isPreOrder && option.quantity === 0 && <RestockSubscription key={option.id} variantId={option.id} />}
        <div className="actions">
          <button type="button" className="btn" disabled={!option.isPreOrder && option.quantity < 1} onClick={addToCart}>
            {t('Add to cart')}
          </button>
          <Link to="/cart" className="btn btn--ghost">
            {t('View cart')}
          </Link>
        </div>
      </div>
    </article>
    {related.length > 0 && <section className="page-section">
      <h2>{t('Related products')}</h2>
      <div className="product-grid">{related.map(item => <ProductCard key={item.id} product={item} store={store} />)}</div>
    </section>}
    </>
  )
}
