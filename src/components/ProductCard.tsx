import { Link } from 'react-router-dom'
import { optionPrice, formatPrice } from '../lib/format'
import { productCategoryLabel } from '../lib/categories'
import type { Product, Store } from '../types'
import { useTranslation } from 'react-i18next'

export function ProductCard({ product, store, scrollToTop = false }: { product: Product; store: Store; scrollToTop?: boolean }) {
  const { t, i18n } = useTranslation()
  const prices = product.productOptions.map(optionPrice)
  const min = Math.min(...prices)
  const max = Math.max(...prices)
  const priceLabel = min === max ? formatPrice(min, store.currency) : t('From {{price}}', { price: formatPrice(min, store.currency) })
  const onSale = product.productOptions.some((option) => option.isDiscount)
  const image = product.imgUrls[0]
  const badges = (product.isNew || onSale) && (
    <div className="product-card__badges">
      {product.isNew && <span className="badge badge--new">{t('New arrival')}</span>}
      {onSale && <span className="badge">{t('Sale')}</span>}
    </div>
  )

  return (
    <Link to={`/product/${product.id}`} className="product-card" onClick={event => {
      if (scrollToTop && event.button === 0 && !event.metaKey && !event.ctrlKey && !event.shiftKey && !event.altKey) window.scrollTo(0, 0)
    }}>
      {image && <div className="product-card__image">
        <img src={image} alt="" />
        {badges}
      </div>}
      {!image && badges}
      <div className="product-card__meta">
        <p className="muted">{productCategoryLabel(product, i18n.resolvedLanguage) ?? t('Uncategorized')}</p>
        <h3>{product.name}</h3>
        <p>{priceLabel}</p>
      </div>
    </Link>
  )
}
