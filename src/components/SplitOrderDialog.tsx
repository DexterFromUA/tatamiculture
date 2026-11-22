import { useId, useState, type FormEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { formatPrice } from '../lib/format'
import { supabaseRequest } from '../lib/supabase'
import { CenteredDialog } from './CenteredDialog'

type SplitItem = {
  id: string
  product_name: string
  variant_name: string
  quantity: number
  line_total: number
}

export type SplitOrderResult = { order_id: string; receipt_code: string }

export function SplitOrderDialog({ orderId, items, total, currency, paid, token, onClose, onSplit }: {
  orderId: string
  items: SplitItem[]
  total: number
  currency: string
  paid: boolean
  token: string
  onClose: () => void
  onSplit: (order: SplitOrderResult) => void
}) {
  const { t } = useTranslation()
  const titleId = useId()
  const instructionsId = useId()
  const [quantities, setQuantities] = useState<Record<string, string>>({})
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const rows = items.map(item => ({ item, quantity: Number(quantities[item.id] || 0) }))
  const valid = rows.every(({ item, quantity }) => Number.isInteger(quantity) && quantity >= 0 && quantity <= item.quantity)
  const selected = rows.filter(row => row.quantity > 0)
  const selectedCount = selected.reduce((sum, row) => sum + row.quantity, 0)
  const itemCount = items.reduce((sum, item) => sum + item.quantity, 0)
  const canSubmit = valid && selectedCount > 0 && selectedCount < itemCount
  const movedTotal = valid ? selected.reduce((sum, { item, quantity }) => sum + Math.round(item.line_total * quantity / item.quantity), 0) : null

  const submit = async (event: FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (!canSubmit || busy) return
    setBusy(true)
    setError('')
    try {
      const result = await supabaseRequest<SplitOrderResult>('/rest/v1/rpc/split_order_items', {
        method: 'POST', token, body: JSON.stringify({
          p_order_id: orderId,
          p_items: selected.map(({ item, quantity }) => ({
            item_id: item.id, quantity, expected_quantity: item.quantity, expected_line_total: item.line_total,
          })),
        }),
      })
      onSplit(result)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Action failed')
    } finally {
      setBusy(false)
    }
  }

  return <CenteredDialog className="split-order-dialog" aria-labelledby={titleId} aria-describedby={instructionsId}
    busy={busy} onClose={onClose}>
    <h2 id={titleId}>{t('Split order')}</h2>
    <p id={instructionsId}>{t('Choose how many units of each item to move. Leave at least one item in the original order.')}</p>
    <form onSubmit={event => void submit(event)}>
      <ul className="split-order-dialog__items">
        {items.map(item => <li key={item.id}>
          <div>
            <strong>{item.product_name}</strong>
            <small>{item.variant_name} · {t('{{count}} in this order', { count: item.quantity })}</small>
          </div>
          <label className="split-order-dialog__quantity">
            <span className="sr-only">{t('Quantity to move for {{name}}', { name: [item.product_name, item.variant_name].filter(Boolean).join(' · ') })}</span>
            <input type="number" min="0" max={item.quantity} step="1" inputMode="numeric" disabled={busy}
              value={quantities[item.id] ?? '0'}
              onChange={event => {
                setQuantities(current => ({ ...current, [item.id]: event.target.value }))
                setError('')
              }} />
          </label>
        </li>)}
      </ul>
      {movedTotal !== null && <dl className="split-order-dialog__totals">
        <div><dt>{t('Remaining order total')}</dt><dd>{formatPrice((total - movedTotal) / 100, currency)}</dd></div>
        <div><dt>{t('New order total')}</dt><dd>{formatPrice(movedTotal / 100, currency)}</dd></div>
      </dl>}
      {paid && <p className="muted split-order-dialog__note">{t('Both parts stay paid. Any refund for a split order must be recorded manually.')}</p>}
      {selectedCount >= itemCount && <p className="error" role="status">{t('Leave at least one item in the original order.')}</p>}
      {error && <p className="error" role="alert">{t(error)}</p>}
      <div className="confirmation-dialog__actions">
        <button type="button" className="btn btn--ghost" disabled={busy} onClick={onClose}>{t('Cancel')}</button>
        <button type="submit" className="btn" disabled={!canSubmit || busy}>{t(busy ? 'Saving…' : 'Create separate order')}</button>
      </div>
    </form>
  </CenteredDialog>
}
