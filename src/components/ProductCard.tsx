import { Link } from 'react-router-dom'
import { optionPrice, formatPrice } from '../lib/format'
import type { Product, Store } from '../types'

export function ProductCard({ product, store }: { product: Product; store: Store }) {
  const prices = product.productOptions.map(optionPrice)
  const min = Math.min(...prices)
  const max = Math.max(...prices)
  const priceLabel = min === max ? formatPrice(min, store.currency) : `From ${formatPrice(min, store.currency)}`
  const onSale = product.productOptions.some((option) => option.isDiscount)

  return (
    <Link to={`/product/${product.id}`} className="product-card">
      <div className="product-card__image">
        <img src={product.imgUrls[0]} alt="" />
        {onSale ? <span className="badge">Sale</span> : null}
      </div>
      <div className="product-card__meta">
        <p className="muted">{product.category}</p>
        <h3>{product.name}</h3>
        <p>{priceLabel}</p>
      </div>
    </Link>
  )
}
