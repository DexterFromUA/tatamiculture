import type { CSSProperties, ReactNode, Ref } from 'react'
import { bannerTextColor, bannerTextShare, bannerTextVisible, defaultBannerTitle, type Banner } from '../lib/banner'

export function StorefrontBanner({ banner, storeName, language, children, headerRef }: {
  banner?: Banner | null
  storeName: string
  language: 'uk' | 'en'
  children: ReactNode
  headerRef?: Ref<HTMLElement>
}) {
  const showDesktopText = bannerTextVisible(banner, 'desktop')
  const showMobileText = bannerTextVisible(banner, 'mobile')
  const kicker = banner?.[`kicker_${language}`]?.trim()
  const title = banner?.[`title_${language}`]?.trim()
  const description = banner?.[`description_${language}`]?.trim()
  const layout = banner?.custom_size_enabled ? banner : undefined
  const background = layout?.background_color
  const showFullMedia = layout !== undefined && layout.show_full_media !== false
  const desktopText = layout?.desktop_text_percent ?? bannerTextShare.default
  const mobileText = layout?.mobile_text_percent ?? bannerTextShare.default
  const mobileMedia = 100 - mobileText
  const style = {
    '--banner-desktop-width': layout?.desktop_width_percent == null ? undefined : `${layout.desktop_width_percent}%`,
    '--banner-mobile-width': layout?.mobile_width_percent == null ? undefined : `${layout.mobile_width_percent}%`,
    '--banner-desktop-height': layout?.desktop_height_px == null ? undefined : `${layout.desktop_height_px}px`,
    '--banner-mobile-height': layout?.mobile_height_px == null ? undefined : `${layout.mobile_height_px}px`,
    '--banner-desktop-text-width': `${desktopText}%`,
    '--banner-mobile-text-track': `${mobileText}fr`,
    '--banner-mobile-media-track': `${mobileMedia}fr`,
    '--banner-mobile-media-share': mobileMedia / 100,
    '--banner-background': background ?? undefined,
    '--banner-ink': background ? bannerTextColor(background) : undefined,
    '--banner-media-fit': showFullMedia ? 'contain' : 'cover',
    '--banner-slide-start-scale': showFullMedia ? .96 : 1.06,
  } as CSSProperties

  return <div className="storefront-banner">
    <header ref={headerRef} className="storefront-hero" style={style} data-desktop-text={showDesktopText} data-mobile-text={showMobileText}>
      {(showDesktopText || showMobileText) && <div className="storefront-hero__copy">
        {kicker && <span className="storefront-kicker">{kicker}</span>}
        <h1><span className="storefront-hero__brand">{storeName}</span><span lang={title ? undefined : 'en'}> / {title || defaultBannerTitle}</span></h1>
        {description && <p>{description}</p>}
      </div>}
      {children}
    </header>
  </div>
}
