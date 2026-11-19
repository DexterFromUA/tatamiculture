import { useCallback, useEffect, useRef, useState } from 'react'
import { api } from '../lib/api'
import type { CatalogFilters, CatalogMetadata, CatalogPage } from '../lib/storefrontCatalog'

const searchDelay = 250

export function useStorefrontCatalog(storeId: string | undefined, filters: CatalogFilters, revision: number, active: boolean) {
  const search = filters.search.trim()
  const parameters = JSON.stringify({ ...filters, search })
  const metadataKey = `${storeId}:${revision}`
  const key = `${metadataKey}:${parameters}`
  const [snapshot, setSnapshot] = useState<{ key: string; page: CatalogPage }>()
  const [metadata, setMetadata] = useState<{ key: string; value: CatalogMetadata }>()
  const [error, setError] = useState<{ key: string; kind: 'first' | 'more' }>()
  const [metadataErrorKey, setMetadataErrorKey] = useState<string>()
  const [attempt, setAttempt] = useState(0)
  const [loadingMore, setLoadingMore] = useState<AbortController | null>(null)
  const moreRequest = useRef<AbortController | null>(null)
  const previousSearch = useRef(search)
  const page = snapshot?.key === key ? snapshot.page : undefined
  const metadataReady = metadata?.key === metadataKey
  const firstPageReady = Boolean(page)

  useEffect(() => {
    if (!active || !storeId || metadataReady) return
    const abort = new AbortController()
    void api.getCatalogMetadata(storeId, abort.signal).then(value => {
      if (!abort.signal.aborted) setMetadata({ key: metadataKey, value })
    }).catch(() => {
      if (!abort.signal.aborted) setMetadataErrorKey(metadataKey)
    })
    return () => abort.abort()
  }, [active, storeId, metadataKey, metadataReady, attempt])

  useEffect(() => {
    if (!active || !storeId) return
    const changedSearch = search !== previousSearch.current
    previousSearch.current = search
    if (firstPageReady) return
    const abort = new AbortController()
    const load = () => {
      void api.getCatalogPage(storeId, JSON.parse(parameters) as CatalogFilters, null, abort.signal).then(result => {
        if (!abort.signal.aborted) {
          setSnapshot({ key, page: result })
          setError(current => current?.key === key ? undefined : current)
        }
      }).catch(() => {
        if (!abort.signal.aborted) setError({ key, kind: 'first' })
      })
    }
    const timer = changedSearch ? window.setTimeout(load, searchDelay) : undefined
    if (!changedSearch) load()
    return () => { window.clearTimeout(timer); abort.abort() }
  }, [active, storeId, key, parameters, search, firstPageReady, attempt])

  useEffect(() => () => {
    moreRequest.current?.abort()
    moreRequest.current = null
  }, [active, key])

  const loadMore = useCallback(() => {
    if (!active || !storeId || !page?.next_cursor || moreRequest.current) return
    const abort = new AbortController()
    moreRequest.current = abort
    setLoadingMore(abort)
    setError(current => current?.key === key ? undefined : current)
    void api.getCatalogPage(storeId, JSON.parse(parameters) as CatalogFilters, page.next_cursor, abort.signal).then(result => {
      if (abort.signal.aborted) return
      setSnapshot(current => {
        if (current?.key !== key) return current
        const loadedIds = new Set(current.page.rows.map(product => product.id))
        return { key, page: { ...result, rows: [...current.page.rows, ...result.rows.filter(product => !loadedIds.has(product.id))] } }
      })
    }).catch(() => {
      if (!abort.signal.aborted) setError({ key, kind: 'more' })
    }).finally(() => {
      if (moreRequest.current === abort) moreRequest.current = null
      setLoadingMore(current => current === abort ? null : current)
    })
  }, [active, storeId, page, key, parameters])

  const pageError = error?.key === key ? error.kind : undefined
  const metadataFailed = !metadataReady && metadataErrorKey === metadataKey
  const retry = () => {
    if (pageError === 'more') { loadMore(); return }
    setError(undefined)
    setMetadataErrorKey(undefined)
    setAttempt(value => value + 1)
  }

  return {
    page,
    metadata: metadataReady ? metadata?.value : undefined,
    loading: !page && pageError !== 'first',
    loadingMetadata: !metadataReady && !metadataFailed,
    loadingMore: Boolean(loadingMore),
    error: pageError ?? (metadataFailed ? 'metadata' : undefined),
    loadMore,
    retry,
  }
}
