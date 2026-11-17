import { supabaseRequest } from './supabase'

export const costCurrencies = ['UAH', 'USD', 'EUR', 'PLN'] as const
export type CostCurrency = typeof costCurrencies[number]

export type CatalogCost = {
  cost_amount: number
  source_amount: number | null
  currency: CostCurrency
}

export type CatalogExchangeRate = {
  currency: CostCurrency
  uah_rate: number
  rate_date: string
}

export function parseUnitCost(value: string) {
  if (!value.trim()) return null
  const amount = Number(value)
  const minor = Math.round(amount * 100)
  return Number.isSafeInteger(minor) && amount >= 0 && minor <= 2147483647 ? minor : undefined
}

export function costInputAmount(cost: CatalogCost | null) {
  return cost ? String((cost.source_amount ?? cost.cost_amount) / 100) : ''
}

export function saveCatalogCosts(
  token: string,
  productId: string,
  defaultCost: { amount: number | null; currency: CostCurrency } | null,
  variantCosts: { variant_id: string; cost_amount: number | null | undefined; currency: CostCurrency }[],
) {
  return supabaseRequest('/rest/v1/rpc/save_catalog_costs_in_currency', {
    method: 'POST', token,
    body: JSON.stringify({
      p_product_id: productId,
      p_update_default: defaultCost !== null,
      p_default_cost: defaultCost?.amount ?? null,
      p_default_currency: defaultCost?.currency ?? 'UAH',
      p_variant_costs: variantCosts,
    }),
  })
}
