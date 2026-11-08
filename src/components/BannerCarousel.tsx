import { useEffect, useState, type Ref } from 'react'
import { useTranslation } from 'react-i18next'
import { Link } from 'react-router-dom'
import type { BannerImage } from '../lib/banner'

export function BannerCarousel({ images, imageRef, ready, hideFirstImage }: {
  images: BannerImage[]
  imageRef: Ref<HTMLImageElement>
  ready: boolean
  hideFirstImage: boolean
}) {
  const { t } = useTranslation()
  const [position, setPosition] = useState(0)
  const [paused, setPaused] = useState(() => window.matchMedia('(prefers-reduced-motion: reduce)').matches)
  const total = images.length
  const current = position % total

  useEffect(() => {
    if (!ready || paused || total < 2) return
    const timer = window.setTimeout(() => setPosition((current + 1) % total), 5000)
    return () => window.clearTimeout(timer)
  }, [current, paused, ready, total])

  const move = (step: number) => {
    setPaused(true)
    setPosition((current + step + total) % total)
  }

  return <div className="storefront-hero__image">
    {images[current].productId ? <Link className="banner-carousel__product" to={`/product/${images[current].productId}`} aria-label={images[current].productName}>
      <img ref={imageRef} src={images[current].url} alt="" hidden={hideFirstImage && current === 0} fetchPriority={current === 0 ? 'high' : 'auto'} />
      <span className="banner-carousel__product-name">{images[current].productName} ↗</span>
    </Link> : <img ref={imageRef} src={images[current].url} alt="" hidden={hideFirstImage && current === 0} fetchPriority={current === 0 ? 'high' : 'auto'} />}
    {total > 1 && <div className="banner-carousel__controls" role="group" aria-label={t('Banner images')}>
      <button type="button" onClick={() => setPaused(!paused)} aria-label={t(paused ? 'Play slideshow' : 'Pause slideshow')}>
        <span aria-hidden="true">{paused ? '▶' : 'Ⅱ'}</span>
      </button>
      <button type="button" onClick={() => move(-1)} aria-label={t('Previous slide')}>‹</button>
      <span className="banner-carousel__position" aria-label={t('Slide {{current}} of {{total}}', { current: current + 1, total })}>{current + 1} / {total}</span>
      <button type="button" onClick={() => move(1)} aria-label={t('Next slide')}>›</button>
    </div>}
  </div>
}
