import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { CatalogCostInput } from './CatalogCostInput'
import { costInputAmount, parseUnitCost, saveCatalogCosts, type CatalogCost, type CatalogExchangeRate, type CostCurrency } from '../lib/catalogCosts'

export function VariantCostEditor({ productId, variantId, cost, rates, token, onSaved }: {
  productId: string
  variantId: string
  cost: CatalogCost | null
  rates: CatalogExchangeRate[]
  token: string
  onSaved: () => Promise<void>
}) {
  const { t } = useTranslation()
  const [amount, setAmount] = useState(costInputAmount(cost))
  const [currency, setCurrency] = useState<CostCurrency>(cost?.currency ?? 'UAH')
  const [message, setMessage] = useState('')
  const [busy, setBusy] = useState(false)
  return <form className="inline-form" onSubmit={async event => {
    event.preventDefault()
    if (busy) return
    const minor = parseUnitCost(amount)
    if (minor === undefined) {
      setMessage(t('Enter a valid unit cost.'))
      return
    }
    setBusy(true)
    setMessage('')
    try {
      await saveCatalogCosts(token, productId, null, [{ variant_id: variantId, cost_amount: minor, currency }])
      setMessage(t('Saved'))
      await onSaved()
    } catch (cause) {
      setMessage(cause instanceof Error ? t(cause.message) : t('Action failed'))
    } finally {
      setBusy(false)
    }
  }}>
    <CatalogCostInput label={t('Unit cost')} amount={amount} currency={currency} rates={rates} disabled={busy}
      onChange={(nextAmount, nextCurrency) => { setAmount(nextAmount); setCurrency(nextCurrency) }} />
    <button className="text-btn" disabled={busy}>{t('Save')}</button>
    {message && <p role="status">{message}</p>}
  </form>
}
