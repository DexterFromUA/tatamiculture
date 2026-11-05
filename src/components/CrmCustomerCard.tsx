import { CustomerAccountActions } from './CustomerAccountActions'
import { customerPhone } from '../lib/crm'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { supabaseRequest } from '../lib/supabase'
import { formatDate, formatPrice } from '../lib/format'

export type CrmCustomer = { id: string; name: string; phone: string; email: string; notes: string; tags: string[]; created_at: string }
export type CrmOrder = { id: string; crm_customer_id: string | null; user_id: string | null; receipt_code: string; total_price: number; currency: string; status: string; created_at: string }


export function CrmCustomerCard({ customer, customers, orders, storeId, token, onSaved, onClose }: {
  customer: CrmCustomer; customers: CrmCustomer[]; orders: CrmOrder[]; storeId: string; token: string
  onSaved: () => void; onClose: () => void
}) {
  const { t } = useTranslation()
  const [notes, setNotes] = useState(customer.notes)
  const [tags, setTags] = useState(customer.tags.join(', '))
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [targetId, setTargetId] = useState('')
  const own = orders.filter(order => order.crm_customer_id === customer.id)
  const duplicates = customers.filter(item => item.id !== customer.id && customerPhone(customer.phone).length >= 9 && customerPhone(item.phone) === customerPhone(customer.phone))
  const totals = new Map<string, number>()
  for (const order of own.filter(order => !order.status.startsWith('CANCELLED'))) totals.set(order.currency, (totals.get(order.currency) ?? 0) + Number(order.total_price))
  return <section className="crm-panel">
    <div className="product-editor__head"><h2>{customer.name}</h2></div>
    <p>{customer.phone} · {customer.email}</p>
    <p>{own.length} {t('orders')} · {[...totals].map(([currency, amount]) => formatPrice(amount / 100, currency)).join(' · ')}</p>
    <CustomerAccountActions storeId={storeId} customerId={customer.id} token={token} onDeleted={onSaved} />
    {error && <p className="error" role="alert">{error}</p>}
    <form className="form" onSubmit={async event => {
      event.preventDefault()
      if (busy) return
      setBusy(true)
      setError('')
      try {
        await supabaseRequest(`/rest/v1/crm_customers?id=eq.${customer.id}`, {
          method: 'PATCH', token, body: JSON.stringify({ notes, tags: [...new Set(tags.split(',').map(tag => tag.trim()).filter(Boolean))] }),
        })
        onSaved()
      } catch (cause) { setError(cause instanceof Error ? cause.message : t('Action failed')) } finally { setBusy(false) }
    }}>
      <label className="field">{t('Tags separated by commas')}<input value={tags} onChange={event => setTags(event.target.value)} maxLength={2000} /></label>
      <label className="field">{t('Private notes')}<textarea rows={5} maxLength={10000} value={notes} onChange={event => setNotes(event.target.value)} /></label>
      <button className="btn" disabled={busy}>{t('Save')}</button>
    </form>
    <details className="customer-section"><summary>{t('Merge customers')} {duplicates.length > 0 && `(${duplicates.length} ${t('matching phone')})`}</summary>
      <p>{t('Orders, notes and tags will move to the selected customer. Account access stays separate.')}</p>
      <label className="field">{t('Keep customer')}<select value={targetId} onChange={event => setTargetId(event.target.value)}>
        <option value="">{t('Select customer')}</option>
        {[...duplicates, ...customers.filter(item => item.id !== customer.id && !duplicates.includes(item))].map(item => <option key={item.id} value={item.id}>{item.name} · {item.phone || item.email}</option>)}
      </select></label>
      <button className="btn" disabled={!targetId || busy} onClick={async () => {
        const target = customers.find(item => item.id === targetId)
        if (!target || !window.confirm(t('Merge {{source}} into {{target}}?', { source: customer.name, target: target.name }))) return
        setBusy(true)
        try {
          await supabaseRequest('/rest/v1/rpc/merge_crm_customers', { method: 'POST', token, body: JSON.stringify({ p_source: customer.id, p_target: targetId }) })
          onSaved()
          onClose()
        } catch (cause) { setError(cause instanceof Error ? cause.message : t('Action failed')) } finally { setBusy(false) }
      }}>{t('Merge customers')}</button>
    </details>
    <h3>{t('Order history')}</h3><ul className="customers-list">{own.map(order => <li key={order.id}>
      <div><strong>#{order.receipt_code}</strong><span>{formatDate(order.created_at)} · {t(order.status)}</span></div>
      <strong>{formatPrice(Number(order.total_price) / 100, order.currency)}</strong>
    </li>)}</ul>
  </section>
}
