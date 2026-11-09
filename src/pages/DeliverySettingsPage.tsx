import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { supabaseRequest } from '../lib/supabase'
import { NovaPostModeToggle } from '../components/NovaPostModeToggle'

type Warehouse = { ref: string; name: string }
type City = Warehouse & { area: string }
type Settings = {
  store_id: string
  sender_name: string
  sender_phone: string
  city_ref: string
  city_name: string
  warehouse_ref: string
  warehouse_name: string
  length_cm: number
  width_cm: number
  height_cm: number
  delivery_payer: 'RECIPIENT' | 'SENDER'
}

const blank = (storeId: string): Settings => ({
  store_id: storeId,
  sender_name: '',
  sender_phone: '',
  city_ref: '',
  city_name: '',
  warehouse_ref: '',
  warehouse_name: '',
  length_cm: 20,
  width_cm: 20,
  height_cm: 10,
  delivery_payer: 'RECIPIENT',
})

export function DeliverySettingsPage({ embedded = false }: { embedded?: boolean }) {
  const { store } = useStore()
  const { token, user } = useAuth()
  const { t } = useTranslation()
  const [settings, setSettings] = useState<Settings | null>(null)
  const [cities, setCities] = useState<City[] | null>(null)
  const [warehouses, setWarehouses] = useState<Warehouse[] | null>(null)
  const [directoryError, setDirectoryError] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  const storeId = store?.id
  const userId = user?.id
  const cityName = settings?.city_name.trim() ?? ''
  const cityRef = settings?.city_ref
  const searchingCity = !cityRef && cityName.length >= 2

  useEffect(() => {
    if (!storeId || !token || !userId) return
    const controller = new AbortController()
    const fields = 'store_id,sender_name,sender_phone,city_ref,city_name,warehouse_ref,warehouse_name,length_cm,width_cm,height_cm,delivery_payer'
    void supabaseRequest<Settings[]>(`/rest/v1/delivery_settings?store_id=eq.${encodeURIComponent(storeId)}&select=${fields}`, {
      token, signal: controller.signal,
    }).then(rows => {
      if (!controller.signal.aborted) setSettings(rows[0] ?? blank(storeId))
    }).catch(cause => {
      if (!controller.signal.aborted) setError(cause instanceof Error ? cause.message : 'Could not load settings')
    })
    return () => controller.abort()
  }, [storeId, token, userId])

  useEffect(() => {
    if (!searchingCity) return
    const controller = new AbortController()
    const timer = window.setTimeout(() => {
      void supabaseRequest<City[]>('/functions/v1/nova-poshta-directory', {
        method: 'POST', body: JSON.stringify({ action: 'cities', query: cityName }), signal: controller.signal,
      }).then(results => {
        if (!controller.signal.aborted) setCities(results)
      }).catch(cause => {
        if (!controller.signal.aborted) setDirectoryError(cause instanceof Error ? cause.message : 'Could not load cities')
      })
    }, 300)
    return () => {
      window.clearTimeout(timer)
      controller.abort()
    }
  }, [cityName, searchingCity])

  useEffect(() => {
    if (!cityRef) return
    const controller = new AbortController()
    void supabaseRequest<Warehouse[]>('/functions/v1/nova-poshta-directory', {
      method: 'POST', body: JSON.stringify({ action: 'warehouses', cityRef }), signal: controller.signal,
    }).then(results => {
      if (!controller.signal.aborted) setWarehouses(results)
    }).catch(cause => {
      if (!controller.signal.aborted) setDirectoryError(cause instanceof Error ? cause.message : 'Could not load branches')
    })
    return () => controller.abort()
  }, [cityRef])

  if (!settings) {
    return error ? (
      <section className="page-status error">
        <h2>Settings are unavailable</h2>
        <p>{error}</p>
      </section>
    ) : <div className="page-status">{t('Loading…')}</div>
  }

  const update = (patch: Partial<Settings>) => {
    setSaved(false)
    setSettings(current => current ? { ...current, ...patch } : current)
  }

  const changeCity = (name: string, ref = '') => {
    if (cityRef || ref || name.trim() !== cityName) {
      setCities(null)
      setDirectoryError(null)
    }
    setWarehouses(null)
    update({ city_name: name, city_ref: ref, warehouse_name: '', warehouse_ref: '' })
  }

  const save = async () => {
    if (!token) return
    setError(null)
    try {
      // The delivery mode switch saves its own field separately.
      await supabaseRequest('/rest/v1/delivery_settings?on_conflict=store_id', {
        method: 'POST', token, headers: { Prefer: 'resolution=merge-duplicates' }, body: JSON.stringify(settings),
      })
      setSaved(true)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not save settings')
    }
  }

  const showSavedWarehouse = settings.warehouse_ref && !warehouses?.some(branch => branch.ref === settings.warehouse_ref)

  return (
    <section className="settings-page">
      {!embedded && <header className="page-head"><p className="eyebrow">{t('Shipping')}</p><h1>{t('Nova Poshta settings')}</h1></header>}
      {error && <p className="error" role="alert">{error}</p>}
      <section className="settings-card">
        <NovaPostModeToggle />
        <form onSubmit={event => { event.preventDefault(); void save() }}>
          <h2>{t('Sender')}</h2>
          <label className="field">
            <span>{t('Sender name or company')}</span>
            <input value={settings.sender_name} onChange={event => update({ sender_name: event.target.value })} />
          </label>
          <label className="field">
            <span>{t('Sender phone')}</span>
            <input value={settings.sender_phone} onChange={event => update({ sender_phone: event.target.value })} />
          </label>
          <div className="field">
            <label htmlFor="dispatch-city">{t('Dispatch city')}</label>
            <input id="dispatch-city" placeholder={t('Type city in Ukrainian')} value={settings.city_name} onChange={event => changeCity(event.target.value)} />
            {searchingCity && !directoryError && (cities?.length ? (
              <div className="city-results">
                {cities.map(city => (
                  <button type="button" key={city.ref} onClick={() => changeCity(city.name, city.ref)}>
                    <strong>{city.name}</strong>
                    {city.area && <small>{city.area}</small>}
                  </button>
                ))}
              </div>
            ) : <small role="status">{t(cities ? 'No cities found' : 'Loading…')}</small>)}
          </div>
          {cityRef && <label className="field">
            <span>{t('Dispatch branch')}</span>
            <select value={settings.warehouse_ref} disabled={!warehouses?.length} onChange={event => {
              const branch = warehouses?.find(item => item.ref === event.target.value)
              update({ warehouse_ref: branch?.ref ?? '', warehouse_name: branch?.name ?? '' })
            }}>
              <option value="">{t(directoryError ? 'Choose branch' : !warehouses ? 'Loading branches…' : warehouses.length ? 'Choose branch' : 'No branches found')}</option>
              {showSavedWarehouse && <option value={settings.warehouse_ref}>{settings.warehouse_name}</option>}
              {warehouses?.map(branch => <option key={branch.ref} value={branch.ref}>{branch.name}</option>)}
            </select>
          </label>}
          {directoryError && <p className="error" role="alert">{directoryError}</p>}
          <fieldset className="parcel-dimensions">
            <legend>{t('Parcel dimensions')}</legend>
            {([
              ['length_cm', 'Length, cm'],
              ['width_cm', 'Width, cm'],
              ['height_cm', 'Height, cm'],
            ] as const).map(([field, label]) => (
              <label className="field" key={field}>
                <span>{t(label)}</span>
                <input type="number" required min="1" max="2147483647" step="1" value={settings[field] || ''}
                  onChange={event => update({ [field]: Number(event.target.value) })} />
              </label>
            ))}
          </fieldset>
          <p className="muted">{t('The declared value is set automatically from the order total when the TTN is created.')}</p>
          <button type="submit" className="btn">{t('Save settings')}</button>
          {saved && <p className="success" role="status">{t('Saved')}</p>}
        </form>
      </section>
    </section>
  )
}
