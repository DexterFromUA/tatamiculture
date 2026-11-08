import { useEffect, useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { fetchAll } from '../lib/crm'
import { useDrawer } from '../lib/useDrawer'
import { CrmCustomerCard, type CrmCustomer, type CrmOrder } from './CrmCustomerCard'
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

export function CustomerPanel({ target, storeId, token, onSaved, onClose }: {
  target: CustomerPanelTarget
  storeId: string
  token: string
  onSaved: () => void
  onClose: () => void
}) {
  const { t } = useTranslation()
  const titleId = useId()
  const { ref: dialogRef, close: closeDrawer, onCancel, onClick } = useDrawer({ openOnMount: true, onClose })
  const [customers, setCustomers] = useState<CrmCustomer[]>([])
  const [orders, setOrders] = useState<CrmOrder[]>([])
  const [loading, setLoading] = useState(true)
  const [revision, setRevision] = useState(0)
  const [error, setError] = useState('')
  useEffect(() => {
    const abort = new AbortController()
    Promise.all([
      fetchAll<CrmCustomer>(`/rest/v1/crm_customers?store_id=eq.${storeId}&select=*&order=created_at.desc,id`, token, abort.signal),
      fetchAll<CrmOrder>(`/rest/v1/orders?store_id=eq.${storeId}&select=id,crm_customer_id,user_id,receipt_code,total_price,currency,status,created_at&order=created_at.desc,id`, token, abort.signal),
    ]).then(([people, purchases]) => {
      if (abort.signal.aborted) return
      setCustomers(people)
      setOrders(purchases)
      setError('')
    }).catch(cause => { if (!abort.signal.aborted) setError(cause.message) })
      .finally(() => { if (!abort.signal.aborted) setLoading(false) })
    return () => abort.abort()
  }, [storeId, token, revision])
  const customerId = target.kind === 'customer'
    ? target.id
    : orders.find(order => order.id === target.id)?.crm_customer_id
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
          storeId={storeId} token={token} onSaved={() => { setRevision(value => value + 1); onSaved() }} onClose={closeDrawer} />
      ) : !error && <p>{t('Customer not found')}</p>}
    </div>
  </dialog>
}
