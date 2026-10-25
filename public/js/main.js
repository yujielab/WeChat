// App entry: account gate → realtime messenger.

import { initViewport } from './ui/viewport.js'
import { initPress } from './ui/press.js'
import { syncThemeColor, startPerfProbe } from './ui/appearance.js'
import { api, connectSocket, onApiEvent } from './api.js'
import {
  state, setMe, setRooms, upsertRoom, patchRoom, setContacts, setPresence, markPresence,
  normMsg, previewText, thread, upsertMessage, replaceMessage, removeMessage, chatInfo
} from './store.js'
import { renderAuth } from './views/auth.js'
import { createShell } from './views/shell.js'
import { createCalls } from './views/call.js'
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

onApiEvent(evt => { if (evt === 'unauthorized') location.reload() })

boot()

async function boot() {
  let status
  try {
    status = await fetch('/auth/status', { credentials: 'same-origin' }).then(r => r.json())
  } catch {
    app.replaceChildren()
    toast('无法连接服务器，请检查网络', { type: 'error', duration: 6000 })
    setTimeout(boot, 4000)
    return
  }
  if (status.authed) return start(status.me)
  renderAuth(app, { needsCode: status.needsCode, onSuccess: start })
}

async function start(me) {
  setMe(me)
  try {
    await refresh()
  } catch (err) {
    toast(err.message, { type: 'error' })
    return setTimeout(() => start(me), 3000)
  }
  socket?.close()
  socket = connectSocket({
    onMessage: handle,
    onOpen: () => { state.socket = true; shell?.setStatus({}); refresh().catch(() => {}) },
    onClose: () => { state.socket = false; shell?.setStatus({ text: '连接中…', spinner: true }) }
  })
  mountShell()
}

async function refresh() {
  const boot = await api.get('/api/bootstrap')
  setMe(boot.me)
  setPresence(boot.presence)
  setRooms(boot.rooms)
  setContacts(boot.contacts)
  state.calls = boot.calls || { enabled: false }
  state.vapid = boot.vapid || null
  shell?.setMe(state.me)
}

function mountShell() {
  if (shell) { shell.setMe(state.me); return }
  calls = createCalls({ socketSend: obj => socket?.send(obj) })
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
      break
    case 'presence':
      markPresence(msg.uid, msg.online)
      break
    case 'typing':
      shell?.thread.setTyping(msg.room, msg.uid, msg.text || '')
      break
    case 'profile':
      patchPeer(msg.user)
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
    patchRoom(m.chat, {
      ts: m.ts,
      last: { id: m.id, ts: m.ts, out: m.out, type: m.type, status: m.status, text: previewText(raw, existing) },
      unread: incUnread ? (existing.unread || 0) + 1 : (state.open === m.chat ? 0 : existing.unread)
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
  for (const m of t.list) if (m.out && m.status !== 'read') { m.status = 'read'; upsertMessage(m) }
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
  await fetch('/auth/logout', { method: 'POST', credentials: 'same-origin' }).catch(() => {})
  location.reload()
}
