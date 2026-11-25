import { useEffect } from 'react'
import { useNavigate } from 'react-router-dom'
import { useAuth } from '../context/AuthContext'
import { useCart } from '../context/CartContext'
import { pendingCodKey } from './orderRequestId'
import { supabaseRequest } from './supabase'

export function useCodReceiptRecovery(storeId?: string) {
  const { user, token, initializing } = useAuth()
  const { items, clear } = useCart()
  const navigate = useNavigate()
  const key = storeId && pendingCodKey(storeId, user?.id, items)
  useEffect(() => {
    if (!key || initializing) return
    const abort = new AbortController()
    const recover = async () => {
      const pending = localStorage.getItem(key)
      if (!pending) return
      const { id, fingerprintKey } = JSON.parse(pending)
      const receipt = await supabaseRequest<string | null>('/rest/v1/rpc/recover_cod_receipt', {
        method: 'POST', token, signal: abort.signal, body: JSON.stringify({ p_request_id: id }),
      })
      if (receipt && !abort.signal.aborted && localStorage.getItem(key) === pending) {
        localStorage.removeItem(key)
        localStorage.removeItem(fingerprintKey)
        clear()
        navigate('/receipt/' + encodeURIComponent(receipt), { replace: true, state: { orderPlaced: true } })
      }
    }
    const check = () => { void recover().catch(() => { /* Retry on reconnect or next visit. */ }) }
    check()
    window.addEventListener('online', check)
    window.addEventListener('tatami:cod-uncertain', check)
    return () => {
      abort.abort()
      window.removeEventListener('online', check)
      window.removeEventListener('tatami:cod-uncertain', check)
    }
  }, [key, initializing, token, navigate, clear])
}
