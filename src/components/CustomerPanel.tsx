import { useEffect, useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { fetchAll } from '../lib/crm'
import { useDrawer } from '../lib/useDrawer'
import { CrmCustomerCard, type CrmCustomer, type CustomerCardOrder } from './CrmCustomerCard'
import type { OrderStatus, PaymentStatus } from '../types'

export type CustomerOrder = {
  id: string
  user_id: string | null
  receipt_code: string
  customer_name: string
  customer_email: string
  customer_phone: string
  total_price: number
  currency: string
  status: OrderStatus
  payment_status: PaymentStatus
  created_at: string
}

export type CustomerPanelTarget = { kind: 'order' | 'customer'; id: string }
type OrderContact = CustomerCardOrder & Pick<CustomerOrder, 'customer_name' | 'customer_email' | 'customer_phone'>

export function CustomerPanel({ target, storeId, token, onSaved, onClose, onViewOrders }: {
  target: CustomerPanelTarget
  storeId: string
  token: string
  onSaved: () => void
  onClose: () => void
  onViewOrders: (customerId: string, name: string) => void
}) {
  const { t } = useTranslation()
  const titleId = useId()
  const { ref: dialogRef, close: closeDrawer, onCancel, onClick } = useDrawer({ openOnMount: true, onClose })
  const [customers, setCustomers] = useState<CrmCustomer[]>([])
  const [orders, setOrders] = useState<OrderContact[]>([])
  const [mergeMembers, setMergeMembers] = useState<Array<{ order_id: string; root_id: string }>>([])
  const [loading, setLoading] = useState(true)
  const [revision, setRevision] = useState(0)
  const [error, setError] = useState('')
  useEffect(() => {
    const abort = new AbortController()
    Promise.all([
      fetchAll<CrmCustomer>(`/rest/v1/crm_customers?store_id=eq.${storeId}&select=*&order=created_at.desc,id`, token, abort.signal),
      fetchAll<OrderContact>(`/rest/v1/orders?store_id=eq.${storeId}&select=id,crm_customer_id,user_id,receipt_code,total_price,currency,status,created_at,delivery_city,delivery_address,customer_name,customer_email,customer_phone&order=created_at.desc,id.desc`, token, abort.signal),
      fetchAll<{ order_id: string; root_id: string }>(`/rest/v1/order_merge_members?select=order_id,root_id,orders!order_merge_members_order_id_fkey!inner(store_id)&orders.store_id=eq.${storeId}&order=order_id`, token, abort.signal),
    ]).then(([people, purchases, members]) => {
      if (abort.signal.aborted) return
      setCustomers(people)
      setOrders(purchases)
      setMergeMembers(members)
      setError('')
    }).catch(cause => { if (!abort.signal.aborted) setError(cause.message) })
      .finally(() => { if (!abort.signal.aborted) setLoading(false) })
    return () => abort.abort()
  }, [storeId, token, revision])
  const order = target.kind === 'order' ? orders.find(order => order.id === target.id) : undefined
  const customerId = target.kind === 'customer' ? target.id : order?.crm_customer_id
  const customer = customers.find(item => item.id === customerId)
  return <dialog ref={dialogRef} className="order-drawer customer-drawer" aria-labelledby={titleId}
    onCancel={onCancel} onClick={onClick}>
    <header className="order-drawer__header">
      <div className="order-drawer__identity">
        <span className="order-drawer__eyebrow">CRM / {t('Customers')}</span>
        <h2 id={titleId}>{t('Customer')}</h2>
      </div>
      <button type="button" className="btn btn--ghost" onClick={() => closeDrawer()}>{t('Close')}</button>
    </header>
    <div className="order-drawer__body">
      {error && <p className="error" role="alert">{error}</p>}
      {loading ? <p>{t('Loading…')}</p> : customer ? (
        <CrmCustomerCard key={customer.id} customer={customer} customers={customers} orders={orders}
          mergeMembers={mergeMembers} storeId={storeId} token={token}
          onSaved={() => { setRevision(value => value + 1); onSaved() }} onClose={closeDrawer}
          onViewOrders={() => closeDrawer(() => onViewOrders(customer.id, customer.name))} />
      ) : order ? (
        <section className="customer-profile__card customer-profile__contact">
          <h3>{order.customer_name || t('Contact details')}</h3>
          <dl>
            <div><dt>{t('Phone')}</dt><dd>{order.customer_phone ? <a href={`tel:${order.customer_phone}`}>{order.customer_phone}</a> : '—'}</dd></div>
            {order.customer_email && <div><dt>{t('Email')}</dt><dd><a href={`mailto:${order.customer_email}`}>{order.customer_email}</a></dd></div>}
            {order.delivery_city && <div><dt>{t('City')}</dt><dd>{order.delivery_city}</dd></div>}
            {order.delivery_address && <div><dt>{t('Last delivery address')}</dt><dd>{order.delivery_address}</dd></div>}
          </dl>
        </section>
      ) : !error && <p>{t('Customer not found')}</p>}
    </div>
  </dialog>
}
