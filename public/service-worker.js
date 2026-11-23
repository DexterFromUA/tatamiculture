const cachePrefix = 'tatami-offline-'
const cacheName = cachePrefix + 'v2'
const offlinePage = '/offline.html'
const offlineIcon = '/apple-touch-icon.png'
const badgeCacheName = 'tatami-push-state'
let badgeQueue = Promise.resolve()

self.addEventListener('install', event => {
  event.waitUntil((async () => {
    const cache = await caches.open(cacheName)
    const response = await fetch(offlinePage, { cache: 'reload' })
    const html = await response.text()
    if (!response.ok || !html.includes('id="offline-title"')) throw new Error('Offline page is not available')
    await cache.put(offlinePage, new Response(html, { headers: { 'Content-Type': 'text/html; charset=utf-8' } }))
    await cache.add(new Request(offlineIcon, { cache: 'reload' })).catch(() => {})
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
    event.respondWith((async () => {
      const controller = new AbortController()
      const timeout = setTimeout(() => controller.abort(), 6500)
      try {
        const response = await fetch(request, { signal: controller.signal, cache: 'no-store' })
        if (response.status < 500) return response
      } catch {
        // The offline document is stored during installation.
      } finally {
        clearTimeout(timeout)
      }
      return (await caches.match(offlinePage, { cacheName })) ?? new Response(
        '<!doctype html><html lang="uk"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>tatami.culture</title><h1>Немає інтернет-з’єднання</h1><a href="">Спробувати ще раз</a></html>',
        { headers: { 'Content-Type': 'text/html; charset=utf-8' } },
      )
    })())
  } else if (url.pathname === offlineIcon) {
    event.respondWith((async () => {
      const cache = await caches.open(cacheName)
      const icon = await cache.match(offlineIcon)
      if (icon) return icon
      const response = await fetch(request)
      if (response.ok && response.headers.get('Content-Type')?.includes('image/png')) {
        await cache.put(offlineIcon, response.clone()).catch(() => {})
      }
      return response
    })())
  }
})

function updateBadge(id) {
  badgeQueue = badgeQueue.catch(() => {}).then(async () => {
    const cache = await caches.open(badgeCacheName)
    const key = '/__tatami-push-state'
    const response = await cache.match(key)
    const state = response ? await response.json() : { count: 0, seen: [] }
    if (id && state.seen.includes(id)) return
    const count = id ? state.count + 1 : 0
    const seen = id ? [...state.seen, id].slice(-100) : state.seen
    await cache.put(key, new Response(JSON.stringify({ count, seen })))
    if (count) await self.navigator.setAppBadge?.(count)
    else await self.navigator.clearAppBadge?.()
  })
  return badgeQueue.catch(() => {})
}

self.addEventListener('message', event => {
  if (event.data?.type === 'clear-app-badge') event.waitUntil(updateBadge())
})

self.addEventListener('push', event => {
  let data
  try { data = event.data?.json() } catch {}
  const id = typeof data?.id === 'string' ? data.id : undefined
  const title = typeof data?.title === 'string' ? data.title.trim() : ''
  const notificationTitle = title && (data?.manual === true || title.toLowerCase() !== 'tatami.culture') ? title : 'Нове сповіщення'
  event.waitUntil(Promise.all([
    self.registration.showNotification(notificationTitle, {
      body: typeof data?.message === 'string' ? data.message : typeof data?.body === 'string' ? data.body : '',
      icon: offlineIcon,
      tag: id,
      data: { path: data?.path },
    }),
    id ? updateBadge(id).then(async () => {
      for (const client of await self.clients.matchAll({ type: 'window' })) {
        if (client.visibilityState === 'visible') client.postMessage({ type: 'push-received' })
      }
    }) : Promise.resolve(),
  ]))
})

self.addEventListener('notificationclick', event => {
  event.notification.close()
  event.waitUntil((async () => {
    const path = event.notification.data?.path
    const allowedPath = typeof path === 'string' && (path === '/checkout'
      || /^\/account#order-[a-f\d]{8}(?:-[a-f\d]{4}){3}-[a-f\d]{12}$/i.test(path)
      || /^\/(receipt|product)\/[a-z\d_-]+$/i.test(path))
    const target = new URL(allowedPath ? path : '/account', self.location.origin)
    const windows = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
    const existing = windows.find(client => client.url === target.href) ?? windows[0]
    if (existing) {
      const client = await existing.navigate(target.href).catch(() => null)
      if (client) {
        await client.focus()
        await updateBadge()
        return
      }
    }
    if (await self.clients.openWindow(target.href)) await updateBadge()
  })())
})
