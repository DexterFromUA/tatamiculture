import { useEffect, useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { supabaseRequest } from '../lib/supabase'
import type { DispatchLocation } from '../lib/ttn'

type Warehouse = { ref: string; name: string }
type City = Warehouse & { area: string }

const directory = '/functions/v1/nova-poshta-directory'
const warehousePageSize = 100

export function TtnDispatchFields({ location, onChange, disabled }: {
  location: DispatchLocation
  onChange: (location: DispatchLocation) => void
  disabled: boolean
}) {
  const { t } = useTranslation()
  const cityId = useId()
  const [cities, setCities] = useState<City[] | null>(null)
  const [warehouses, setWarehouses] = useState<Warehouse[]>([])
  const [loadedPage, setLoadedPage] = useState(0)
  const [requestPage, setRequestPage] = useState({ number: 1 })
  const [hasMore, setHasMore] = useState(false)
  const [error, setError] = useState<string | null>(null)
  const cityQuery = location.cityName.trim()
  const cityRef = location.cityRef
  const searching = !cityRef && cityQuery.length >= 2

  useEffect(() => {
    if (!searching) return
    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      void supabaseRequest<City[]>(directory, {
        method: 'POST',
        body: JSON.stringify({ action: 'cities', query: cityQuery }),
        signal: AbortSignal.any([controller.signal, AbortSignal.timeout(10000)]),
      }).then(results => {
        if (!controller.signal.aborted) setCities(results)
      }).catch(cause => {
        if (!controller.signal.aborted) setError(cause instanceof Error ? cause.message : 'Could not load cities')
      })
    }, 300)
    return () => { window.clearTimeout(timer); controller.abort() }
  }, [cityQuery, searching])

  useEffect(() => {
    if (!cityRef) return
    const controller = new AbortController()
    void supabaseRequest<Warehouse[]>(directory, {
      method: 'POST',
      body: JSON.stringify({ action: 'warehouses', cityRef, page: requestPage.number }),
      signal: AbortSignal.any([controller.signal, AbortSignal.timeout(10000)]),
    }).then(results => {
      if (controller.signal.aborted) return
      setWarehouses(current => {
        const branches = new Map(current.map(branch => [branch.ref, branch]))
        for (const branch of results) branches.set(branch.ref, branch)
        return [...branches.values()]
      })
      setLoadedPage(requestPage.number)
      setHasMore(results.length === warehousePageSize)
    }).catch(cause => {
      if (!controller.signal.aborted) setError(cause instanceof Error ? cause.message : 'Could not load branches')
    })
    return () => controller.abort()
  }, [cityRef, requestPage])

  const changeCity = (cityName: string, ref = '') => {
    if (cityRef || ref || cityName.trim() !== cityQuery) {
      setCities(null)
      setError(null)
    }
    setWarehouses([])
    setLoadedPage(0)
    setHasMore(false)
    setRequestPage({ number: 1 })
    onChange({ cityName, cityRef: ref, warehouseRef: '', warehouseName: '' })
  }

  const loadingBranches = Boolean(cityRef && requestPage.number !== loadedPage && !error)
  const showSavedBranch = location.warehouseRef && !warehouses.some(branch => branch.ref === location.warehouseRef)

  return <>
    <div className="field">
      <label htmlFor={cityId}>{t('Dispatch city')}</label>
      <input id={cityId} required disabled={disabled} placeholder={t('Type city in Ukrainian')}
        value={location.cityName} onChange={event => changeCity(event.target.value)} />
      {searching && !error && (cities?.length ? (
        <div className="city-results">
          {cities.map(city => <button type="button" key={city.ref} disabled={disabled} onClick={() => changeCity(city.name, city.ref)}>
            <strong>{city.name}</strong>{city.area && <small>{city.area}</small>}
          </button>)}
        </div>
      ) : <small role="status">{t(cities ? 'No cities found' : 'Loading…')}</small>)}
    </div>
    <label className="field">
      <span>{t('Dispatch branch')}</span>
      <select required value={location.warehouseRef} disabled={disabled || !cityRef}
        onChange={event => {
          const branch = warehouses.find(item => item.ref === event.target.value)
          if (branch) onChange({ ...location, warehouseRef: branch.ref, warehouseName: branch.name })
          else if (!event.target.value) onChange({ ...location, warehouseRef: '', warehouseName: '' })
        }}>
        <option value="" disabled>{t(loadingBranches && !loadedPage ? 'Loading branches…' : cityRef && loadedPage && !warehouses.length ? 'No branches found' : 'Choose branch')}</option>
        {showSavedBranch && <option value={location.warehouseRef}>{location.warehouseName || location.warehouseRef}</option>}
        {warehouses.map(branch => <option key={branch.ref} value={branch.ref}>{branch.name}</option>)}
      </select>
    </label>
    {cityRef && (hasMore || error) && <button type="button" className="text-btn" disabled={disabled || loadingBranches}
      onClick={() => { setError(null); setRequestPage({ number: loadedPage + 1 }) }}>
      {t(error ? 'Try again' : loadingBranches ? 'Loading branches…' : 'Load more branches')}
    </button>}
    {error && <p className="error" role="alert">{t(error)}</p>}
  </>
}
