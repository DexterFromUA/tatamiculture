import { useEffect, useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { SupabaseError, supabaseRequest } from '../lib/supabase'
import { ToggleSwitch } from '../components/ToggleSwitch'
import { SettingsSectionHeading } from '../components/SettingsSectionHeading'

type Warehouse = { ref: string; name: string }
type City = Warehouse & { area: string }
const defaultTrackingInterval = 120

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
  auto_update_order_status?: boolean
  nova_poshta_tracking_interval_minutes?: number | ''
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

export function DeliverySettingsPage({ heading }: { heading?: { number: string; title: string } }) {
  const { store } = useStore()
  const { token, user } = useAuth()
  const { t } = useTranslation()
  const automationDescriptionId = useId()
  const formId = useId()
  const [settings, setSettings] = useState<Settings | null>(null)
  const [cities, setCities] = useState<City[] | null>(null)
  const [warehouses, setWarehouses] = useState<Warehouse[] | null>(null)
  const [directoryError, setDirectoryError] = useState<string | null>(null)
  const [error, setError] = useState<string | null>(null)
  const [saved, setSaved] = useState(false)
  const [saving, setSaving] = useState(false)
  const storeId = store?.id
  const userId = user?.id
  const cityName = settings?.city_name.trim() ?? ''
  const cityRef = settings?.city_ref
  const searchingCity = !cityRef && cityName.length >= 2

  useEffect(() => {
    if (!storeId || !token || !userId) return
    const controller = new AbortController()
    const fields = 'store_id,sender_name,sender_phone,city_ref,city_name,warehouse_ref,warehouse_name,length_cm,width_cm,height_cm,delivery_payer'
    const load = (select: string) => supabaseRequest<Settings[]>(
      `/rest/v1/delivery_settings?store_id=eq.${encodeURIComponent(storeId)}&select=${select}`,
      { token, signal: controller.signal },
    )
    const automationFields = `${fields},auto_update_order_status`
    void load(`${automationFields},nova_poshta_tracking_interval_minutes`).then((rows): Settings =>
      rows[0] ?? { ...blank(storeId), auto_update_order_status: true, nova_poshta_tracking_interval_minutes: defaultTrackingInterval },
    ).catch(async cause => {
      if (!(cause instanceof SupabaseError && cause.code === '42703' && cause.message.includes('nova_poshta_tracking_interval_minutes'))) throw cause
      const rows = await load(automationFields)
      return rows[0] ?? { ...blank(storeId), auto_update_order_status: true }
    }).catch(async cause => {
      if (!(cause instanceof SupabaseError && cause.code === '42703' && cause.message.includes('auto_update_order_status'))) throw cause
      const rows = await load(fields)
      return rows[0] ?? blank(storeId)
    }).then(result => {
      if (!controller.signal.aborted) setSettings(result)
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

  const saveAction = <div className="settings-workspace__heading-actions">
    {saved && <p className="success" role="status">{t('Saved')}</p>}
    <button type="submit" form={formId} className="btn" disabled={saving || !settings || !token}>
      {t(saving ? 'Saving…' : 'Save')}
    </button>
  </div>
  const header = heading ? <SettingsSectionHeading {...heading} action={saveAction} /> : (
    <header className="page-head page-head--row">
      <div><p className="eyebrow">{t('Shipping')}</p><h1>{t('Nova Poshta settings')}</h1></div>
      {saveAction}
    </header>
  )

  if (!settings) {
    return <>{header}{error ? (
      <section className="page-status error">
        <h2>Settings are unavailable</h2>
        <p>{error}</p>
      </section>
    ) : <div className="page-status">{t('Loading…')}</div>}</>
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
    if (!token || saving) return
    setError(null)
    setSaved(false)
    setSaving(true)
    try {
      await supabaseRequest('/rest/v1/delivery_settings?on_conflict=store_id', {
        method: 'POST', token, headers: { Prefer: 'resolution=merge-duplicates' }, body: JSON.stringify(settings),
      })
      setSaved(true)
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : 'Could not save settings')
    } finally {
      setSaving(false)
    }
  }

  const showSavedWarehouse = settings.warehouse_ref && !warehouses?.some(branch => branch.ref === settings.warehouse_ref)

  return (
    <section className="settings-page">
      {header}
      {error && <p className="error" role="alert">{error}</p>}
      <section className="settings-card">
        <form id={formId} onSubmit={event => { event.preventDefault(); void save() }}>
          <div className="delivery-settings__automation">
            <label className="switch-field">
              <ToggleSwitch aria-describedby={automationDescriptionId}
                checked={settings.auto_update_order_status ?? true} disabled={saving || settings.auto_update_order_status === undefined}
                onChange={event => update({ auto_update_order_status: event.target.checked })} />
              {t('Update order status automatically')}
            </label>
            <small className="muted" id={automationDescriptionId}>{t(settings.auto_update_order_status === undefined
              ? 'This setting becomes available after the database update.'
              : 'Use Nova Poshta tracking to update order status. Parcel tracking continues when this setting is off.')}</small>
            <label className="field delivery-settings__interval">
              <span>{t('Parcel tracking interval, min')}</span>
              <input type="number" inputMode="numeric" required min="1" max="2147483647" step="1"
                value={settings.nova_poshta_tracking_interval_minutes ?? ''}
                disabled={saving || settings.nova_poshta_tracking_interval_minutes === undefined}
                onChange={event => update({
                  nova_poshta_tracking_interval_minutes: event.target.value === '' ? '' : event.target.valueAsNumber,
                })} />
              {settings.nova_poshta_tracking_interval_minutes === undefined && settings.auto_update_order_status !== undefined &&
                <small className="muted">{t('This setting becomes available after the database update.')}</small>}
            </label>
          </div>
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
        </form>
      </section>
    </section>
  )
}
