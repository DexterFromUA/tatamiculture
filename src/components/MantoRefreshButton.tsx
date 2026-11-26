import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useToast } from '../context/ToastContext'
import { refreshMantoSnapshot, type MantoSourceLink } from '../lib/mantoImport'
import { mantoProductLink } from '../../supabase/functions/crm-import-manto/product'

export function MantoRefreshButton({ storeId, productId, token, source, disabled }: {
  storeId: string
  productId: string
  token: string
  source: MantoSourceLink
  disabled?: boolean
}) {
  const { t } = useTranslation()
  const { addToast } = useToast()
  const [busy, setBusy] = useState(false)
  const pending = useRef<AbortController | null>(null)
  useEffect(() => () => pending.current?.abort(), [])

  const link = mantoProductLink(source.url)?.url
  if (!link) return null

  const refresh = async () => {
    if (pending.current || disabled) return
    const request = new AbortController()
    pending.current = request
    setBusy(true)
    try {
      await refreshMantoSnapshot(storeId, token, link.href, source.manto_product_id, request.signal, productId)
      addToast(t('Manto snapshot updated'))
    } catch (cause) {
      if (!request.signal.aborted) addToast(t(cause instanceof Error ? cause.message : 'Could not update Manto data.'))
    } finally {
      pending.current = null
      if (!request.signal.aborted) setBusy(false)
    }
  }

  return <button type="button" className="text-btn" disabled={disabled || busy} onClick={() => void refresh()}>
    {t(busy ? 'Updating…' : 'Refresh')}
  </button>
}
