import { useStorefrontSettingsSave } from './StorefrontSettingsSave'
import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { contactsChanged, getStorefrontContacts, type StorefrontContacts } from '../lib/storefrontContacts'
import { supabaseRequest } from '../lib/supabase'

export function ContactSettings() {
  const { t } = useTranslation()
  const { store } = useStore()
  const { token } = useAuth()
  const [draft, setDraft] = useState<StorefrontContacts | null>(null)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [, setSaved] = useState(false)
  const storeId = store?.id

  useEffect(() => {
    if (!storeId) return
    let active = true
    void getStorefrontContacts(storeId).then(value => { if (active) setDraft(value) })
      .catch(() => { if (active) setError(t('Could not load contacts.')) })
    return () => { active = false }
  }, [storeId, t])

  const save = async () => {
    if (!storeId || !token || !draft || busy) throw new Error('Settings are not ready.')
    const email = draft.email.trim()
    const instagram_url = draft.instagram_url.trim()
    if (instagram_url && !/^https:\/\/(www\.)?instagram\.com\/[A-Za-z0-9._]+\/?$/i.test(instagram_url)) {
      setError(t('Enter a valid Instagram profile URL.'))
      throw new Error(t('Enter a valid Instagram profile URL.'))
    }
    setBusy(true)
    setError('')
    setSaved(false)
    try {
      await supabaseRequest('/rest/v1/storefront_contacts?on_conflict=store_id', {
        method: 'POST', token, headers: { Prefer: 'resolution=merge-duplicates' },
        body: JSON.stringify({ store_id: storeId, email, instagram_url }),
      })
      setDraft({ email, instagram_url })
      setSaved(true)
      window.dispatchEvent(new Event(contactsChanged))
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : t('Could not save contacts.'))
      throw cause
    } finally {
      setBusy(false)
    }
  }

  useStorefrontSettingsSave('ContactSettings.tsx', save)

  return <section className="settings-card">
    <header className="banner-settings__header"><h3>{t('Store contacts')}</h3></header>
    <p className="muted">{t('These contacts appear at the bottom of the store.')}</p>
    {error && <p className="error" role="alert">{error}</p>}
    {draft && <form onSubmit={event => event.preventDefault()}>
      <label className="field"><span>{t('Email')}</span><input type="email" maxLength={254} value={draft.email} onChange={event => { setDraft({ ...draft, email: event.target.value }); setSaved(false) }} /></label>
      <label className="field"><span>{t('Instagram profile URL')}</span><input type="url" maxLength={500} value={draft.instagram_url} onChange={event => { setDraft({ ...draft, instagram_url: event.target.value }); setSaved(false) }} /></label>

    </form>}
  </section>
}
