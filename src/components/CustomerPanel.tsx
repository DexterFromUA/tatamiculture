import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { supabaseRequest } from '../lib/supabase'
import { fetchAll } from '../lib/crm'
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

export function CustomerPanel({ order, storeId, token, onClose }: {
  order: CustomerOrder; storeId: string; token: string; managerId: string; onClose: () => void
}) {
  const { t } = useTranslation()
  const dialog = useRef<HTMLDialogElement>(null)
  const [customers, setCustomers] = useState<CrmCustomer[]>([])
  const [orders, setOrders] = useState<CrmOrder[]>([])
  const [customerId, setCustomerId] = useState('')
  const [loading, setLoading] = useState(true)
  const [revision, setRevision] = useState(0)
  const [error, setError] = useState('')
  useEffect(() => {
    const panel = dialog.current
    panel?.showModal()
    return () => panel?.close()
  }, [])
  useEffect(() => {
    const abort = new AbortController()
    Promise.all([
      supabaseRequest<Array<{ crm_customer_id: string | null }>>(`/rest/v1/orders?id=eq.${order.id}&select=crm_customer_id`, { token, signal: abort.signal }),
      fetchAll<CrmCustomer>(`/rest/v1/crm_customers?store_id=eq.${storeId}&select=*&order=created_at.desc,id`, token, abort.signal),
      fetchAll<CrmOrder>(`/rest/v1/orders?store_id=eq.${storeId}&select=id,crm_customer_id,user_id,receipt_code,total_price,currency,status,created_at&order=created_at.desc,id`, token, abort.signal),
    ]).then(([rows, people, purchases]) => {
      setCustomerId(rows[0]?.crm_customer_id ?? '')
      setCustomers(people)
      setOrders(purchases)
      setError('')
    }).catch(cause => { if (!abort.signal.aborted) setError(cause.message) })
      .finally(() => { if (!abort.signal.aborted) setLoading(false) })
    return () => abort.abort()
  }, [order.id, storeId, token, revision])
  const customer = customers.find(item => item.id === customerId)
  return <dialog ref={dialog} className="order-drawer customer-drawer" aria-labelledby="customer-drawer-title"
    onCancel={event => { event.preventDefault(); onClose() }}
    onClick={event => { if (event.target === event.currentTarget) onClose() }}>
    <header className="order-drawer__header">
      <div className="order-drawer__identity">
        <span className="order-drawer__eyebrow">CRM / {t('Customers')}</span>
        <h2 id="customer-drawer-title">{t('Customer')}</h2>
      </div>
      <button type="button" className="btn btn--ghost" onClick={onClose}>{t('Close')}</button>
    </header>
    <div className="order-drawer__body">
      {error && <p className="error" role="alert">{error}</p>}
      {loading ? <p>{t('Loading…')}</p> : customer ? <CrmCustomerCard key={customer.id} embedded customer={customer} customers={customers} orders={orders} token={token} onSaved={() => setRevision(value => value + 1)} onClose={onClose} /> : !error && <p>{t('Customer not found')}</p>}
    </div>
  </dialog>
}
