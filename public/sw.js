// Service worker: offline app shell, a media cache, and Web Push.

const SHELL = 'shell-v16'
const MEDIA = 'media-v1'
const MEDIA_MAX = 400
const SHELL_FILES = [
  '/',
  '/index.html',
  '/manifest.webmanifest',
  '/css/tokens.css',
  '/css/base.css',
  '/css/symbols.css',
  '/css/glass.css',
  '/css/list.css',
  '/css/thread.css',
  '/css/overlays.css',
  '/css/auth.css',
  '/css/call.css',
  '/css/draw.css',
  '/css/attachments.css',
  '/css/invite-code.css',
  '/css/duo-layout.css',
  '/css/photo-stack.css',
  '/css/columns.css',
  '/css/fold.css',
  '/js/boot.js',
  '/js/main.js',
  '/js/api.js',
  '/js/store.js',
  '/js/ui/dom.js',
  '/js/ui/symbols.js',
  '/js/ui/push.js',
  '/js/ui/dots.js',
  '/js/ui/format.js',
  '/js/ui/haptics.js',
  '/js/ui/viewport.js',
  '/js/ui/press.js',
  '/js/ui/spring.js',
  '/js/ui/strip.js',
  '/js/ui/appearance.js',
  '/js/ui/invite-code.js',
  '/js/ui/fold.js',
  '/js/ui/bars.js',
  '/js/views/overlay.js',
  '/js/views/avatar.js',
  '/js/views/chatList.js',
  '/js/views/bubbles.js',
  '/js/views/composer.js',
  '/js/views/attachments.js',
  '/js/views/photo-stack.js',
  '/js/views/viewer.js',
  '/js/views/thread.js',
  '/js/views/auth.js',
  '/js/views/sheets.js',
  '/js/views/sidebar.js',
  '/js/views/artifact.js',
  '/js/views/shell.js',
  '/js/views/call.js',
  '/js/views/draw.js',
  '/icons/icon.svg'
]

self.addEventListener('install', event => {
  event.waitUntil(caches.open(SHELL).then(c => c.addAll(SHELL_FILES)).then(() => self.skipWaiting()))
})

self.addEventListener('activate', event => {
  event.waitUntil((async () => {
    for (const key of await caches.keys()) if (![SHELL, MEDIA].includes(key)) await caches.delete(key)
    await self.clients.claim()
  })())
})

self.addEventListener('fetch', event => {
  const req = event.request
  if (req.method !== 'GET') return
  const url = new URL(req.url)
  if (url.origin !== location.origin) return

  // Photos and avatars never change for a given URL: cache first.
  if (/^\/api\/media\/(image|avatar)\//.test(url.pathname)) {
    event.respondWith(mediaFirst(req))
    return
  }
  if (url.pathname.startsWith('/api/') || url.pathname.startsWith('/auth/')) return

  // App shell: serve instantly from cache, refresh in the background.
  if (req.mode === 'navigate') {
    event.respondWith(fetch(req).then(res => {
      if (res.ok) caches.open(SHELL).then(c => c.put('/index.html', res.clone()))
      return res
    }).catch(() => caches.match('/index.html')))
    return
  }
  event.respondWith((async () => {
    const cached = await caches.match(req)
    const fresh = fetch(req).then(res => {
      if (res.ok) caches.open(SHELL).then(c => c.put(req, res.clone()))
      return res
    }).catch(() => cached)
    return cached || fresh
  })())
})

async function mediaFirst(req) {
  const cache = await caches.open(MEDIA)
  const hit = await cache.match(req)
  if (hit) return hit
  const res = await fetch(req)
  if (res.ok && res.status === 200) {
    await cache.put(req, res.clone())
    const keys = await cache.keys()
    for (const k of keys.slice(0, Math.max(0, keys.length - MEDIA_MAX))) await cache.delete(k)
  }
  return res
}

// Pushes are Declarative Web Push messages (src/push/webpush.js). Where the
// browser supports them it shows them itself and this never runs; elsewhere
// the same JSON arrives here and is shown the same way. Older messages
// ({ title, body, room }) still read.
self.addEventListener('push', event => {
  let data = {}
  try {
    data = event.data?.json() || {}
  } catch {
    data = { title: 'Cuven', body: event.data?.text() || '' }
  }
  const n = data.web_push === 8030 && data.notification ? data.notification : data
  const navigate = n.navigate || (data.room ? `/?chat=${encodeURIComponent(data.room)}` : '/')
  const badge = Number(n.app_badge ?? data.count)
  event.waitUntil((async () => {
    if (Number.isFinite(badge) && self.navigator.setAppBadge) {
      self.navigator.setAppBadge(badge).catch(() => {})
    }
    // iOS revokes subscriptions whose pushes don't show a notification, so
    // always show one; the server only pushes while no window is in front.
    await self.registration.showNotification(n.title || 'Cuven', {
      body: n.body || '',
      tag: n.tag || 'duo',
      renotify: true,
      silent: Boolean(n.silent),
      lang: n.lang,
      icon: '/icons/icon-192.png',
      badge: '/icons/icon-192.png',
      data: { navigate }
    })
  })())
})

self.addEventListener('notificationclick', event => {
  event.notification.close()
  const target = new URL(event.notification.data?.navigate || '/', self.location.origin)
  const room = target.searchParams.get('chat') || event.notification.data?.room || null
  event.waitUntil((async () => {
    const clients = await self.clients.matchAll({ type: 'window', includeUncontrolled: true })
    for (const c of clients) {
      if ('focus' in c) {
        await c.focus()
        if (room) c.postMessage({ t: 'open', room })
        return
      }
    }
    await self.clients.openWindow(target.href)
  })())
})
