import { useEffect, useState } from 'react'
import { useTranslation } from 'react-i18next'
import type { BannerImage } from '../lib/banner'

export function BannerCarousel({ images }: { images: BannerImage[] }) {
  const { t } = useTranslation()
  const [position, setPosition] = useState(0)
  const [paused, setPaused] = useState(() => window.matchMedia('(prefers-reduced-motion: reduce)').matches)
  const total = images.length
  const current = position % total

  useEffect(() => {
    if (paused || total < 2) return
    const timer = window.setTimeout(() => setPosition((current + 1) % total), 5000)
    return () => window.clearTimeout(timer)
  }, [current, paused, total])

  const move = (step: number) => {
    setPaused(true)
    setPosition((current + step + total) % total)
  }

  return <div className="storefront-hero__image">
    <img src={images[current].url} alt="" />
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
