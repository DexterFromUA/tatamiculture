import { ProductCard } from '../components/ProductCard'
import { useStore } from '../context/StoreContext'

export function CatalogPage() {
  const { store, products } = useStore()
  if (!store) return null

  return (
    <section>
      <header className="page-head">
        <h1>{store.name}</h1>
        <p className="lede">{store.description}</p>
      </header>
      <div className="grid">
        {products.map((product) => (
          <ProductCard key={product.id} product={product} store={store} />
        ))}
      </div>
    </section>
  )
}
