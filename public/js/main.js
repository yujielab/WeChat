// App entry: account gate → realtime messenger.

import { initViewport } from './ui/viewport.js'
import { initPress } from './ui/press.js'
import { syncThemeColor, startPerfProbe } from './ui/appearance.js'
import { api, connectSocket, onApiEvent } from './api.js'
import { storage, reducedMotion } from './ui/dom.js'
import {
  state, setMe, setPrefs, setRooms, upsertRoom, patchRoom, setContacts, setPresence, markPresence,
  normMsg, previewText, thread, upsertMessage, replaceMessage, removeMessage, chatInfo
} from './store.js'
import { renderAuth } from './views/auth.js'
import { createShell } from './views/shell.js'
import { createCalls } from './views/call.js'
import { syncPush } from './ui/push.js'
import { prewarmStickers } from './views/stickers.js'
import { toast, closeAllOverlays } from './views/overlay.js'

const app = document.getElementById('app')
let socket = null
let shell = null
let calls = null

initViewport()
initPress()
syncThemeColor()
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', syncThemeColor)

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/sw.js').catch(() => {})
  navigator.serviceWorker.addEventListener('message', e => {
    if (e.data?.t === 'open' && e.data.room && shell) shell.openChat(e.data.room)
  })
}

onApiEvent(evt => {
  if (evt !== 'unauthorized') return
  storage(BOOT_CACHE, null)
  location.reload()
})

// The last bootstrap, kept so a launch paints the app at once and catches
// up behind it instead of showing an empty screen for two round trips.
// Presence is left out: it is only true live.
const BOOT_CACHE = 'cache:boot'
function cachedBoot() {
  try {
    const b = JSON.parse(storage(BOOT_CACHE) || 'null')
    return b?.me?.id && Array.isArray(b.rooms) ? b : null
  } catch {
    return null
  }
}

boot()

async function boot() {
  const cached = shell ? null : cachedBoot()
  if (cached) {
    state.restored = true
    setMe(cached.me)
    applyBoot(cached)
    mountShell()
  }
  let status
  try {
    status = await fetch('/auth/status', { credentials: 'same-origin' }).then(r => r.json())
  } catch {
    if (shell) shell.setStatus({ text: '连接中…', spinner: true })
    else {
      app.replaceChildren()
      toast('无法连接服务器，请检查网络', { type: 'error', duration: 6000 })
    }
    setTimeout(boot, 4000)
    return
  }
  if (status.authed && (!state.me || state.me.id === status.me.id)) return start(status.me)
  // Signed out, or someone else signed in, since the cache was written.
  storage(BOOT_CACHE, null)
  if (shell) return location.reload()
  renderAuth(app, { needsCode: status.needsCode, onSuccess: start })
}

async function start(me) {
  setMe(me)
  try {
    await refresh()
  } catch (err) {
    // A restored app says it is still connecting; a blank one says why.
    if (shell) shell.setStatus({ text: '连接中…', spinner: true })
    else toast(err.message, { type: 'error' })
    return setTimeout(() => start(me), 3000)
  }
  socket?.close()
  socket = connectSocket({
    onMessage: handle,
    onOpen: () => { state.socket = true; shell?.setStatus({}); refresh().catch(() => {}) },
    onClose: () => { state.socket = false; shell?.setStatus({ text: '连接中…', spinner: true }) }
  })
  enterApp()
}

// From sign-in the app cross-fades in rather than cutting over.
function enterApp() {
  if (shell || !app.querySelector('.auth') || !document.startViewTransition || reducedMotion()) return mountShell()
  const root = document.documentElement
  root.dataset.arrive = ''
  document.startViewTransition(mountShell).finished.finally(() => delete root.dataset.arrive)
}

async function refresh() {
  const boot = await api.get('/api/bootstrap')
  setMe(boot.me)
  setPresence(boot.presence)
  applyBoot(boot)
  shell?.setMe(state.me)
  storage(BOOT_CACHE, JSON.stringify({ me: boot.me, rooms: boot.rooms, contacts: boot.contacts, calls: boot.calls, vapid: boot.vapid, stickers: boot.stickers, assist: boot.assist, prefs: boot.prefs }))
  // Once per launch: keep this device's push subscription current.
  if (!pushSynced) {
    pushSynced = true
    syncPush(state.vapid)
  }
  // Stickers ready before anyone opens the panel (once per launch, when idle).
  if (state.stickers) prewarmStickers()
}
let pushSynced = false

function applyBoot(boot) {
  setRooms(boot.rooms)
  setContacts(boot.contacts)
  state.calls = boot.calls || { enabled: false }
  state.vapid = boot.vapid || null
  state.stickers = Boolean(boot.stickers)
  state.assist = Boolean(boot.assist)
  setPrefs(boot.prefs)
}

function mountShell() {
  if (shell) { shell.setMe(state.me); return }
  calls = createCalls({ socketSend: obj => socket?.send(obj), connected: () => Boolean(socket?.connected) })
  shell = createShell(app, {
    socketSend: obj => socket?.send(obj),
    loadContacts,
    onCall: (room, media) => calls.start(room, media),
    onLogout: logout
  })
  shell.setMe(state.me)
  startPerfProbe()
}

