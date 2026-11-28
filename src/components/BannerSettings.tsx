import { useStorefrontSettingsSave } from './StorefrontSettingsSave'
import { useEffect, useId, useState } from 'react'
import { useTranslation } from 'react-i18next'
import { useAuth } from '../context/AuthContext'
import { useStore } from '../context/StoreContext'
import { bannerImages, bannerTextVisible, defaultBannerTitle, type Banner, type BannerImage } from '../lib/banner'
import { LocalImagePreview } from './LocalImagePreview'
import { BannerLayoutSettings } from './BannerLayoutSettings'
import { ToggleSwitch } from './ToggleSwitch'
import { removeBannerImage, SupabaseError, supabaseRequest, uploadBannerImage } from '../lib/supabase'

const empty = (id: string): Banner => ({
  store_id: id, enabled: true, show_text: true, show_full_media: true, custom_size_enabled: false, image_url: '', image_path: '', images: [],
  kicker_uk: '', kicker_en: '', title_uk: '', title_en: '', description_uk: '', description_en: '',
})

const textFields = [
  { key: 'kicker', label: 'Banner eyebrow', maxLength: 80 },
  { key: 'title', label: 'Banner heading', maxLength: 80 },
  { key: 'description', label: 'Banner description', maxLength: 240 },
] as const

const textSwitches = [
  { device: 'desktop', label: 'Show banner text on desktop' },
  { device: 'mobile', label: 'Show banner text on mobile' },
] as const

export function BannerSettings() {
  const { store } = useStore()
  const { token } = useAuth()
  const { t } = useTranslation()
  const headingId = useId()
  const imageHintId = useId()
  const [banner, setBanner] = useState<Banner | null>(null)
  const [files, setFiles] = useState<File[]>([])
  const [removedUrls, setRemovedUrls] = useState<string[]>([])
  const [busy, setBusy] = useState(false)
  const [error, setError] = useState('')
  const [, setSaved] = useState(false)
  const existingImages = bannerImages(banner)
  const keptImages = existingImages.filter(image => !removedUrls.includes(image.url))
  const showText = bannerTextVisible(banner, 'desktop') || bannerTextVisible(banner, 'mobile')
  useEffect(() => {
    if (!store || !token) return
    let cancelled = false
    void supabaseRequest<Banner[]>(`/rest/v1/storefront_banners?store_id=eq.${encodeURIComponent(store.id)}&select=*`, { token }).then(rows => { if (!cancelled) setBanner(rows[0] ?? empty(store.id)) }).catch(cause => { if (!cancelled) setError(cause instanceof Error ? cause.message : 'Could not load banner') })
    return () => { cancelled = true }
  }, [store, token])
  const save = async () => {
    if (!banner || !token || busy) throw new Error('Settings are not ready.')
    setBusy(true); setError(''); setSaved(false)
    const uploaded: BannerImage[] = []
    let savingRecord = false
    try {
      for (const file of files) {
        const image = await uploadBannerImage(banner.store_id, file, token)
        uploaded.push({ url: image.publicUrl, path: image.path, type: file.type.startsWith('video/') ? 'video' : 'image' })
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
      throw cause
    } finally { setBusy(false) }
  }
  useStorefrontSettingsSave('BannerSettings.tsx', save)

  return <section className="settings-card banner-settings" aria-labelledby={headingId}>
    <header className="banner-settings__header"><h3 id={headingId}>{t('Homepage banner')}</h3></header>
    {error && <p className="error" role="alert">{t(error)}</p>}
    {banner && store && <>
      <label className="switch-field banner-settings__visibility">
        <ToggleSwitch checked={banner.enabled} disabled={busy} onChange={event => {
          setBanner({ ...banner, enabled: event.target.checked })
          setSaved(false)
        }} />
        {t('Show banner on homepage')}
      </label>
      <div className="banner-settings__image">
        <label className="product-photo-upload">
          <input className="sr-only" type="file" multiple accept="image/jpeg,image/png,image/webp,video/mp4,video/webm,video/quicktime" disabled={busy}
            aria-describedby={imageHintId} onChange={event => {
              const picked = Array.from(event.target.files ?? [])
              if (picked.length) {
                setFiles(current => [...current, ...picked])
                setSaved(false)
              }
              event.target.value = ''
            }} />
          <span className="product-photo-upload__icon" aria-hidden="true">＋</span>
          <span className="product-photo-upload__copy">
            <strong>{t('Banner images and videos')}</strong>
            <small>{t('Images up to 5 MB · MP4, WebM or MOV up to 50 MB')}</small>
          </span>
          <span className="product-photo-upload__action" aria-hidden="true">{t('Choose files')}</span>
        </label>
        <p id={imageHintId} className="banner-settings__image-hint muted">{t('Without banner images, the banner shows new arrivals and products on sale.')}</p>
        {(keptImages.length > 0 || files.length > 0) && <ol className="banner-settings__slides">
          {keptImages.map(image => <li key={image.url}>
            {image.type === 'video' ? <video src={image.url} muted playsInline preload="metadata" /> : <img src={image.url} alt="" />}
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
      {textSwitches.map(({ device, label }) => <label key={device} className="switch-field banner-settings__visibility">
        <ToggleSwitch checked={bannerTextVisible(banner, device)} disabled={busy} onChange={event => {
          setBanner({ ...banner, [`show_${device}_text`]: event.target.checked })
          setSaved(false)
        }} />
        {t(label)}
      </label>)}
      {showText && <div className="banner-settings__languages">
        {(['uk', 'en'] as const).map(language => <fieldset className="banner-settings__language" key={language} disabled={busy}>
          <legend>{language === 'uk' ? t('Ukrainian') : t('English')}</legend>
          {textFields.map(field => {
            const key = `${field.key}_${language}` as const
            return <label className="field" key={key}>
              <span>{t(field.label)}</span>
              <input
                maxLength={field.maxLength}
                placeholder={field.key === 'title' ? defaultBannerTitle : undefined}
                value={banner[key]}
                onChange={event => {
                  setBanner({ ...banner, [key]: event.target.value })
                  setSaved(false)
                }}
              />
            </label>
          })}
        </fieldset>)}
      </div>}

      <label className="switch-field banner-settings__visibility">
        <ToggleSwitch checked={banner.custom_size_enabled === true} disabled={busy} onChange={event => {
          const enabled = event.target.checked
          setBanner(current => current && { ...current, custom_size_enabled: enabled })
          setSaved(false)
        }} />
        {t('Advanced banner settings')}
      </label>
      {banner.custom_size_enabled && <BannerLayoutSettings banner={banner} storeName={store.name} images={keptImages} files={files} busy={busy}
        onChange={layout => {
          setBanner(current => current && { ...current, ...layout })
          setSaved(false)
        }} />}

    </>}
  </section>
}
