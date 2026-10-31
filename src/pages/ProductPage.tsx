import { useMemo, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useCart } from '../context/CartContext'
import { useStore } from '../context/StoreContext'
import { useToast } from '../context/ToastContext'
import { formatPrice, optionPrice } from '../lib/format'

export function ProductPage() {
  const { productId } = useParams()
  const { store, products } = useStore()
  const { addItem } = useCart()
  const { addToast } = useToast()
  const product = products.find((item) => item.id === productId)
  const [optionId, setOptionId] = useState(product?.productOptions[0]?.id ?? '')
  const [quantity, setQuantity] = useState(1)
  const [imageIndex, setImageIndex] = useState(0)

  const option = useMemo(
    () => product?.productOptions.find((item) => item.id === optionId) ?? product?.productOptions[0],
    [optionId, product],
  )

  if (!store) return null

  if (!product || !option) {
    return (
      <div className="page-status">
        <h1>Product not found</h1>
        <Link to="/">Back to shop</Link>
      </div>
    )
  }

  const price = optionPrice(option)
  const images = product.imgUrls
  const activeImage = images[imageIndex] ?? images[0]
  const changeImage = (direction: -1 | 1) => {
    setImageIndex((current) => (current + direction + images.length) % images.length)
  }

  const addToCart = () => {
    addItem(product.id, option.id, quantity)
    addToast('Added to cart')
  }

  return (
    <article className="product-view">
      <div className="product-gallery">
        <div className="product-view__image">
          <img src={activeImage} alt={product.name} />
          {images.length > 1 ? <div className="gallery-controls">
            <button type="button" onClick={() => changeImage(-1)} aria-label="Previous image">←</button>
            <span>{imageIndex + 1} / {images.length}</span>
            <button type="button" onClick={() => changeImage(1)} aria-label="Next image">→</button>
          </div> : null}
        </div>
        {images.length > 1 ? <div className="gallery-thumbnails">
          {images.map((image, index) => <button type="button" className={index === imageIndex ? 'active' : ''} key={image} onClick={() => setImageIndex(index)} aria-label={`Show image ${index + 1}`}><img src={image} alt="" /></button>)}
        </div> : null}
      </div>
      <div className="product-view__body">
        <p className="muted">{product.category}</p>
        <h1>{product.name}</h1>
        <p className="lede">{product.description}</p>
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
          <span>Option</span>
          <select value={option.id} onChange={(event) => setOptionId(event.target.value)}>
            {product.productOptions.map((item) => (
              <option key={item.id} value={item.id}>
                {item.name}
                {item.isPreOrder ? ' · pre-order' : ''}
                {item.isLimited ? ` · ${item.quantity} left` : ''}
              </option>
            ))}
          </select>
        </label>
        <label className="field">
          <span>Quantity</span>
          <input
            type="number"
            min={1}
            max={option.isLimited ? option.quantity : 10}
            value={quantity}
            onChange={(event) => setQuantity(Math.max(1, Number(event.target.value) || 1))}
          />
        </label>
        {option.isPreOrder ? <p className="note">This option is a pre-order. Production starts after checkout.</p> : null}
        <div className="actions">
          <button type="button" className="btn" onClick={addToCart}>
            Add to cart
          </button>
          <Link to="/cart" className="btn btn--ghost">
            View cart
          </Link>
        </div>
      </div>
    </article>
  )
}
