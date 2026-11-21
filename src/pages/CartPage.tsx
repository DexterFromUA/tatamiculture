import { useCodReceiptRecovery } from '../lib/useCodReceiptRecovery'
import { customerUnitPrice } from '../lib/catalogPricing'
import { purchaseQuantityLimit, unavailableQuantity } from '../lib/catalogAvailability'
import { useEffect } from 'react'
import { Link, useNavigate, useSearchParams } from 'react-router-dom'
import { useCart } from '../context/CartContext'
import { useStore } from '../context/StoreContext'
import { useToast } from '../context/ToastContext'
import { api } from '../lib/api'
import { formatPrice, optionPrice } from '../lib/format'
import { productCategoryLabel } from '../lib/categories'
import { productName } from '../lib/productText'
import { useTranslation } from 'react-i18next'
import { LoadingIndicator } from '../components/LoadingIndicator'

export function CartPage() {
  const { store, refreshProducts } = useStore()
  useCodReceiptRecovery(store?.id)
  const { items, products, loadingProducts, productsError, setQuantity, removeItem, customerDiscount } = useCart()
  const { addToast } = useToast()
  const navigate = useNavigate()
  const [searchParams] = useSearchParams()
  const paymentCode = searchParams.get('payment')
  const storeId = store?.id
  const { t, i18n } = useTranslation()

  useEffect(() => {
    if (!paymentCode || !storeId) return
    if (!/^[a-z0-9-]{4,64}$/i.test(paymentCode)) {
      navigate('/cart', { replace: true })
      return
    }

    let active = true
    let timer: number | undefined
    let retries = 15
    const finish = (failed: boolean) => {
      addToast(t(failed ? 'Payment was unsuccessful' : 'Payment has not been confirmed'))
      navigate('/cart', { replace: true })
    }

    const check = async () => {
      try {
        const order = await api.getOrderByReceipt(paymentCode)
        if (!active) return
        if (order?.storeId === storeId && order.paymentMethod === 'ONLINE' && order.paymentStatus === 'PAID') {
          navigate(`/receipt/${encodeURIComponent(order.receiptCode)}`, { replace: true, state: { returnedFromPayment: true } })
          return
        }
        const status = order?.paymentStatus ?? await api.getOnlineCheckoutStatus(paymentCode)
        if (!active) return
        if (status === 'FAILED' || status === 'REFUNDED') {
          finish(true)
          return
        }
      } catch {
        if (!active) return
      }
      if (retries > 0) {
        retries -= 1
        timer = window.setTimeout(() => void check(), 2000)
      } else {
        finish(false)
      }
    }

    void check()
    return () => {
      active = false
      window.clearTimeout(timer)
    }
  }, [paymentCode, storeId, addToast, navigate, t])

  if (!store) return null
  if (loadingProducts && !items.length) return <LoadingIndicator label={t('Loading…')} />
  if (productsError) return <section className="page-status">
    <p role="alert">{t('Could not load the products in your cart.')}</p>
    <button type="button" className="btn" onClick={refreshProducts}>{t('Try again')}</button>
  </section>

  const rows = items
    .map((item) => {
      const product = products.find((entry) => entry.id === item.productId)
      const option = product?.productOptions.find((entry) => entry.id === item.optionId)
      if (!product || !option) return null
      const unit = optionPrice(option)
      return { item, product, option, unit, line: unit * item.quantity, limit: purchaseQuantityLimit(option) }
    })
    .filter((row) => row !== null)

  const subtotal = rows.reduce((sum, row) => sum + row.line, 0)
  const unavailableItems = rows.some(row => row.item.quantity > row.limit)
  const total = rows.reduce((sum, row) => sum + customerUnitPrice(row.option, customerDiscount.percent) * row.item.quantity, 0)
  const personalSavings = Math.round((subtotal - total) * 100) / 100

  if (rows.length === 0) {
    return (
      <section className="cart-empty">
        <p className="eyebrow">{t('Your order')}</p>
        <h1>{t('Cart is empty')}</h1>
        {paymentCode && <p role="status">{t('Waiting for payment confirmation…')}</p>}
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
      {paymentCode && <p role="status">{t('Waiting for payment confirmation…')}</p>}
      <div className="cart-page__layout"><div>
      <div className="cart-list-heading"><div><p className="eyebrow">01 / {t('Your order')}</p><h2>{t('Your selection')}</h2></div><span>{rows.length}</span></div>
      <ul className="line-list">
        {rows.map(({ item, product, option, unit, line, limit }) => (
          <li key={`${item.productId}-${item.optionId}`} className="line cart-line">
            {product.imgUrls[0] && <img src={product.imgUrls[0]} alt="" />}
            <div className="cart-line__product">
              <p className="cart-line__category">{productCategoryLabel(product, i18n.resolvedLanguage) ?? t('Uncategorized')}</p>
              <Link to={`/product/${product.id}`}>{productName(product, i18n.resolvedLanguage)}</Link>
              <p className="muted">{t('Option')}: {option.name}{option.isPreOrder ? ` · ${t('pre-order')}` : ''}</p>
              <p>{formatPrice(unit, store.currency)}</p>
              {item.quantity > limit && <p className="error">{t(unavailableQuantity)}</p>}
            </div>
            <label className="qty cart-line__quantity">
              <span>{t('Quantity')}</span>
              <input
                type="number"
                min={1}
                max={Math.max(1, limit)}
                disabled={limit === 0}
                value={item.quantity}
                onChange={(event) =>
                  setQuantity(item.productId, item.optionId, Math.max(1, Math.min(limit, Math.trunc(Number(event.target.value)) || 1)))
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
        <div className="cart-summary__detail"><span>{t('Items in order: {{quantity}}', { quantity: rows.reduce((sum, row) => sum + row.item.quantity, 0) })}</span><strong>{formatPrice(subtotal, store.currency)}</strong></div>
        <div className="cart-summary__detail"><span>{t('Delivery')}</span><span>{t('Shipping cost is confirmed after dispatch.')}</span></div>
        {personalSavings > 0 && <div className="cart-summary__detail personal-discount-summary"><span>{t('Personal discount')} · {customerDiscount.percent}%</span><strong>−{formatPrice(personalSavings, store.currency)}</strong></div>}
        {customerDiscount.loading && <p role="status">{t('Checking your discount…')}</p>}
        {customerDiscount.error && <p className="error" role="alert">{t(customerDiscount.error)} <button type="button" className="text-btn" onClick={customerDiscount.retry}>{t('Try again')}</button></p>}
        <div className="summary"><span>{t('Total')}</span><strong>{formatPrice(total, store.currency)}</strong></div>
        {paymentCode || loadingProducts || unavailableItems ? <button type="button" className="btn" disabled>{t('Checkout')}</button> : <Link to="/checkout" className="btn">
          {t('Checkout')} <span aria-hidden="true">↗</span>
        </Link>}
      </aside></div>
    </section>
  )
}
