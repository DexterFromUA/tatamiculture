import { StrictMode, useEffect } from 'react'
import { createRoot } from 'react-dom/client'
import { BrowserRouter } from 'react-router-dom'
import App from './App.tsx'
import { AuthProvider } from './context/AuthContext.tsx'
import { ToastProvider } from './context/ToastContext.tsx'
import { isStandalone } from './lib/pwa'
import { supabaseConfigured } from './lib/supabase'
import './i18n.ts'
import './index.css'

document.documentElement.dataset.theme = window.matchMedia('(prefers-color-scheme: dark)').matches ? 'dark' : 'light'

function AppRoot() {
  useEffect(() => {
    if (!supabaseConfigured) window.dispatchEvent(new Event('tatami-app-ready'))
  }, [])
  return <App />
}

createRoot(document.getElementById('root')!).render(
  <StrictMode>
    <BrowserRouter>
      <AuthProvider>
        <ToastProvider>
          <AppRoot />
        </ToastProvider>
      </AuthProvider>
    </BrowserRouter>
  </StrictMode>,
)

if (import.meta.env.PROD && isStandalone() && 'serviceWorker' in navigator) {
  void navigator.serviceWorker.register('/service-worker.js', { updateViaCache: 'none' }).catch(error => {
    console.warn('Could not prepare the offline page.', error)
  })
  const clearBadge = () => {
    if (document.visibilityState !== 'visible') return
    navigator.serviceWorker.controller?.postMessage({ type: 'clear-app-badge' })
    void navigator.clearAppBadge?.().catch(() => {})
  }
  document.addEventListener('visibilitychange', clearBadge)
  window.addEventListener('pageshow', clearBadge)
  navigator.serviceWorker.addEventListener('controllerchange', clearBadge)
  navigator.serviceWorker.addEventListener('message', event => {
    if (event.data?.type === 'push-received') clearBadge()
  })
  clearBadge()
}
