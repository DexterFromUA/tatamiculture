import { useEffect, useState } from 'react'
import { Link, useParams } from 'react-router-dom'
import { useTranslation } from 'react-i18next'
import { formatPrice, optionPrice } from '../lib/format'
import { api } from '../lib/api'
import type { Product, Store } from '../types'

export function QuickBuyPage() {
  const { code } = useParams()
  const { t } = useTranslation()
  const [loading, setLoading] = useState(true)
  const [loadFailed, setLoadFailed] = useState(false)
  const [payload, setPayload] = useState<{ store: Store; product: Product } | null>(null)

  useEffect(() => {
    let cancelled = false

    const load = async () => {
      if (!code) return
      const next = await api.getShortLink(code)
      if (!cancelled) {
        setPayload(next ? { store: next.store, product: next.product } : null)
        setLoading(false)
      }
    }

    void load().catch(() => {
      if (cancelled) return
      setLoadFailed(true)
      setLoading(false)
    })
    return () => {
      cancelled = true
    }
  }, [code])

  if (loading) return <div className="page-status">Opening link…</div>
  if (loadFailed) return <main className="page-status"><h1>{t('Store temporarily unavailable')}</h1></main>

  if (!payload) {
    return (
      <section className="page-status">
        <h1>Link expired</h1>
        <p>This short link is unavailable.</p>
        <Link to="/">{t('Go to Tatami.Culture')}</Link>
      </section>
    )
  }

  const { store, product } = payload
  const price = Math.min(...product.productOptions.map(optionPrice))

  return (
    <section className="page-status">
      <p className="muted">{store.name} · quick buy</p>
      <h1>{product.name}</h1>
      <p>From {formatPrice(price, store.currency)}</p>
      <Link className="btn" to={`/product/${product.id}`}>
        View product
      </Link>
    </section>
  )
}
