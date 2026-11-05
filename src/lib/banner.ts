export type BannerImage = { url: string; path: string }

export type Banner = {
  store_id: string
  enabled: boolean
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

export function bannerImages(banner?: Banner | null): BannerImage[] {
  const images = banner?.images?.filter(image => typeof image?.url === 'string' && image.url) ?? []
  if (images.length) return images
  return banner?.image_url ? [{ url: banner.image_url, path: banner.image_path }] : []
}
