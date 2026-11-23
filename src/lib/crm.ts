import { supabaseRequest } from './supabase'

export const crmPageSize = 50

export type CrmPage<T> = { rows: T[]; page: number; total: number }
export type CrmPageEndpoint = 'crm_orders_page' | 'crm_customers_page' | 'crm_catalog_page'

export function fetchCrmPage<T>(endpoint: CrmPageEndpoint, body: string, token: string, signal?: AbortSignal) {
  return supabaseRequest<CrmPage<T>>(`/rest/v1/rpc/${endpoint}`, { method: 'POST', body, token, signal })
}

// Exports are the only list action that reads every matching page.
export async function fetchCrmExportRows<T>(endpoint: CrmPageEndpoint, filters: object, token: string) {
  const size = 200
  const rows: T[] = []
  for (let page = 1; ; page++) {
    const result = await fetchCrmPage<T>(endpoint, JSON.stringify({ ...filters, p_page: page, p_page_size: size }), token)
    if (result.page !== page) return rows
    rows.push(...result.rows)
    if (page * size >= result.total || result.rows.length === 0) return rows
  }
}

export function orderPaymentStatusKey(order: { status: string; payment_method: string; payment_status: string }) {
  if (order.payment_method === 'CASH_ON_DELIVERY' && order.payment_status === 'PENDING' && order.status.startsWith('CANCELLED')) {
    return 'payment_UNPAID'
  }
  return `payment_${order.payment_status}`
}

export type StoreStaffRole = 'OWNER' | 'MANAGER' | 'CONTENT'

export async function getStoreStaffRole(storeId: string, userId: string, token: string, signal?: AbortSignal) {
  const memberships = await supabaseRequest<Array<{ role: StoreStaffRole }>>(
    `/rest/v1/store_members?store_id=eq.${encodeURIComponent(storeId)}&user_id=eq.${encodeURIComponent(userId)}&select=role`,
    { token, signal },
  )
  return memberships[0]?.role ?? null
}

export async function hasStoreMembership(storeId: string, userId: string, token: string, signal?: AbortSignal): Promise<boolean> {
  return (await getStoreStaffRole(storeId, userId, token, signal)) !== null
}

// PostgREST defaults to a capped result set; fetch every page for exports and aggregates.
export async function fetchAll<T>(path: string, token: string, signal?: AbortSignal): Promise<T[]> {
  const result: T[] = []
  for (let offset = 0; ; ) {
    const rows = await supabaseRequest<T[]>(`${path}&limit=500&offset=${offset}`, { token, signal })
    result.push(...rows)
    if (!rows.length) return result
    offset += rows.length
  }
}

export function downloadCsv(filename: string, rows: unknown[][]) {
  const quote = (value: unknown) => {
    let text = String(value ?? '')
    if (typeof value === 'string' && /^[\s\uFEFF]*[=+@\-\t\r\n]/.test(text)) text = `'${text}`
    return `"${text.replaceAll('"', '""')}"`
  }
  const url = URL.createObjectURL(new Blob(['\uFEFF', rows.map(row => row.map(quote).join(';')).join('\r\n')], { type: 'text/csv;charset=utf-8' }))
  const link = document.createElement('a')
  link.href = url
  link.download = filename
  link.click()
  window.setTimeout(() => URL.revokeObjectURL(url), 1000)
}

export const customerPhone = (value: string) => {
  const digits = value.replace(/\D/g, '')
  return digits.length === 10 && digits.startsWith('0') ? `38${digits}` : digits
}