// ---------------------------------------------------------------- realtime events
function handle(msg) {
  switch (msg.t) {
    case 'hello':
      setMe(msg.me)
      setPresence(msg.presence)
      break
    case 'msg': {
      const m = normMsg(msg.msg)
      // A message taken back changes in place: nothing new to count or to
      // move up the list; the row's preview follows only if it was the last.
      if (msg.msg.state === 'revoked') {
        if (state.threads.has(m.chat)) upsertMessage(m)
        const room = state.chats.get(m.chat)
        if (room?.last?.id === m.id) patchRoom(m.chat, { last: { ...room.last, status: m.status, text: previewText(msg.msg, room) } })
        // An unread one is no longer there to read: the server recounts.
        if (!m.out && room?.unread && state.open !== m.chat) refresh().catch(() => {})
        break
      }
      // Replace our own optimistic bubble when the server echoes it back.
      if (msg.localId) {
        const t = state.threads.get(m.chat)
        if (t?.byId.has(`local:${msg.localId}`)) { replaceMessage(`local:${msg.localId}`, m); bumpRoom(m, msg.msg); break }
      }
      // Only materialize into a thread that exists (open or previously opened);
      // otherwise the room row preview is enough until it's opened.
      if (state.threads.has(m.chat) || state.open === m.chat) upsertMessage(m)
      bumpRoom(m, msg.msg)
      break
    }
    case 'read':
      // Peer read our messages in this DM.
      markThreadRead(msg.room, msg.by)
      if (msg.ts > (state.chats.get(msg.room)?.peerRead || 0)) patchRoom(msg.room, { peerRead: msg.ts })
      break
    case 'keys': {
      // A sent message's key words, a moment after it: shown in place.
      const known = state.threads.get(msg.room)?.byId.get(msg.id)
      if (known && Array.isArray(msg.keys)) upsertMessage({ ...known, meta: { ...known.meta, keys: msg.keys } })
      break
    }
    case 'edit': {
      // Rewritten by its sender: in place, nothing new to read; the list's
      // preview follows if it was the last message.
      const known = state.threads.get(msg.msg.room)?.byId.get(msg.msg.id)
      const n = normMsg(msg.msg)
      if (known) upsertMessage({ ...known, text: n.text, meta: n.meta, edited: n.edited, reactions: n.reactions })
      const room = state.chats.get(msg.msg.room)
      if (room?.last?.id === msg.msg.id) patchRoom(msg.msg.room, { last: { ...room.last, text: previewText(msg.msg, room) } })
      // Whoever edited it is done typing.
      if (msg.msg.sender !== state.me?.id) shell?.thread.typingDone(msg.msg.room)
      break
    }
    case 'react': {
      // Only the reactions change: the message keeps its place, read state and unread count.
      const known = state.threads.get(msg.msg.room)?.byId.get(msg.msg.id)
      if (known) upsertMessage({ ...known, reactions: msg.msg.reactions || [] })
      break
    }
    case 'presence':
      markPresence(msg.uid, msg.online)
      break
    case 'typing':
      shell?.thread.setTyping(msg.room, msg.uid, msg.text || '')
      break
    case 'profile':
      patchPeer(msg.user)
      break
    case 'prefs':
      // Backdrops chosen on another of this account's devices.
      setPrefs(msg.prefs)
      break
    case 'rooms-dirty':
      refresh().catch(() => {})
      break
    case 'contacts-dirty':
      loadContacts(true).catch(() => {})
      break
    case 'call':
      calls?.onSignal(msg)
      break
  }
}

function bumpRoom(m, raw) {
  const existing = state.chats.get(m.chat)
  if (existing) {
    const incUnread = !m.out && state.open !== m.chat && raw.type !== 'system'
    // Something new replaces a hand-made unread mark, and brings a deleted
    // conversation back (as on the server).
    const counted = existing.marked ? 0 : existing.unread || 0
    patchRoom(m.chat, {
      ts: m.ts,
      last: { id: m.id, ts: m.ts, out: m.out, type: m.type, status: m.status, text: previewText(raw, existing) },
      unread: incUnread ? counted + 1 : (state.open === m.chat ? 0 : existing.unread),
      ...(raw.type !== 'system' && { hidden: false }),
      ...(incUnread && { marked: false })
    })
  } else {
    // A brand-new room (first message of a fresh DM/group) — fetch it in.
    refresh().catch(() => {})
  }
  if (!m.out && state.open !== m.chat && raw.type !== 'system') shell?.list?.render()
}


function markThreadRead(roomId, by) {
  const t = state.threads.get(roomId)
  if (!t) return
  // Only what reached the server can be read: a message still sending or
  // one that failed keeps saying so.
  for (const m of t.list) {
    if (!m.out || m.status === 'read' || m.status === 'sending' || m.status === 'failed' || String(m.id).startsWith('local:')) continue
    m.status = 'read'
    upsertMessage(m)
  }
}

function patchPeer(user) {
  for (const [id, c] of state.chats) {
    if (c.kind === 'dm' && c.peer?.id === user.id) {
      c.peer = user; c.name = user.display; c.avatar = user.avatar
      patchRoom(id, { name: user.display, avatar: user.avatar, peer: user })
    }
  }
  const mem = state.members
  for (const map of mem.values()) if (map.has(user.id)) map.set(user.id, user)
}

let contactsLoading = null
async function loadContacts(force) {
  if (state.contacts.length && !force) return state.contacts
  contactsLoading ||= api.get('/api/contacts')
    .then(r => { setContacts(r.contacts); return state.contacts })
    .catch(err => { toast(err.message, { type: 'error' }); return [] })
    .finally(() => { contactsLoading = null })
  return contactsLoading
}

async function logout() {
  storage(BOOT_CACHE, null)
  await fetch('/auth/logout', { method: 'POST', credentials: 'same-origin' }).catch(() => {})
  location.reload()
}
