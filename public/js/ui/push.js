// Web Push subscription. Where the browser has Declarative Web Push
// (window.pushManager: Safari 18.4 and later, Home Screen apps on iOS) the
// subscription belongs to the page, not the service worker, and the server's
// web_push 8030 messages are shown by the system even when the app was
// closed long ago. Elsewhere it goes through the service worker as before.

import { api } from '../api.js'

const declarative = () => 'pushManager' in window
const swManager = () => ('serviceWorker' in navigator && 'PushManager' in window
  // ready never settles without a service worker; don't wait on it forever.
  ? Promise.race([navigator.serviceWorker.ready.then(r => r.pushManager), new Promise(r => setTimeout(() => r(null), 4000))])
  : Promise.resolve(null))
const manager = () => (declarative() ? Promise.resolve(window.pushManager) : swManager())

export const pushSupported = () => 'Notification' in window && (declarative() || ('serviceWorker' in navigator && 'PushManager' in window))

export async function currentSubscription() {
  try { return await (await manager())?.getSubscription() || null } catch { return null }
}

/** Asks for permission (call from a tap), subscribes and registers with the server. */
export async function enablePush(vapid) {
  if (await Notification.requestPermission() !== 'granted') throw new Error('没有获得通知权限')
  const pm = await manager()
  if (!pm) throw new Error('此设备不支持网页推送')
  const sub = await keptSubscription(pm, vapid) || await pm.subscribe({ userVisibleOnly: true, applicationServerKey: b64urlToBytes(vapid) })
  await api.post('/api/push/subscribe', { sub: sub.toJSON() })
  await retireWorkerSubscription(sub)
  return sub
}

export async function disablePush() {
  for (const pm of [await manager(), declarative() ? await swManager() : null]) {
    const sub = await pm?.getSubscription().catch(() => null)
    if (!sub) continue
    await api.post('/api/push/unsubscribe', { endpoint: sub.endpoint })
    await sub.unsubscribe()
  }
}

/**
 * On launch, with permission already granted: make sure this device is
 * subscribed the best way it can be and that the server has it (a renewed
 * endpoint, or one subscribed before Declarative Web Push, is replaced).
 */
export async function syncPush(vapid) {
  if (!vapid || !pushSupported() || Notification.permission !== 'granted') return
  try {
    const pm = await manager()
    if (!pm) return
    const had = await pm.getSubscription()
    let sub = await keptSubscription(pm, vapid)
    if (!sub && (had || (declarative() && await swManager().then(m => m?.getSubscription()).catch(() => null)))) {
      // Made for another server key, or through the service worker before:
      // subscribe again (permission is already granted, so nothing asks).
      sub = await pm.subscribe({ userVisibleOnly: true, applicationServerKey: b64urlToBytes(vapid) })
    }
    if (!sub) return
    await api.post('/api/push/subscribe', { sub: sub.toJSON() })
    await retireWorkerSubscription(sub)
  } catch {}
}

// A subscription made for a different server key (one set or changed since)
// would be refused by the push service: let it go so a fresh one is made.
async function keptSubscription(pm, vapid) {
  const sub = await pm.getSubscription()
  const key = sub?.options?.applicationServerKey
  if (!sub || !key) return sub
  const mine = new Uint8Array(key)
  const theirs = b64urlToBytes(vapid)
  if (mine.length === theirs.length && mine.every((v, i) => v === theirs[i])) return sub
  await api.post('/api/push/unsubscribe', { endpoint: sub.endpoint }).catch(() => {})
  await sub.unsubscribe().catch(() => {})
  return null
}

// With a page subscription in place, an older service-worker one would only
// deliver each notification twice.
async function retireWorkerSubscription(current) {
  if (!declarative()) return
  const old = await swManager().then(m => m?.getSubscription()).catch(() => null)
  if (!old || old.endpoint === current.endpoint) return
  await api.post('/api/push/unsubscribe', { endpoint: old.endpoint }).catch(() => {})
  await old.unsubscribe().catch(() => {})
}

function b64urlToBytes(s) {
  const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4))
  return Uint8Array.from(bin, c => c.charCodeAt(0))
}
