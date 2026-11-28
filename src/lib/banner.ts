export type BannerImage = { url: string; path: string; type?: 'image' | 'video'; productId?: string; productName?: string }

export const defaultBannerTitle = 'Defend yourself'
export const bannerIcon = '/tatami-mark-transparent.png'
export const bannerSizeLimits = { minWidth: 50, maxWidth: 100, minHeight: 140, maxHeight: 1600 }
export const bannerTextShare = { min: 20, max: 80, default: 50 }
export type BannerDevice = 'desktop' | 'mobile'
export type BannerLayout = {
  custom_size_enabled: boolean
  desktop_width_percent: number | null
  desktop_height_px: number | null
  mobile_width_percent: number | null
  mobile_height_px: number | null
  desktop_text_percent: number | null
  mobile_text_percent: number | null
  background_color: string | null
}

export type Banner = Partial<BannerLayout> & {
  store_id: string
  enabled: boolean
  show_text: boolean
  show_desktop_text?: boolean | null
  show_mobile_text?: boolean | null
  image_url: string
  image_path: string
  images?: BannerImage[]
  kicker_uk: string
  kicker_en: string
  title_uk: string
  title_en: string
  description_uk: string
  description_en: string
}

export function bannerTextVisible(banner: Banner | null | undefined, device: BannerDevice) {
  return banner?.[`show_${device}_text`] ?? (banner?.show_text !== false)
}

export function bannerTextColor(background: string) {
  const channels = [1, 3, 5].map(offset => {
    const channel = Number.parseInt(background.slice(offset, offset + 2), 16) / 255
    return channel <= .04045 ? channel / 12.92 : ((channel + .055) / 1.055) ** 2.4
  })
  const luminance = .2126 * channels[0] + .7152 * channels[1] + .0722 * channels[2]
  return luminance > .179 ? '#000' : '#fff'
}

export function bannerImages(banner?: Banner | null): BannerImage[] {
  const images = banner?.images?.filter(image => typeof image?.url === 'string' && image.url) ?? []
  if (images.length) return images
  return banner?.image_url ? [{ url: banner.image_url, path: banner.image_path }] : []
}
