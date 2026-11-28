import { useEffect, useLayoutEffect, useRef, useState, type CSSProperties, type PointerEvent as ReactPointerEvent } from 'react'
import { useTranslation } from 'react-i18next'
import { api } from '../lib/api'
import { bannerIcon, bannerSizeLimits, bannerTextShare, bannerTextVisible, type Banner, type BannerDevice, type BannerImage, type BannerLayout } from '../lib/banner'
import { StorefrontBanner } from './StorefrontBanner'
import { ToggleSwitch } from './ToggleSwitch'

const viewports = { desktop: 1280, mobile: 390 }
const { minWidth, maxWidth, minHeight, maxHeight } = bannerSizeLimits

function readWindowSize() {
  return { width: document.documentElement.clientWidth, viewport: window.innerWidth }
}

function bounded(value: number, min: number, max: number) {
  return Math.round(Math.max(min, Math.min(max, value)))
}

export function BannerLayoutSettings({ banner, storeName, images, files, busy, onChange }: {
  banner: Banner
  storeName: string
  images: BannerImage[]
  files: File[]
  busy: boolean
  onChange: (layout: Partial<BannerLayout>) => void
}) {
  const { t, i18n } = useTranslation()
  const [windowSize, setWindowSize] = useState(readWindowSize)
  const currentDevice = windowSize.width <= 700 ? 'mobile' : 'desktop'
  const [device, setDevice] = useState<BannerDevice>(currentDevice)
  const [slide, setSlide] = useState(0)
  const [localSlides, setLocalSlides] = useState<BannerImage[]>([])
  const [fallbackSlides, setFallbackSlides] = useState<BannerImage[]>([])
  const [metrics, setMetrics] = useState({ scale: 0, height: 0, bannerHeight: 400 })
  const frame = useRef<HTMLDivElement>(null)
  const canvas = useRef<HTMLDivElement>(null)
  const hero = useRef<HTMLElement>(null)
  const drag = useRef<AbortController | null>(null)
  const viewportWidth = device === currentDevice ? windowSize.width : viewports[device]
  const typographyWidth = device === currentDevice ? windowSize.viewport : viewportWidth
  const widthKey = `${device}_width_percent` as const
  const heightKey = `${device}_height_px` as const
  const ratioKey = `${device}_text_percent` as const
  const width = banner[widthKey] ?? 100
  const height = banner[heightKey] ?? metrics.bannerHeight
  const textShare = banner[ratioKey] ?? bannerTextShare.default
  const needsFallback = images.length === 0 && files.length === 0
  const slides = needsFallback ? fallbackSlides : [...images, ...localSlides]
  const media = slides.length ? slides[slide % slides.length] : undefined

  useEffect(() => () => drag.current?.abort(), [device, busy])

  useEffect(() => {
    const observer = new ResizeObserver(() => {
      const next = readWindowSize()
      setWindowSize(previous => previous.width === next.width && previous.viewport === next.viewport ? previous : next)
    })
    observer.observe(document.documentElement)
    return () => observer.disconnect()
  }, [])

  useEffect(() => {
    const previews: BannerImage[] = files.map(file => ({
      url: URL.createObjectURL(file), path: '', type: file.type.startsWith('video/') ? 'video' : 'image',
    }))
    setLocalSlides(previews)
    return () => previews.forEach(preview => URL.revokeObjectURL(preview.url))
  }, [files])

  useEffect(() => {
    if (!needsFallback) return
    const request = new AbortController()
    void api.getCatalogMetadata(banner.store_id, request.signal).then(metadata => {
      if (!request.signal.aborted) setFallbackSlides(metadata.bannerProducts.map(product => ({ url: product.url, path: '' })))
    }).catch(() => { /* Use the store mark when the catalogue is unavailable. */ })
    return () => request.abort()
  }, [banner.store_id, needsFallback])

  useLayoutEffect(() => {
    const frameElement = frame.current
    const canvasElement = canvas.current
    const bannerElement = hero.current
    if (!frameElement || !canvasElement || !bannerElement) return
    const measure = () => {
      const scale = frameElement.clientWidth / viewportWidth
      const height = canvasElement.offsetHeight * scale
      const bannerHeight = bannerElement.offsetHeight
      setMetrics(current => current.scale === scale && current.height === height && current.bannerHeight === bannerHeight
        ? current : { scale, height, bannerHeight })
    }
    const observer = new ResizeObserver(measure)
    observer.observe(frameElement)
    observer.observe(canvasElement)
    observer.observe(bannerElement)
    measure()
    return () => observer.disconnect()
  }, [viewportWidth])

  const startResize = (event: ReactPointerEvent<HTMLButtonElement>) => {
    const available = hero.current?.parentElement?.clientWidth
    if (event.button !== 0 || !available || !metrics.scale) return
    event.preventDefault()
    const { clientX, clientY, pointerId } = event
    const { scale } = metrics
    drag.current?.abort()
    const request = new AbortController()
    drag.current = request
    const options = { signal: request.signal }
    window.addEventListener('pointermove', move => {
      if (move.pointerId !== pointerId) return
      const widthChange = (move.clientX - clientX) * 200 / (available * scale)
      const heightChange = (move.clientY - clientY) / scale
      onChange({
        [widthKey]: bounded(width + widthChange, minWidth, maxWidth),
        [heightKey]: bounded(height + heightChange, minHeight, maxHeight),
      })
    }, options)
    const stop = (end: PointerEvent) => {
      if (end.pointerId === pointerId) request.abort()
    }
    window.addEventListener('pointerup', stop, options)
    window.addEventListener('pointercancel', stop, options)
    window.addEventListener('blur', () => request.abort(), options)
  }

  return <fieldset className="banner-layout" disabled={busy}>
    <div className="banner-layout__toolbar">
      <div className="banner-layout__devices" role="group" aria-label={t('Preview screen')}>
        <button type="button" className="btn btn--ghost" aria-pressed={device === 'desktop'} onClick={() => setDevice('desktop')}>{t('Desktop')}</button>
        <button type="button" className="btn btn--ghost" aria-pressed={device === 'mobile'} onClick={() => setDevice('mobile')}>{t('Mobile')}</button>
      </div>
      <div className="banner-layout__color">
        <label>
          {t('Banner background')}
          <input type="color" value={banner.background_color ?? '#f1f1f1'} onChange={event => onChange({ background_color: event.target.value })} />
        </label>
        {banner.background_color && <button className="text-btn" type="button" onClick={() => onChange({ background_color: null })}>{t('Reset color')}</button>}
      </div>
    </div>

    <div className="banner-layout__sizes">
      <label className="field">
        <span>{t('Banner width')} · {width}%</span>
        <input type="range" min={minWidth} max={maxWidth} value={width} onChange={event => onChange({ [widthKey]: event.target.valueAsNumber })} />
      </label>
      <label className="field">
        <span>{t('Banner height')} · {height} px</span>
        <input type="range" min={minHeight} max={maxHeight} value={bounded(height, minHeight, maxHeight)} onChange={event => onChange({ [heightKey]: event.target.valueAsNumber })} />
      </label>
      {bannerTextVisible(banner, device) && <label className="field">
        <span>{t('Text {{text}}% · Media {{media}}%', { text: textShare, media: 100 - textShare })}</span>
        <input type="range" min={bannerTextShare.min} max={bannerTextShare.max} value={textShare}
          onChange={event => onChange({ [ratioKey]: event.target.valueAsNumber })} />
      </label>}
      <button className="text-btn" type="button" disabled={banner[widthKey] == null && banner[heightKey] == null && banner[ratioKey] == null}
        onClick={() => onChange({ [widthKey]: null, [heightKey]: null, [ratioKey]: null })}>{t('Reset size')}</button>
    </div>

    <label className="switch-field banner-layout__media-fit">
      <ToggleSwitch checked={banner.show_full_media !== false} onChange={event => onChange({ show_full_media: event.target.checked })} />
      {t('Show images and videos in full')}
    </label>
    <div className="banner-layout__frame" ref={frame} style={{ maxWidth: viewportWidth, height: metrics.height || 240 }}>
      <div className="banner-layout__canvas" ref={canvas} style={{
        width: viewportWidth, transform: `scale(${metrics.scale || 1})`,
        '--preview-scale': Math.max(metrics.scale, .1), '--banner-viewport': `${typographyWidth}px`,
      } as CSSProperties}>
        <div className="banner-layout__topbar">{storeName}</div>
        <div className="banner-layout__main">
          <StorefrontBanner banner={banner} storeName={storeName} language={i18n.resolvedLanguage === 'en' ? 'en' : 'uk'} headerRef={hero}>
            <div className={`storefront-hero__image${media ? '' : ' storefront-hero__image--site-icon'}`}>
              {media?.type === 'video'
                ? <video src={media.url} muted playsInline preload="metadata" />
                : <img src={media?.url ?? bannerIcon} alt="" />}
            </div>
            <button type="button" className="banner-layout__handle" aria-label={t('Resize banner')}
              onPointerDown={startResize}
              onKeyDown={event => {
                if (event.key === 'ArrowLeft' || event.key === 'ArrowRight') {
                  event.preventDefault()
                  onChange({ [widthKey]: bounded(width + (event.key === 'ArrowLeft' ? -1 : 1), minWidth, maxWidth) })
                }
                if (event.key === 'ArrowUp' || event.key === 'ArrowDown') {
                  event.preventDefault()
                  onChange({ [heightKey]: bounded(height + (event.key === 'ArrowUp' ? -10 : 10), minHeight, maxHeight) })
                }
              }}>
              <span aria-hidden="true">↘</span>
            </button>
          </StorefrontBanner>
        </div>
      </div>
    </div>

    {slides.length > 1 && <div className="banner-layout__slides">
      <button type="button" className="text-btn" aria-label={t('Previous slide')} onClick={() => setSlide((slide % slides.length + slides.length - 1) % slides.length)}>‹</button>
      <span>{slide % slides.length + 1} / {slides.length}</span>
      <button type="button" className="text-btn" aria-label={t('Next slide')} onClick={() => setSlide((slide + 1) % slides.length)}>›</button>
    </div>}
  </fieldset>
}
