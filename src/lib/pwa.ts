export const pwaLayoutPreview = import.meta.env.DEV
  && new URLSearchParams(window.location.search).get('pwa-preview') === '1'

export function isStandalone() {
  return window.matchMedia('(display-mode: standalone)').matches
    || (navigator as Navigator & { standalone?: boolean }).standalone === true
}
