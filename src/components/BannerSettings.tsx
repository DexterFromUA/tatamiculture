import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { bannerImages, type Banner, type BannerImage } from '../lib/banner'
import { LocalImagePreview } from './LocalImagePreview'
import { removeBannerImage, SupabaseError, supabaseRequest, uploadBannerImage } from '../lib/supabase'

const empty = (id: string): Banner => ({
  store_id: id, enabled: true, image_url: '', image_path: '', images: [],
  kicker_uk: '', kicker_en: '', title_uk: '', title_en: '', description_uk: '', description_en: '',
})

const textFields = [
  { key: 'kicker', label: 'Banner eyebrow', maxLength: 80 },
  { key: 'title', label: 'Banner heading', maxLength: 80 },
  { key: 'description', label: 'Banner description', maxLength: 240 },
] as const

export function BannerSettings() {
  const { store } = useStore()
  const { token } = useAuth()
  const { t } = useTranslation()
  const [banner, setBanner] = useState<Banner | null>(null)
  const [files, setFiles] = useState<File[]>([])
  const [removedUrls, setRemovedUrls] = useState<string[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [saved, setSaved] = useState(false)
  const existingImages = bannerImages(banner)
  const keptImages = existingImages.filter(image => !removedUrls.includes(image.url))
  useEffect(() => {
    if (!store || !token) return
    let cancelled = false
    void supabaseRequest<Banner[]>(`/rest/v1/storefront_banners?store_id=eq.${encodeURIComponent(store.id)}&select=*`, { token }).then(rows => { if (!cancelled) setBanner(rows[0] ?? empty(store.id)) }).catch(cause => { if (!cancelled) setError(cause instanceof Error ? cause.message : 'Could not load banner') })
    return () => { cancelled = true }
  }, [store, token])
  const save = async () => {
    if (!banner || !token || busy) return
    setBusy(true); setError(''); setSaved(false)
    const uploaded: BannerImage[] = []
    let savingRecord = false
    try {
      for (const file of files) {
        const image = await uploadBannerImage(banner.store_id, file, token)
        uploaded.push({ url: image.publicUrl, path: image.path })
      }
      const images = [...keptImages, ...uploaded]
      const next = {
        ...banner, images,
        image_url: images[0]?.url ?? '',
        image_path: images[0]?.path ?? '',
      }
      savingRecord = true
      await supabaseRequest('/rest/v1/storefront_banners?on_conflict=store_id', {
        method: 'POST', token, headers: { Prefer: 'resolution=merge-duplicates' }, body: JSON.stringify(next),
      })
      setBanner(next)
      setFiles([])
      setRemovedUrls([])
      setSaved(true)
      await Promise.allSettled(existingImages
        .filter(image => removedUrls.includes(image.url) && image.path && !images.some(kept => kept.path === image.path))
        .map(image => removeBannerImage(image.path, token)))
    } catch (cause) {
      // A lost response may mean the banner was saved. Keep files it might now reference.
      if (!savingRecord || (cause instanceof SupabaseError && cause.status >= 400 && cause.status < 500)) {
        await Promise.allSettled(uploaded.map(image => removeBannerImage(image.path, token)))
      }
      setError(cause instanceof Error ? cause.message : t('Could not save banner'))
    } finally { setBusy(false) }
  }
  return <section className="settings-card banner-settings">
    <div className="banner-settings__header">
      <p className="eyebrow">01 / {t('Storefront')}</p>
      <h2>{t('Homepage banner')}</h2>
    </div>
    {error && <p className="error" role="alert">{t(error)}</p>}
    {banner && <>
      <label className="check banner-settings__visibility">
        <input type="checkbox" checked={banner.enabled} disabled={busy} onChange={event => {
          setBanner({ ...banner, enabled: event.target.checked })
          setSaved(false)
        }} />
        {t('Show banner on homepage')}
      </label>
      <div className="banner-settings__image">
        <label className="field">
          <span>{t('Banner images')}</span>
          <input type="file" multiple accept="image/jpeg,image/png,image/webp" disabled={busy} onChange={event => {
            const picked = Array.from(event.target.files ?? [])
            setFiles(current => [...current, ...picked])
            setSaved(false)
            event.target.value = ''
          }} />
          <small>{t('JPG, PNG or WebP · up to 5 MB per file')}</small>
        </label>
        {(keptImages.length > 0 || files.length > 0) && <ol className="banner-settings__slides">
          {keptImages.map(image => <li key={image.url}>
            <img src={image.url} alt="" />
            <button type="button" className="text-btn" disabled={busy} onClick={() => {
              setRemovedUrls(current => [...current, image.url])
              setSaved(false)
            }}>{t('Remove')}</button>
          </li>)}
          {files.map((file, index) => <li key={`${file.name}-${index}`}>
            <LocalImagePreview file={file} />
            <button type="button" className="text-btn" disabled={busy} onClick={() => {
              setFiles(current => current.filter((_, i) => i !== index))
              setSaved(false)
            }}>{t('Remove')}</button>
          </li>)}
        </ol>}
      </div>
      <div className="banner-settings__languages">
        {(['uk', 'en'] as const).map(language => <fieldset className="banner-settings__language" key={language} disabled={busy}>
          <legend>{language === 'uk' ? t('Ukrainian') : t('English')}</legend>
          {textFields.map(field => {
            const key = `${field.key}_${language}` as const
            return <label className="field" key={key}>
              <span>{t(field.label)}</span>
              <input
                maxLength={field.maxLength}
                placeholder={field.key === 'title' ? t('Everyday movement', { lng: language }) : t('Hidden when empty')}
                value={banner[key]}
                onChange={event => {
                  setBanner({ ...banner, [key]: event.target.value })
                  setSaved(false)
                }}
              />
            </label>
          })}
        </fieldset>)}
      </div>
      <div className="banner-settings__actions">
        <button type="button" className="btn" disabled={busy} onClick={() => void save()}>{busy ? t('Saving…') : t('Save banner')}</button>
        {saved && <p className="success" role="status">{t('Saved')}</p>}
      </div>
    </>}
  </section>
}
