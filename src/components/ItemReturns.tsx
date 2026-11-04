import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { supabaseRequest } from '../lib/supabase'
import { formatPrice } from '../lib/format'

type Item = { id: string; product_id: string | null; variant_id: string | null; product_name: string; variant_name: string; quantity: number; unit_price: number }
type Return = { id: string; item_id: string; quantity: number; reason: string; status: string; replacement_variant: string | null; refund_amount: number; restock: boolean }
type Variant = { id: string; product_id: string; name: string; price: number; stock_quantity: number }
export function ItemReturns({ orderId, token, currency, onChange }: { orderId: string; token: string; currency: string; onChange: () => void }) {
  const { t } = useTranslation()
  const [items, setItems] = useState<Item[]>([])
  const [returns, setReturns] = useState<Return[]>([])
  const [variants, setVariants] = useState<Variant[]>([])
  const [selected, setSelected] = useState('')
  const [replacement, setReplacement] = useState('')
  const [revision, setRevision] = useState(0)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const requestId = useRef(crypto.randomUUID())
  useEffect(() => {
    const abort = new AbortController()
    Promise.all([
      supabaseRequest<Item[]>(`/rest/v1/order_items?order_id=eq.${orderId}&select=id,product_id,variant_id,product_name,variant_name,quantity,unit_price`, { token, signal: abort.signal }),
      supabaseRequest<Return[]>(`/rest/v1/item_returns?order_id=eq.${orderId}&select=*&order=created_at.desc`, { token, signal: abort.signal }),
    ]).then(([nextItems, nextReturns]) => { setItems(nextItems); setReturns(nextReturns) })
      .catch(cause => { if (!abort.signal.aborted) setError(cause.message) })
    return () => abort.abort()
  }, [orderId, token, revision])
  const item = items.find(row => row.id === selected)
  useEffect(() => {
    if (!item?.product_id) return
    const abort = new AbortController()
    supabaseRequest<Variant[]>(`/rest/v1/product_variants?product_id=eq.${item.product_id}&is_preorder=eq.false&select=id,product_id,name,price,stock_quantity&order=position`, { token, signal: abort.signal })
      .then(setVariants).catch(cause => { if (!abort.signal.aborted) setError(cause.message) })
    return () => abort.abort()
  }, [item?.product_id, token, revision])
  const available = item ? item.quantity - returns.filter(row => row.item_id === item.id && row.status !== 'cancelled').reduce((sum, row) => sum + row.quantity, 0) : 0
  const refresh = () => { setRevision(value => value + 1); onChange() }
  const advance = async (id: string, status: string) => {
    if (busy) return
    if (status === 'completed' && !window.confirm(t('Confirm that the refund was paid or the replacement was handed over.'))) return
    setBusy(true)
    setError('')
    try {
      await supabaseRequest('/rest/v1/rpc/advance_item_return', { method: 'POST', token, body: JSON.stringify({ p_id: id, p_status: status }) })
      refresh()
    } catch (cause) { setError(cause instanceof Error ? cause.message : t('Action failed')) } finally { setBusy(false) }
  }
  return <section className="order-drawer__card">
    <div className="order-drawer__section-heading"><span className="order-drawer__section-number">02</span><h3>{t('Returns and size exchanges')}</h3></div>
    <p className="muted">{t('Confirm payment here after issuing the refund through your payment provider.')}</p>
    {error && <p className="error" role="alert">{error}</p>}
    <ul className="note-list">{returns.map(row => <li key={row.id}>
      <p>{items.find(item => item.id === row.item_id)?.product_name} · {items.find(item => item.id === row.item_id)?.variant_name} × {row.quantity}</p>
      <p>{t(`return_${row.status}`)} · {row.replacement_variant ? t('Size exchange') : formatPrice(row.refund_amount / 100, currency)} · {row.reason}</p>
      <div className="actions">
        {row.status === 'requested' && <><button className="text-btn" disabled={busy} onClick={() => void advance(row.id, 'received')}>{t('Item received')}</button><button className="text-btn" disabled={busy} onClick={() => void advance(row.id, 'cancelled')}>{t('Cancel')}</button></>}
        {row.status === 'received' && <button className="text-btn" disabled={busy} onClick={() => void advance(row.id, 'completed')}>{t(row.replacement_variant ? 'Replacement handed over' : 'Refund paid')}</button>}
      </div>
    </li>)}</ul>
    <form className="form" onSubmit={async event => {
      event.preventDefault()
      if (busy || !item || available < 1) return
      const form = event.currentTarget
      const data = new FormData(form)
      setBusy(true)
      setError('')
      try {
        await supabaseRequest('/rest/v1/rpc/request_item_return', { method: 'POST', token, body: JSON.stringify({
          p_id: requestId.current, p_item: item.id, p_quantity: Number(data.get('quantity')),
          p_reason: data.get('reason'), p_restock: data.get('restock') === 'on', p_replacement: replacement || null,
        }) })
        requestId.current = crypto.randomUUID()
        form.reset()
        refresh()
      } catch (cause) { setError(cause instanceof Error ? cause.message : t('Action failed')) } finally { setBusy(false) }
    }}>
      <label className="field">{t('Order items')}<select required value={selected} onChange={event => { setSelected(event.target.value); setReplacement(''); requestId.current = crypto.randomUUID() }}>
        <option value="">{t('Select item')}</option>{items.map(item => <option key={item.id} value={item.id}>{item.product_name} · {item.variant_name}</option>)}
      </select></label>
      <label className="field">{t('Quantity')}<input name="quantity" required type="number" min="1" max={available} step="1" defaultValue="1" /></label>
      <label className="field">{t('Return or exchange')}<select value={replacement} onChange={event => setReplacement(event.target.value)}>
        <option value="">{t('Money refund')}</option>
        {variants.filter(variant => variant.product_id === item?.product_id && variant.id !== item.variant_id && variant.price === item.unit_price).map(variant => <option key={variant.id} value={variant.id}>{variant.name} · {variant.stock_quantity} {t('in stock')}</option>)}
      </select></label>
      <p>{t('Exchange is available for another size at the original price. Stock is checked when handed over.')}</p>
      <label className="check"><input name="restock" type="checkbox" defaultChecked />{t('Return received goods to stock')}</label>
      <label className="field">{t('Reason')}<textarea name="reason" required maxLength={1000} /></label>
      <button className="btn" disabled={busy || available < 1}>{t('Create return request')}</button>
    </form>
  </section>
}
