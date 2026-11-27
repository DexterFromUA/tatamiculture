import { createContext, useContext, useEffect, useRef, useState, type ReactNode } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'

type SaveHandler = () => Promise<void>
type SaveRegistry = Map<string, SaveHandler>
const SaveContext = createContext<SaveRegistry | null>(null)

export function useStorefrontSettingsSave(name: string, save: SaveHandler) {
  const registry = useContext(SaveContext)
  const latest = useRef(save)
  latest.current = save
  useEffect(() => {
    if (!registry) return
    registry.set(name, () => latest.current())
    return () => { registry.delete(name) }
  }, [name, registry])
}

export function StorefrontSettingsSave({ children }: { children: ReactNode }) {
  const { t } = useTranslation()
  const { token } = useAuth()
  const registry = useRef<SaveRegistry>(new Map()).current
  const container = useRef<HTMLDivElement>(null)
  const pending = useRef(false)
  const [busy, setBusy] = useState(false)
  const [saved, setSaved] = useState(false)
  const [failed, setFailed] = useState(false)

  const saveAll = async () => {
    if (pending.current || !token) return
    for (const form of container.current?.querySelectorAll('form') ?? []) {
      if (!form.reportValidity()) return
    }
    pending.current = true
    setBusy(true)
    setSaved(false)
    setFailed(false)
    try {
      for (const save of registry.values()) await save()
      setSaved(true)
    } catch {
      setFailed(true)
    } finally {
      pending.current = false
      setBusy(false)
    }
  }

  return <SaveContext.Provider value={registry}>
    <div ref={container} className="settings-workspace__storefront" inert={busy}
      onChange={() => setSaved(false)}>
      {children}
    </div>
    <div className="banner-settings__actions">
      <button type="button" className="btn" disabled={busy || !token} onClick={() => void saveAll()}>
        {t(busy ? 'Saving…' : 'Save settings')}
      </button>
      {saved && <p className="success" role="status">{t('Saved')}</p>}
      {failed && <p className="error" role="alert">{t('Some settings could not be saved. Check the messages above and try again.')}</p>}
    </div>
  </SaveContext.Provider>
}
