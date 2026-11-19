import { CustomerDiscountEditor } from './CustomerDiscountEditor'
import { CustomerAdminAccess } from './CustomerAdminAccess'
import { CustomerAccountActions } from './CustomerAccountActions'
import { customerPhone } from '../lib/crm'
import { useState } from 'react'
import { useTranslation } from 'react-i18next'
import { supabaseRequest } from '../lib/supabase'
import { formatDate, formatPrice } from '../lib/format'

export type CrmCustomer = { id: string; name: string; phone: string; email: string; notes: string; tags: string[]; created_at: string }
export type CrmOrder = { id: string; crm_customer_id: string | null; user_id: string | null; receipt_code: string; total_price: number; currency: string; status: string; created_at: string }
export type CustomerCardOrder = CrmOrder & { delivery_city: string | null; delivery_address: string | null }


export function CrmCustomerCard({ customer, customers, orders, mergeMembers, storeId, token, onSaved, onClose, onViewOrders }: {
  customer: CrmCustomer; customers: CrmCustomer[]; orders: CustomerCardOrder[]; storeId: string; token: string
  mergeMembers: Array<{ order_id: string; root_id: string }>
  onSaved: () => void; onClose: () => void; onViewOrders: () => void
}) {
  const { t } = useTranslation()
  const [name, setName] = useState(customer.name)
  const [notes, setNotes] = useState(customer.notes)
  const [tags, setTags] = useState(customer.tags.join(', '))
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [savedMessage, setSavedMessage] = useState('')
  const [targetId, setTargetId] = useState('')
  const own = orders.filter(order => order.crm_customer_id === customer.id)
  const rootById = new Map(mergeMembers.map(member => [member.order_id, member.root_id]))
  const ownRoots = new Set(own.map(order => rootById.get(order.id) ?? order.id))
  const groupedOwn = orders.filter(order => ownRoots.has(order.id)).map(order => {
    const members = orders.filter(item => (rootById.get(item.id) ?? item.id) === order.id)
    return { ...order, total_price: members.reduce((sum, item) => sum + Number(item.total_price), 0) }
  })
  const lastDelivery = own.find(order => order.delivery_city?.trim() && order.delivery_address?.trim())
  const duplicates = customers.filter(item => item.id !== customer.id && customerPhone(customer.phone).length >= 9 && customerPhone(item.phone) === customerPhone(customer.phone))
  const totals = new Map<string, number>()
  for (const order of own.filter(order => !order.status.startsWith('CANCELLED'))) totals.set(order.currency, (totals.get(order.currency) ?? 0) + Number(order.total_price))
  const totalLabel = [...totals].map(([currency, amount]) => formatPrice(amount / 100, currency)).join(' · ') || '—'
  const initial = customer.name.trim().charAt(0).toLocaleUpperCase() || '?'
  return <section className="customer-profile">
    <div className="customer-profile__identity">
      <span className="customer-profile__avatar" aria-hidden="true">{initial}</span>
      <div className="customer-profile__identity-text">
        <h2>{customer.name}</h2>
        <span>{t('Customer since')} {formatDate(customer.created_at)}</span>
      </div>
    </div>
    <div className="customer-profile__stats">
      <div><span>{t('Orders')}</span><strong>{groupedOwn.length}</strong></div>
      <div><span>{t('Order value')}</span><strong>{totalLabel}</strong><small>{t('Excluding cancelled orders')}</small></div>
    </div>
    <section className="customer-profile__card customer-profile__contact">
      <h3>{t('Contact details')}</h3>
      <dl>
        <div><dt>{t('Phone')}</dt><dd>{customer.phone ? <a href={`tel:${customer.phone}`}>{customer.phone}</a> : '—'}</dd></div>
        {customer.email && <div><dt>{t('Email')}</dt><dd><a href={`mailto:${customer.email}`}>{customer.email}</a></dd></div>}
        {lastDelivery && <>
          <div><dt>{t('City')}</dt><dd>{lastDelivery.delivery_city}</dd></div>
          <div><dt>{t('Last delivery address')}</dt><dd>{lastDelivery.delivery_address}</dd></div>
        </>}
      </dl>
      <CustomerAccountActions storeId={storeId} customerId={customer.id} token={token} onDeleted={onSaved} />
    </section>
    <section className="customer-profile__card">
    <h3>{t('Customer details')}</h3>
    {error && <p className="error" role="alert">{error}</p>}
    <form className="form customer-profile__details-form" onSubmit={async event => {
      event.preventDefault()
      if (busy) return
      setSavedMessage('')
      const nextName = name.trim()
      if (!nextName) {
        setError(t('Enter a name between 1 and 100 characters.'))
        return
      }
      setBusy(true)
      setError('')
      try {
        await supabaseRequest('/rest/v1/rpc/update_crm_customer_details', {
          method: 'POST', token, body: JSON.stringify({
            p_store_id: storeId, p_customer_id: customer.id, p_name: nextName,
            p_notes: notes, p_tags: [...new Set(tags.split(',').map(tag => tag.trim()).filter(Boolean))],
          }),
        })
        setName(nextName)
        setSavedMessage(nextName !== customer.name ? 'Name updated' : 'Changes saved')
        onSaved()
      } catch (cause) { setError(cause instanceof Error ? cause.message : t('Action failed')) } finally { setBusy(false) }
    }}>
      <label className="field">{t('Name')}<input value={name} onChange={event => { setName(event.target.value); setSavedMessage('') }} maxLength={100} required disabled={busy} autoComplete="name" /></label>
      <label className="field">{t('Tags separated by commas')}<input value={tags} onChange={event => { setTags(event.target.value); setSavedMessage('') }} maxLength={2000} /></label>
      <label className="field">{t('Private notes')}<textarea rows={5} maxLength={10000} value={notes} onChange={event => { setNotes(event.target.value); setSavedMessage('') }} /></label>
      <div className="actions">
        <button className="btn" disabled={busy}>{t(busy ? 'Saving…' : 'Save')}</button>
        <span className="customer-save-status" role="status">{savedMessage && <><span aria-hidden="true">✓</span> {t(savedMessage)}</>}</span>
      </div>
    </form>
    </section>
    <section className="customer-profile__card customer-profile__orders">
      <div className="customer-profile__section-heading"><h3>{t('Order history')}</h3><span>{groupedOwn.length}</span></div>
      {groupedOwn.length ? <ul className="customer-profile__order-list">{groupedOwn.slice(0, 5).map(order => <li key={order.id}>
        <div><strong>#{order.receipt_code}</strong><span>{formatDate(order.created_at)} · {t(order.status)}</span></div>
        <strong>{formatPrice(Number(order.total_price) / 100, order.currency)}</strong>
      </li>)}</ul> : <p className="customer-profile__empty">{t('No orders yet.')}</p>}
      {groupedOwn.length > 0 && <button type="button" className="text-btn customer-profile__orders-link" onClick={onViewOrders}>
        {t('View all customer orders')} <span aria-hidden="true">↗</span>
      </button>}
    </section>
    <CustomerDiscountEditor key={customer.id} storeId={storeId} customerId={customer.id} token={token} onSaved={onSaved} />
    <CustomerAdminAccess key={customer.id} storeId={storeId} customerId={customer.id} token={token} onSaved={onSaved} />
    <details className="customer-profile__card customer-profile__merge"><summary>{t('Merge customers')} {duplicates.length > 0 && <span>{duplicates.length} {t('matching phone')}</span>}</summary>
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
  </section>
}
