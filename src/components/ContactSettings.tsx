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
  const [saved, setSaved] = useState(false)
  const storeId = store?.id

  useEffect(() => {
    if (!storeId) return
    let active = true
    void getStorefrontContacts(storeId).then(value => { if (active) setDraft(value) })
      .catch(() => { if (active) setError(t('Could not load contacts.')) })
    return () => { active = false }
  }, [storeId, t])

  const save = async (event: React.FormEvent<HTMLFormElement>) => {
    event.preventDefault()
    if (!storeId || !token || !draft || busy) return
    const email = draft.email.trim()
    const instagram_url = draft.instagram_url.trim()
    if (instagram_url && !/^https:\/\/(www\.)?instagram\.com\/[A-Za-z0-9._]+\/?$/i.test(instagram_url)) {
      setError(t('Enter a valid Instagram profile URL.'))
      return
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
    } finally {
      setBusy(false)
    }
  }

  return <section className="settings-card contact-settings">
    <header className="banner-settings__header"><h2>{t('Store contacts')}</h2><p className="muted">{t('These contacts appear at the bottom of the store.')}</p></header>
    {error && <p className="error" role="alert">{error}</p>}
    {draft && <form className="form" onSubmit={event => void save(event)}>
      <label className="field"><span>{t('Email')}</span><input type="email" maxLength={254} value={draft.email} onChange={event => { setDraft({ ...draft, email: event.target.value }); setSaved(false) }} /></label>
      <label className="field"><span>{t('Instagram profile URL')}</span><input type="url" maxLength={500} placeholder="https://www.instagram.com/tatami.culture" value={draft.instagram_url} onChange={event => { setDraft({ ...draft, instagram_url: event.target.value }); setSaved(false) }} /></label>
      <div className="banner-settings__actions"><button className="btn" disabled={busy || !token}>{t(busy ? 'Saving…' : 'Save settings')}</button>{saved && <p className="success" role="status">{t('Saved')}</p>}</div>
    </form>}
  </section>
}
