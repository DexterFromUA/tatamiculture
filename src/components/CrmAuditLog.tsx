import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { useCrmPage } from '../hooks/useCrmPage'
import { crmPageSize } from '../lib/crm'
import { CrmPagination } from './CrmPagination'

const areas = {
  orders: 'Orders',
  catalog: 'Catalogue',
  customers: 'Customers',
  settings: 'Settings',
  notifications: 'Notifications',
  exports: 'CSV exports',
} as const

const actions: Record<string, string> = {
  insert: 'Audit created', update: 'Audit updated', delete: 'Audit removed',
  order_status: 'Order status changed', merge: 'Orders merged', split_order: 'Order split',
  refund: 'Refund updated', refund_review: 'Refund reviewed',
  ttn_created: 'TTN created', ttn_linked: 'TTN linked', ttn_unlinked: 'TTN unlinked',
  ttn_attempt_closed: 'TTN attempt closed', tracking_refresh: 'Shipment tracking refreshed',
  customer_account_removed: 'Customer account removed', customers_merged: 'Customer cards merged',
  push_queued: 'Push queued', sms_queued: 'SMS queued', export_csv: 'CSV prepared',
}

const entities: Record<string, string> = {
  orders: 'Order', order_items: 'Order items', order_returns: 'Refunds',
  item_returns: 'Item returns', order_financials: 'Order costs', order_item_costs: 'Item costs',
  order_cancellation_refunds: 'Refund', products: 'Product', product_variants: 'Variant',
  categories: 'Category', product_categories: 'Product categories', product_images: 'Product photo',
  product_costs: 'Product cost', variant_costs: 'Variant cost', stock_movements: 'Stock adjustment',
  catalog_import_settings: 'Cost on import',
  crm_customers: 'Customer', crm_customer_keys: 'Customer account', customer_discounts: 'Personal discount',
  store_members: 'Administrator access', store_payment_methods: 'Payment methods',
  delivery_settings: 'Nova Poshta settings', shop_settings: 'Store settings',
  storefront_theme_settings: 'Theme', storefront_banners: 'Homepage banner', storefront_contacts: 'Contacts',
  crm_staff_push_preferences: 'Staff push notifications', crm_staff_sms_preferences: 'Staff SMS notifications',
  customer_push_broadcasts: 'Notification broadcast', crm_sms_requests: 'SMS notifications',
  sms_provider: 'SMS provider',
}

const fieldLabels: Record<string, string> = {
  status: 'Status', payment_status: 'Payment status', payment_method: 'Payment method', provider: 'SMS provider',
  nova_poshta_status_code: 'Shipment status code', nova_poshta_status: 'Shipment status', nova_poshta_ttn: 'TTN',
  customer_name: 'Name', customer_phone: 'Phone', customer_email: 'Email', delivery_city: 'City',
  delivery_address: 'Delivery address', delivery_city_ref: 'City', delivery_address_ref: 'Delivery address',
  stock_quantity: 'Stock', quantity: 'Quantity', low_stock_threshold: 'Low stock threshold',
  percent: 'Discount', is_active: 'Published', is_new: 'New', enabled: 'Enabled',
  payment_test_mode: 'Payment mode', cash_on_delivery: 'Payment on delivery', cost_amount: 'Cost',
  order_sms_enabled: 'Order status SMS', order_push_enabled: 'Order status push',
  restock_sms_enabled: 'Back-in-stock SMS', sms_notifications_enabled: 'Back-in-stock push',
  auto_update_order_status: 'Update order statuses automatically', previous_quantity: 'Previous stock',
  nova_poshta_tracking_interval_minutes: 'Tracking interval in minutes',
  auto_fill_cost: 'Fill in the cost automatically', cost_discount_percent: 'Discount from supplier price, %',
}

type AuditRow = {
  id: number
  occurred_at: string
  actor_id: string | null
  actor_name: string | null
  entity: string
  entity_id: string | null
  action: string
  fields: string[]
  details: Record<string, unknown>
}

type FieldChange = { before: string | number | boolean | null; after: string | number | boolean | null }

function isFieldChange(detail: unknown): detail is FieldChange {
  return typeof detail === 'object' && detail !== null && 'before' in detail && 'after' in detail
}

