import { Link } from 'react-router-dom'
import { useCart } from '../context/CartContext'
import { useStore } from '../context/StoreContext'
import { formatPrice, optionPrice } from '../lib/format'

export function CartPage() {
  const { store, products } = useStore()
  const { items, setQuantity, removeItem } = useCart()

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
      <section className="page-status">
        <h1>Cart is empty</h1>
        <Link to="/">Continue shopping</Link>
      </section>
    )
  }

  return (
    <section>
      <header className="page-head">
        <h1>Cart</h1>
      </header>
      <ul className="line-list">
        {rows.map(({ item, product, option, unit, line }) => (
          <li key={`${item.productId}-${item.optionId}`} className="line">
            <img src={product.imgUrls[0]} alt="" />
            <div>
              <Link to={`/product/${product.id}`}>{product.name}</Link>
              <p className="muted">{option.name}</p>
              <p>{formatPrice(unit, store.currency)}</p>
            </div>
            <label className="qty">
              <span className="sr-only">Quantity</span>
              <input
                type="number"
                min={1}
                value={item.quantity}
                onChange={(event) =>
                  setQuantity(item.productId, item.optionId, Math.max(1, Number(event.target.value) || 1))
                }
              />
            </label>
            <strong>{formatPrice(line, store.currency)}</strong>
            <button type="button" className="text-btn" onClick={() => removeItem(item.productId, item.optionId)}>
              Remove
            </button>
          </li>
        ))}
      </ul>
      <div className="summary">
        <p>
          Total <strong>{formatPrice(total, store.currency)}</strong>
        </p>
        <Link to="/checkout" className="btn">
          Checkout
        </Link>
      </div>
    </section>
  )
}
