import { useEffect, useState } from 'react'
import { Link, useLocation, useNavigate, useParams } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'
import { useCart } from '../context/CartContext'
import { useStore } from '../context/StoreContext'
import { formatDate, formatPrice } from '../lib/format'
import { api } from '../lib/api'
import { normalizePhone } from '../lib/phone'
import type { Order } from '../types'
import { useTranslation } from 'react-i18next'
import { OrderActivity } from '../components/OrderActivity'
import { NovaPoshtaTrackingLink } from '../components/NovaPoshtaTrackingLink'

const paymentProviderOrigins = new Set(['https://pay.monobank.ua', 'https://pay.mbnk.biz', 'https://www.liqpay.ua', 'https://liqpay.ua'])

function returnedFromPaymentProvider(referrer: string) {
  try {
    return paymentProviderOrigins.has(new URL(referrer).origin)
  } catch {
    return false
  }
}

export function ReceiptPage() {
  const { code } = useParams()
  const { store } = useStore()
  const { completeOnlineCheckout } = useCart()
  const { user, token, initializing, logout } = useAuth()
  const location = useLocation()
  const returningFromPayment = new URLSearchParams(location.search).get('payment') === 'return'
  const navigate = useNavigate()
  const returnError = (location.state as { claimError?: string } | null)?.claimError
  const [order, setOrder] = useState<Order | null>(null)
  const [loading, setLoading] = useState(true)
  const [claiming, setClaiming] = useState(false)
  const [claimError, setClaimError] = useState('')
  const { t } = useTranslation()

  useEffect(() => {
    if (!code) return
    let cancelled = false
    let timer: number | undefined
    let retries = returningFromPayment ? 15 : 0

    const load = async () => {
      try {
        const next = await api.getOrderByReceipt(code)
        if (cancelled) return
        setOrder(next)
        setLoading(false)
        if (next?.paymentMethod !== 'ONLINE' || next.paymentStatus !== 'PENDING') return
      } catch {
        if (cancelled) return
        if (!retries) setLoading(false)
      }
      if (retries > 0) {
        retries -= 1
        timer = window.setTimeout(() => void load(), 2000)
      }
    }

    void load()
    return () => {
      cancelled = true
      window.clearTimeout(timer)
    }
  }, [code, returningFromPayment])

  useEffect(() => {
    if (order && order.receiptCode === code?.trim().toLowerCase()) {
      completeOnlineCheckout(order, returningFromPayment && returnedFromPaymentProvider(document.referrer))
    }
  }, [order, code, completeOnlineCheckout, returningFromPayment])

  if (!store) return null
  if (loading) return <div className="page-status">{t('Looking up receipt…')}</div>

  if (!order) {
    return (
      <section className="page-status">
        <h1>{t('Receipt not found')}</h1>
        <Link to="/">{t('Back to shop')}</Link>
      </section>
    )
  }

  const guestOrder = order.userId === 'guest' && order.storeId === store.id
  const ownOrder = user?.id === order.userId
  const receiptPath = `/receipt/${encodeURIComponent(order.receiptCode)}`
  const orderPhone = normalizePhone(order.customerPhone)
  const wrongAccount = Boolean(user && orderPhone && normalizePhone(user.phone) !== orderPhone)
  const claimIntent = { from: receiptPath, receiptToClaim: order.receiptCode, orderPhone }
  const visibleClaimError = !claiming && (claimError || returnError)
  const claimOrder = async () => {
    if (!user || !token || !guestOrder || !orderPhone || wrongAccount || claiming) return
    setClaiming(true)
    setClaimError('')
    try {
      if (await api.claimGuestOrder(store.id, order.receiptCode, token)) {
        setOrder(current => current?.id === order.id ? { ...current, userId: user.id } : current)
      } else {
        setClaimError('This order could not be linked to this account.')
      }
    } catch {
      setClaimError('Could not save this order. Try again.')
    } finally {
      setClaiming(false)
    }
  }

  return (
    <section className="receipt-page">
      <header className="receipt-hero">
        <p className="eyebrow">{t('Receipt')} · {order.receiptCode}{order.paymentTestMode && ` · ${t('Test order')}`}</p>
        <h1>{t('Thank you, {{name}}', { name: order.customerName })}</h1>
        <p>{formatDate(order.createdAt)}</p>
      </header>
      <div className="receipt-layout"><div className="receipt-content">
      <section className="receipt-card"><div className="receipt-card__head"><div><p className="eyebrow">{t('Your order')}</p><h2>{t('Order items')}</h2></div><span className="receipt-count">{order.items.reduce((sum, item) => sum + item.quantity, 0)}</span></div>
      <ul className="receipt-items">
        {order.items.map((item) => (
          <li key={item.id}>
            <div>
              <strong>{item.productName}</strong>
              <p className="muted">
                {item.optionName} × {item.quantity}
                {item.isPreOrder ? ` · ${t('pre-order')}` : ''}
              </p>
            </div>
            <span>{formatPrice(item.lineTotal, order.currency)}</span>
          </li>
        ))}
      </ul>
      <div className="receipt-total"><span>{t('Total')}</span><strong>{formatPrice(order.totalPrice, order.currency)}</strong></div></section>
      <section className="receipt-card receipt-delivery">
        <p className="eyebrow">{t('Deliver to')}</p>
        <h2>{t('Delivery')}</h2>
        <p>{[order.deliveryCity, order.deliveryAddress].filter(Boolean).join(', ')}</p>
        {order.novaPoshtaTtn ? <>
          <p><strong>ТТН: {order.novaPoshtaTtn}</strong></p>
          <p className="muted">{order.novaPoshtaStatus || t('TTN created — status will appear after dispatch.')}</p>
          <NovaPoshtaTrackingLink className="receipt-link" ttn={order.novaPoshtaTtn}>{t('Track shipment')} ↗</NovaPoshtaTrackingLink>
        </> : <p className="muted">{t('TTN will be added after dispatch.')}</p>}
      </section>
      <OrderActivity key={`${order.receiptCode}:${order.status}`} receiptCode={order.receiptCode} currency={order.currency} />
      </div><aside className="receipt-card receipt-summary">
        <p className="eyebrow">{t('Receipt')} · {order.receiptCode}</p>
        <h2>{t('Order details')}</h2>
        <dl>
          <div><dt>{t('Order status')}</dt><dd>{t(order.status)}</dd></div>
          {order.paymentMethod && <div><dt>{t('Payment method')}</dt><dd>{t(order.paymentMethod === 'CASH_ON_DELIVERY' ? 'Payment on delivery' : 'Online payment')}</dd></div>}
        </dl>
        {!initializing && (guestOrder || ownOrder) && <div className="receipt-claim">
          {ownOrder ? (
            <Link to="/account" className="text-btn">{t('View in order history')} ↗</Link>
          ) : !orderPhone ? (
            <p className="muted">{t('This order cannot be saved because the checkout phone number is invalid.')}</p>
          ) : wrongAccount ? (
            <>
              <p className="muted">{t('Your account uses a different phone number from this order.')}</p>
              <button type="button" className="btn" onClick={() => {
                logout()
                navigate('/login', { state: claimIntent })
              }}>
                {t('Sign in with the order phone number')}
              </button>
            </>
          ) : (
            <>
              {!user && <p className="muted">{t('Use the phone number from this order.')}</p>}
              {visibleClaimError && <p className="error" role="alert">{t(visibleClaimError)}</p>}
              {user && token
                ? <button type="button" className="btn" disabled={claiming} onClick={() => void claimOrder()}>
                    {t(claiming ? 'Saving…' : 'Save order to account')}
                  </button>
                : <Link to="/login" state={claimIntent} className="btn">
                    {t('Save order to account')}
                  </Link>}
            </>
          )}
        </div>}
        {guestOrder || ownOrder
          ? <Link to="/" className="text-btn">{t('Continue shopping')} ↗</Link>
          : <Link to="/" className="btn">{t('Continue shopping')} ↗</Link>}
      </aside></div>
    </section>
  )
}
