import { Link } from 'react-router-dom'
import { optionPrice, formatPrice } from '../lib/format'
import { productCategoryLabel } from '../lib/categories'
import type { Product, Store } from '../types'
import { useTranslation } from 'react-i18next'

export function ProductCard({ product, store }: { product: Product; store: Store }) {
  const { t, i18n } = useTranslation()
  const prices = product.productOptions.map(optionPrice)
  const min = Math.min(...prices)
  const max = Math.max(...prices)
  const priceLabel = min === max ? formatPrice(min, store.currency) : t('From {{price}}', { price: formatPrice(min, store.currency) })
  const onSale = product.productOptions.some((option) => option.isDiscount)

  return (
    <Link to={`/product/${product.id}`} className="product-card">
      <div className="product-card__image">
        <img src={product.imgUrls[0]} alt="" />
        {onSale ? <span className="badge">{t('Sale')}</span> : null}
      </div>
      <div className="product-card__meta">
        <p className="muted">{productCategoryLabel(product, i18n.resolvedLanguage) ?? t('Uncategorized')}</p>
        <h3>{product.name}</h3>
        <p>{priceLabel}</p>
      </div>
    </Link>
  )
}
