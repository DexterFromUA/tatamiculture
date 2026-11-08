import { Link } from 'react-router-dom'
import { useCart } from '../context/CartContext'
import { useStore } from '../context/StoreContext'
import { formatPrice, optionPrice } from '../lib/format'
import { productCategoryLabel } from '../lib/categories'
import { productName } from '../lib/productText'
import { useTranslation } from 'react-i18next'

export function CartPage() {
  const { store, products } = useStore()
  const { items, setQuantity, removeItem } = useCart()
  const { t, i18n } = useTranslation()

  if (!store) return null

  const rows = items
    .map((item) => {
      const product = products.find((entry) => entry.id === item.productId)
      const option = product?.productOptions.find((entry) => entry.id === item.optionId)
      if (!product || !option) return null
      const unit = optionPrice(option)
      return { item, product, option, unit, line: unit * item.quantity }
    })
    .filter((row) => row !== null)

  const total = rows.reduce((sum, row) => sum + row.line, 0)

  if (rows.length === 0) {
    return (
      <section className="cart-empty">
        <p className="eyebrow">{t('Your order')}</p>
        <h1>{t('Cart is empty')}</h1>
        <p>{t('Your selected items will appear here.')}</p>
        <Link className="cart-empty__link" to="/">{t('Continue shopping')} ↗</Link>
      </section>
    )
  }

  return (
    <section className="cart-page">
      <header className="cart-hero">
        <p className="eyebrow">{t('Your order')}</p>
        <h1>{t('Cart')}</h1>
        <div className="cart-hero__footer"><Link to="/">← {t('Continue shopping')}</Link><span>{t('Items in order: {{quantity}}', { quantity: rows.reduce((sum, row) => sum + row.item.quantity, 0) })}</span></div>
      </header>
      <div className="cart-page__layout"><div>
      <div className="cart-list-heading"><div><p className="eyebrow">01 / {t('Your order')}</p><h2>{t('Your selection')}</h2></div><span>{rows.length}</span></div>
      <ul className="line-list">
        {rows.map(({ item, product, option, unit, line }) => (
          <li key={`${item.productId}-${item.optionId}`} className="line cart-line">
            {product.imgUrls[0] && <img src={product.imgUrls[0]} alt="" />}
            <div className="cart-line__product">
              <p className="cart-line__category">{productCategoryLabel(product, i18n.resolvedLanguage) ?? t('Uncategorized')}</p>
              <Link to={`/product/${product.id}`}>{productName(product, i18n.resolvedLanguage)}</Link>
              <p className="muted">{t('Option')}: {option.name}{option.isPreOrder ? ` · ${t('pre-order')}` : ''}</p>
              <p>{formatPrice(unit, store.currency)}</p>
            </div>
            <label className="qty cart-line__quantity">
              <span>{t('Quantity')}</span>
              <input
                type="number"
                min={1}
                value={item.quantity}
                onChange={(event) =>
                  setQuantity(item.productId, item.optionId, Math.max(1, Number(event.target.value) || 1))
                }
              />
            </label>
            <strong className="cart-line__total">{formatPrice(line, store.currency)}</strong>
            <button type="button" className="text-btn cart-line__remove" onClick={() => removeItem(item.productId, item.optionId)}>
              {t('Remove')}
            </button>
          </li>
        ))}
      </ul>
      </div><aside className="cart-summary">
        <p className="eyebrow">02 / {t('Your order')}</p><h2>{t('Order summary')}</h2>
        <div className="cart-summary__detail"><span>{t('Items in order: {{quantity}}', { quantity: rows.reduce((sum, row) => sum + row.item.quantity, 0) })}</span><strong>{formatPrice(total, store.currency)}</strong></div>
        <div className="cart-summary__detail"><span>{t('Delivery')}</span><span>{t('Shipping cost is confirmed after dispatch.')}</span></div>
        <div className="summary"><span>{t('Total')}</span><strong>{formatPrice(total, store.currency)}</strong></div>
        <Link to="/checkout" className="btn">
          {t('Checkout')} <span aria-hidden="true">↗</span>
        </Link>
      </aside></div>
    </section>
  )
}
