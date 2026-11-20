const cachePrefix = 'tatami-offline-'
const cacheName = cachePrefix + 'v1'
const offlinePage = '/offline.html'
const offlineIcon = '/apple-touch-icon.png'

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    const cache = await caches.open(cacheName)
    await cache.addAll([offlinePage, offlineIcon].map(path => new Request(path, { cache: 'reload' })))
    await self.skipWaiting()
  })())
})

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    const names = await caches.keys()
    await Promise.all(names
      .filter(name => name.startsWith(cachePrefix) && name !== cacheName)
      .map(name => caches.delete(name)))
    await self.clients.claim()
  })())
})

self.addEventListener('fetch', event => {
  const { request } = event
  const url = new URL(request.url)
  if (request.method !== 'GET' || url.origin !== self.location.origin) return

  if (request.mode === 'navigate') {
    event.respondWith(fetch(request).catch(async () => {
      const cache = await caches.open(cacheName)
      return (await cache.match(offlinePage)) ?? Response.error()
    }))
  } else if (url.pathname === offlineIcon) {
    event.respondWith(fetch(request).catch(async () => {
      const cache = await caches.open(cacheName)
      return (await cache.match(offlineIcon)) ?? Response.error()
    }))
  }
})
