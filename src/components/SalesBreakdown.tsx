import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { fetchAll } from '../lib/crm'
import { formatPrice } from '../lib/format'

type Sale = {
  id: string
  product_id: string | null
  variant_id: string | null
  product_name: string
  variant_name: string
  quantity: number
  line_total: number
  orders: { created_at: string; currency: string }
}

type Inventory = { id: string; name: string; created_at: string; categories: { name: string } | null; product_variants: Array<{ id: string; name: string; stock_quantity: number; is_preorder: boolean }> }
type Demand = { variant_id: string }

export function SalesBreakdown({ storeId, token }: { storeId: string; token: string }) {
  const { t } = useTranslation()
  const [rows, setRows] = useState<Sale[]>([])
  const [inventory, setInventory] = useState<Inventory[]>([])
  const [demand, setDemand] = useState<Demand[]>([])
  const [group, setGroup] = useState('variant')
  const [days, setDays] = useState(30)
  const [error, setError] = useState('')
  const [loading, setLoading] = useState(true)
  const [now] = useState(() => Date.now())
  useEffect(() => {
    const abort = new AbortController()
    const since = new Date(now - 730 * 86400000).toISOString()
    Promise.all([fetchAll<Sale>(`/rest/v1/order_items?select=id,product_id,variant_id,product_name,variant_name,quantity,line_total,orders!inner(created_at,currency,store_id,status)&orders.store_id=eq.${storeId}&orders.status=eq.DELIVERED&orders.created_at=gte.${since}&order=id`, token, abort.signal)
      , fetchAll<Inventory>(`/rest/v1/products?store_id=eq.${storeId}&select=id,name,created_at,categories(name),product_variants(id,name,stock_quantity,is_preorder)&order=id`, token, abort.signal),
        fetchAll<Demand>(`/rest/v1/restock_subscriptions?notified_at=is.null&select=variant_id,user_id,product_variants!inner(products!inner(store_id))&product_variants.products.store_id=eq.${storeId}&order=variant_id,user_id`, token, abort.signal),
      ]).then(([sales, products, subscriptions]) => { setRows(sales); setInventory(products); setDemand(subscriptions) }).catch(cause => { if (!abort.signal.aborted) setError(cause.message) })
      .finally(() => { if (!abort.signal.aborted) setLoading(false) })
    return () => abort.abort()
  }, [storeId, token, now])
  const totals = new Map<string, { name: string; variant: string; currency: string; units: number; revenue: number; previous: number }>()
  for (const row of rows) {
    const age = now - new Date(row.orders.created_at).getTime()
    if (age < 0 || age >= days * 2 * 86400000) continue
    const product = inventory.find(item => item.id === row.product_id)
    const name = group === 'category' ? product?.categories?.name ?? t('Uncategorized') : row.product_name
    const variant = group === 'variant' ? row.variant_name : ''
    const identity = group === 'category' ? name : group === 'product' ? row.product_id ?? row.product_name : row.variant_id ?? `${row.product_name}-${row.variant_name}`
    const key = JSON.stringify([identity, row.orders.currency])
    const current = totals.get(key) ?? { name, variant, currency: row.orders.currency, units: 0, revenue: 0, previous: 0 }
    if (age < days * 86400000) {
      current.units += row.quantity
      current.revenue += Number(row.line_total)
    } else {
      current.previous += Number(row.line_total)
    }
    totals.set(key, current)
  }
  const idle = inventory.filter(product => now - new Date(product.created_at).getTime() >= days * 86400000 && !rows.some(row => row.product_id === product.id && now - new Date(row.orders.created_at).getTime() < days * 86400000) && product.product_variants.some(variant => !variant.is_preorder && variant.stock_quantity > 0))
  const demandCounts = new Map<string, number>()
  for (const subscription of demand) demandCounts.set(subscription.variant_id, (demandCounts.get(subscription.variant_id) ?? 0) + 1)
  return <section className="crm-panel">
    <h2>{t('Product sales')}</h2>
    <label className="field">{t('Period')}
      <select value={days} onChange={event => setDays(Number(event.target.value))}>
        {[7, 30, 90, 365].map(value => <option key={value} value={value}>{value} {t('days')}</option>)}
      </select>
    </label>
    <label className="field">{t('Group by')}<select value={group} onChange={event => setGroup(event.target.value)}>
      <option value="variant">{t('Size')}</option><option value="product">{t('Products')}</option><option value="category">{t('Category')}</option>
    </select></label>
    <p>{t('Categories reflect the current catalogue.')}</p>
    <p>{t('Delivered sales by order date. Previous period has the same length.')}</p>
    {error && <p className="error">{error}</p>}
    {loading ? <p>{t('Loading…')}</p> : <ul className="customers-list">
      {[...totals.entries()].sort((a, b) => b[1].units - a[1].units).map(([key, row]) => <li key={key}>
        <div><strong>{row.name}</strong><span>{row.variant} · {row.units} {t('units')}</span></div>
        <div><strong>{formatPrice(row.revenue / 100, row.currency)}</strong>
          <span>{t('Previous period')} · {formatPrice(row.previous / 100, row.currency)}</span>
        </div>
      </li>)}
      {totals.size === 0 && <li>{t('No sales in this period')}</li>}
    </ul>}
    <h3>{t('Stock without sales in this period')}</h3>
    <ul>{idle.map(product => <li key={product.id}>{product.name} · {product.product_variants.reduce((sum, variant) => sum + (variant.is_preorder ? 0 : variant.stock_quantity), 0)} {t('units')}</li>)}</ul>
    <h3>{t('Restock demand')}</h3>
    <ul>{inventory.flatMap(product => product.product_variants.filter(variant => demandCounts.has(variant.id)).map(variant => <li key={variant.id}>{product.name} · {variant.name} · {demandCounts.get(variant.id)} {t('subscriptions')}</li>))}</ul>
  </section>
}