export function CrmAuditLog() {
  const { store } = useStore()
  const { token } = useAuth()
  const { t, i18n } = useTranslation()
  const [page, setPage] = useState(1)
  const [area, setArea] = useState<keyof typeof areas | ''>('')
  const [search, setSearch] = useState('')
  const filters = { p_store_id: store?.id, p_area: area || null, p_search: search.trim() }
  const { data, error, loading, retry } = useCrmPage<AuditRow>('crm_audit_log_page', filters, page, token, 0)
  const dateTime = new Intl.DateTimeFormat(i18n.resolvedLanguage === 'uk' ? 'uk-UA' : 'en-GB', { dateStyle: 'short', timeStyle: 'short' })
  const pages = Math.max(1, Math.ceil((data?.total ?? 0) / crmPageSize))
  const searchLabel = t('Search by administrator or record ID')

  function formatValue(field: string, value: FieldChange['after']) {
    if (value === null) return '—'
    if (field === 'payment_test_mode') return t(value ? 'Test mode' : 'Live mode')
    if (typeof value === 'boolean') return t(value ? 'Enabled' : 'Disabled')
    if (field === 'payment_status') return t(`payment_${value}`)
    if (field === 'payment_method') return t(value === 'CASH_ON_DELIVERY' ? 'Payment on delivery' : 'Online payment')
    if (field === 'provider') return { twilio: 'Twilio', kyivstar: 'Kyivstar', smsclub: 'SMSClub' }[String(value)] ?? String(value)
    if (typeof value === 'number') return String(value)
    return t(value)
  }

  return <section className="settings-card crm-audit" aria-busy={loading}>
    <div className="customers-toolbar crm-audit__filters">
      <label className="search-field">
        <span className="sr-only">{searchLabel}</span>
        <input type="search" maxLength={100} value={search} placeholder={searchLabel} onChange={event => { setSearch(event.target.value); setPage(1) }} />
      </label>
      <select aria-label={t('Activity category')} value={area} onChange={event => { setArea(event.target.value as typeof area); setPage(1) }}>
        <option value="">{t('All activity')}</option>
        {Object.entries(areas).map(([key, label]) => <option key={key} value={key}>{t(label)}</option>)}
      </select>
      <button type="button" className="btn btn--ghost" disabled={loading} onClick={retry}>{t('Refresh')}</button>
    </div>
    {error && <p className="error" role="alert">{t('Could not load the activity log.')}</p>}
    {loading && !data && <p className="muted" role="status">{t('Loading…')}</p>}
    {data?.rows.length === 0 && <p className="muted">{t('No activity matches these filters.')}</p>}
    {Boolean(data?.rows.length) && <ol className="crm-audit__list">
      {data?.rows.map(entry => {
        const affectedId = entry.details.order_id ?? entry.details.product_id ?? entry.entity_id
        const fields = [...new Set([...entry.fields, ...Object.keys(entry.details).filter(key => isFieldChange(entry.details[key]))])]
        return <li key={entry.id} className="crm-audit__entry">
          <div className="crm-audit__entry-head">
            <div><strong>{t(actions[entry.action] ?? entry.action)}</strong>
              <p>{t(entities[entry.entity] ?? entry.entity)} · {entry.actor_name || (entry.actor_id ? entry.actor_id.slice(0, 8) : t('System'))}</p>
            </div>
            <time dateTime={entry.occurred_at}>{dateTime.format(new Date(entry.occurred_at))}</time>
          </div>
          {typeof entry.details.recipient_count === 'number' && <p>{t('Recipients: {{count}}', { count: entry.details.recipient_count })}</p>}
          {typeof entry.details.row_count === 'number' && <p>{t('Exported rows: {{count}}', { count: entry.details.row_count })}</p>}
          {(typeof affectedId === 'string' || fields.length > 0) && <details>
            <summary>{t('Details')}</summary>
            {typeof affectedId === 'string' && <p>{t('Record ID')} <code>{affectedId}</code></p>}
            {typeof entry.details.merged_customer_id === 'string' && <p>{t('Merged customer ID')} <code>{entry.details.merged_customer_id}</code></p>}
            {fields.length > 0 && <ul className="crm-audit__fields">
              {fields.map(field => {
                const detail = entry.details[field]
                return <li key={field}>
                  <span>{t(fieldLabels[field] ?? field.replaceAll('_', ' '))}</span>
                  {isFieldChange(detail) && <span>{formatValue(field, detail.before)} → {formatValue(field, detail.after)}</span>}
                </li>
              })}
            </ul>}
          </details>}
        </li>
      })}
    </ol>}
    {pages > 1 && <CrmPagination page={data?.page ?? page} pages={pages} loading={loading} onChange={setPage} />}
  </section>
}
