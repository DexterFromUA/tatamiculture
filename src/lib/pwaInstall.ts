import { isStandalone, pwaLayoutPreview } from './pwa'

type InstallMode = 'native' | 'ios' | null
type InstallState = { mode: InstallMode; dismissed: boolean }
type NativeInstallPrompt = Event & { prompt: () => Promise<{ outcome: 'accepted' | 'dismissed' }> }

const dismissKey = 'tatami-install-offer-dismissed'
const appleMobile = /iPhone|iPad|iPod/.test(navigator.userAgent)
  || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1)

function readDismissed() {
  try { return localStorage.getItem(dismissKey) === '1' } catch { return false }
}

let deferredPrompt: NativeInstallPrompt | undefined
let installed = false
let dismissed = readDismissed()
const listeners = new Set<() => void>()

function installMode(): InstallMode {
  if (!window.isSecureContext || installed || isStandalone() || pwaLayoutPreview) return null
  if (deferredPrompt) return 'native'
  return appleMobile ? 'ios' : null
}

let state: InstallState = { mode: installMode(), dismissed }

function notify() {
  const mode = installMode()
  if (state.mode === mode && state.dismissed === dismissed) return
  state = { mode, dismissed }
  listeners.forEach(listener => listener())
}

export function subscribeToPwaInstall(listener: () => void) {
  listeners.add(listener)
  return () => { listeners.delete(listener) }
}

export function getPwaInstallState() {
  return state
}

export function dismissPwaInstallOffer() {
  dismissed = true
  try { localStorage.setItem(dismissKey, '1') } catch { /* Keep the decision for this page. */ }
  notify()
}

export async function promptPwaInstall() {
  const prompt = deferredPrompt
  if (!prompt || installMode() !== 'native') return
  deferredPrompt = undefined
  try {
    const { outcome } = await prompt.prompt()
    if (outcome === 'accepted') installed = true
    else dismissPwaInstallOffer()
  } finally {
    notify()
  }
}

// Listen before the storefront mounts. Chromium can signal eligibility during startup.
window.addEventListener('beforeinstallprompt', event => {
  if (!window.isSecureContext || installed || isStandalone() || pwaLayoutPreview) return
  event.preventDefault()
  deferredPrompt = event as NativeInstallPrompt
  notify()
})
window.addEventListener('appinstalled', () => {
  installed = true
  deferredPrompt = undefined
  notify()
})
window.matchMedia('(display-mode: standalone)').addEventListener('change', notify)
window.addEventListener('storage', event => {
  if (event.key !== dismissKey || event.newValue !== '1') return
  dismissed = true
  notify()
})
