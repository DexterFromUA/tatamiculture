import { useEffect, useRef, useState } from 'react'
import { crmPageSize, fetchCrmPage, type CrmPage, type CrmPageEndpoint } from '../lib/crm'

const searchDelay = 250

export function useCrmPage<T>(
  endpoint: CrmPageEndpoint, filters: Record<string, unknown> & { p_search?: string }, page: number, token: string | null, revision: number,
) {
  const body = JSON.stringify({ ...filters, p_page: page, p_page_size: crmPageSize })
  const search = filters.p_search ?? ''
  const previousSearch = useRef(search)
  const [attempt, setAttempt] = useState(0)
  const query = `${endpoint}:${body}`
  const key = `${revision}:${attempt}`
  const [result, setResult] = useState<{ query: string; key: string; token: string; data?: CrmPage<T>; error?: string }>()

  useEffect(() => {
    if (!token) return
    const searchChanged = previousSearch.current !== search
    previousSearch.current = search
    const abort = new AbortController()
    const load = () => {
      void fetchCrmPage<T>(endpoint, body, token, abort.signal).then(data => {
        if (!abort.signal.aborted) setResult({ query, key, token, data })
      }).catch(cause => {
        if (!abort.signal.aborted) setResult({ query, key, token, error: cause instanceof Error ? cause.message : 'Action failed' })
      })
    }
    const timer = searchChanged ? window.setTimeout(load, searchDelay) : undefined
    if (!searchChanged) load()
    return () => { window.clearTimeout(timer); abort.abort() }
  }, [endpoint, body, query, key, token, search])

  const samePage = result?.query === query && result.token === token ? result : undefined
  const current = samePage?.key === key ? samePage : undefined
  return {
    data: samePage?.data, error: current?.error, loading: Boolean(token && !current),
    retry: () => setAttempt(value => value + 1),
  }
}
