import { useEffect, useRef, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { removeBannerImage, supabaseRequest, uploadBannerImage } from '../lib/supabase'

export type Banner = { store_id: string; image_url: string; image_path: string; kicker_uk: string; kicker_en: string; title_uk: string; title_en: string; description_uk: string; description_en: string }
const empty = (id: string): Banner => ({ store_id: id, image_url: '', image_path: '', kicker_uk: '', kicker_en: '', title_uk: '', title_en: '', description_uk: '', description_en: '' })

export function BannerSettings() {
  const { store } = useStore()
  const { token } = useAuth()
  const { t } = useTranslation()
  const [banner, setBanner] = useState<Banner | null>(null)
  const [file, setFile] = useState<File | null>(null)
  const [removeImage, setRemoveImage] = useState(false)
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [saved, setSaved] = useState(false)
  const fileInput = useRef<HTMLInputElement>(null)
  useEffect(() => {
    if (!store || !token) return
    let cancelled = false
    void supabaseRequest<Banner[]>(`/rest/v1/storefront_banners?store_id=eq.${encodeURIComponent(store.id)}&select=*`, { token }).then(rows => { if (!cancelled) setBanner(rows[0] ?? empty(store.id)) }).catch(cause => { if (!cancelled) setError(cause instanceof Error ? cause.message : t('Could not load banner')) })
    return () => { cancelled = true }
  }, [store, token, t])
  const save = async () => {
    if (!banner || !token || busy) return
    setBusy(true); setError(''); setSaved(false)
    let uploaded: { path: string; publicUrl: string } | null = null
    try {
      if (file) uploaded = await uploadBannerImage(banner.store_id, file, token)
      const next = { ...banner, image_url: uploaded?.publicUrl ?? (removeImage ? '' : banner.image_url), image_path: uploaded?.path ?? (removeImage ? '' : banner.image_path) }
      await supabaseRequest('/rest/v1/storefront_banners?on_conflict=store_id', { method: 'POST', token, headers: { Prefer: 'resolution=merge-duplicates' }, body: JSON.stringify(next) })
      setBanner(next); setFile(null); setRemoveImage(false); setSaved(true)
      if (fileInput.current) fileInput.current.value = ''
      if (banner.image_path && (uploaded || removeImage)) await removeBannerImage(banner.image_path, token).catch(() => {})
    } catch (cause) {
      if (uploaded) await removeBannerImage(uploaded.path, token).catch(() => {})
      setError(cause instanceof Error ? cause.message : t('Could not save banner'))
    } finally { setBusy(false) }
  }
  return <section className="settings-card banner-settings"><h2>{t('Homepage banner')}</h2><p className="muted">{t('Empty fields use the default text.')}</p>
    {error ? <p className="error">{error}</p> : null}
    {banner ? <>
      {banner.image_url && !removeImage ? <img className="banner-settings__preview" src={banner.image_url} alt="" /> : null}
      <label className="field"><span>{t('Banner image')}</span><input ref={fileInput} type="file" accept="image/jpeg,image/png,image/webp" onChange={event => { setFile(event.target.files?.[0] ?? null); setRemoveImage(false); setSaved(false) }} /><small>{t('JPG, PNG or WebP · up to 5 MB per file')}</small></label>
      {banner.image_url ? <label className="check"><input type="checkbox" checked={removeImage} onChange={event => { setRemoveImage(event.target.checked); setFile(null); if (fileInput.current) fileInput.current.value = '' }} /> {t('Remove banner image')}</label> : null}
      {(['uk', 'en'] as const).map(language => <fieldset className="banner-settings__language" key={language}><legend>{language === 'uk' ? t('Ukrainian') : t('English')}</legend>{(['kicker', 'title', 'description'] as const).map(field => { const key = `${field}_${language}` as keyof Banner; return <label className="field" key={key}><span>{t(field === 'kicker' ? 'Banner eyebrow' : field === 'title' ? 'Banner heading' : 'Banner description')}</span><input maxLength={field === 'description' ? 240 : 80} value={banner[key]} onChange={event => { setBanner({ ...banner, [key]: event.target.value }); setSaved(false) }} /></label> })}</fieldset>)}
      <button type="button" className="btn" disabled={busy} onClick={() => void save()}>{busy ? t('Saving…') : t('Save banner')}</button>{saved ? <p className="success">{t('Saved')}</p> : null}
    </> : null}
  </section>
}
