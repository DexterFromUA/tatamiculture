import { useLocation } from 'react-router-dom'
import { useEffect, useState } from 'react'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { supabaseRequest } from '../lib/supabase'

export type PersonalDiscount = { percent: number; active: boolean; pending: boolean; mode: string; used: number; order_limit: number | null }

export function useCustomerDiscount() {
  const { store } = useStore()
  const { pathname } = useLocation()
  const { token, user } = useAuth()
  const storeId = store?.id
  const userId = user?.id
  const [result, setResult] = useState<{ storeId: string; userId: string; discount: PersonalDiscount | null }>()
  const [error, setError] = useState('')
  const [revision, setRevision] = useState(0)
  useEffect(() => {
    if (!storeId || !token || !userId) return
    const abort = new AbortController()
    const load = () => {
      void supabaseRequest<PersonalDiscount | null>('/functions/v1/customer-discount', {
        method: 'POST', token, signal: abort.signal, body: JSON.stringify({ storeId }),
      }).then(discount => {
        if (!abort.signal.aborted) { setResult({ storeId, userId, discount }); setError('') }
      }).catch(() => { if (!abort.signal.aborted) setError('Could not load your discount. Try again.') })
    }
    load()
    window.addEventListener('focus', load)
    const timer = window.setInterval(load, 60000)
    return () => { abort.abort(); window.removeEventListener('focus', load); window.clearInterval(timer) }
  }, [storeId, token, userId, revision, pathname])
  const current = result?.storeId === storeId && result?.userId === userId
  const discount = current ? result?.discount : null
  return {
    percent: Number(discount?.active ? discount.percent : 0),
    loading: Boolean(token && userId && !current && !error),
    error: token && userId ? error || (discount?.pending ? 'A discounted payment is still pending. Complete it or wait for its status to update.' : '') : '',
    retry: () => { setError(''); setRevision(value => value + 1) },
  }
}

export function personalUnitPrice(price: number, percent: number) {
  return Math.floor((Math.round(price * 100) * (10000 - Math.round(percent * 100)) + 5000) / 10000) / 100
}
