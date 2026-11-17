import { useTranslation } from 'react-i18next'
import { costCurrencies, parseUnitCost, type CatalogExchangeRate, type CostCurrency } from '../lib/catalogCosts'
import { formatPrice } from '../lib/format'

export function CatalogCostInput({ label, amount, currency, rates, disabled, placeholder, hint, onChange }: {
  label: string
  amount: string
  currency: CostCurrency
  rates: CatalogExchangeRate[]
  disabled?: boolean
  placeholder?: string
  hint?: string
  onChange: (amount: string, currency: CostCurrency) => void
}) {
  const { t, i18n } = useTranslation()
  const rate = rates.find(item => item.currency === currency)
  const minor = parseUnitCost(amount)
  const hasCost = minor != null && currency !== 'UAH'
  const rateDate = rate && new Intl.DateTimeFormat(i18n.resolvedLanguage, { dateStyle: 'short', timeZone: 'UTC' })
    .format(new Date(rate.rate_date + 'T00:00:00Z'))

  return <div className="catalog-cost-field" role="group" aria-label={label}>
    <span className="catalog-cost-field__label">{label}</span>
    <div className="catalog-cost-field__control">
      <input aria-label={label} type="number" min="0" step="0.01" max="21474836.47" value={amount}
        placeholder={placeholder} disabled={disabled} onChange={event => onChange(event.target.value, currency)} />
      <select aria-label={t('Cost currency')} value={currency} disabled={disabled}
        onChange={event => onChange(amount, event.target.value as CostCurrency)}>
        {costCurrencies.map(code => <option key={code} value={code}>{code}</option>)}
      </select>
    </div>
    {hasCost && <small className="muted">
      {rate ? t('≈ {{amount}} · NBU rate {{date}}', { amount: formatPrice(Math.round(minor * rate.uah_rate) / 100, 'UAH'), date: rateDate })
        : t('Exchange rate is unavailable. Try again shortly.')}
    </small>}
    {hint && <small className="muted">{hint}</small>}
  </div>
}
