// Client state for the messenger: the signed-in user, rooms (conversations),
// contacts, presence, per-room members and message lists, with a tiny event
// bus. Server objects are normalized here into the shapes the views consume.

import { storage } from './ui/dom.js'

const bus = new Map()

export function on(event, fn) {
  if (!bus.has(event)) bus.set(event, new Set())
  bus.get(event).add(fn)
  return () => bus.get(event)?.delete(fn)
}
export function emit(event, ...args) {
  for (const fn of bus.get(event) || []) {
    try { fn(...args) } catch (err) { console.error(err) }
  }
}

export const state = {
  me: null,
  chats: new Map(),       // roomId -> normalized room
  temp: new Map(),        // rooms opened before they have messages
  contacts: [],
  presence: new Set(),    // online user ids
  members: new Map(),     // roomId -> Map(uid -> user)
  threads: new Map(),
  open: null,
  filter: 'all',
  socket: false,
  calls: { enabled: false },
  vapid: null,
  previews: new Map()     // localId -> object URL for just-sent media
}

export function setMe(me) { state.me = me }

// ---------------------------------------------------------------- normalize

export function normRoom(r) {
  const online = r.kind === 'dm' && r.peer ? state.presence.has(r.peer.id) : false
  return {
    id: r.id,
    kind: r.kind,
    room: r.kind === 'group',
    name: r.name,
    avatar: r.avatar || '',
    peer: r.peer || null,
    peerRead: r.peerRead || 0,
    unread: r.unread || 0,
    muted: Boolean(r.muted),
    pinned: Boolean(r.pinned),
    count: r.count || 0,
    ts: r.ts || 0,
    online,
    last: r.last ? normLast(r.last, r) : null
  }
}

function normLast(m, room) {
  return {
    id: m.id,
    ts: m.ts,
    out: m.sender === state.me?.id,
    type: m.type,
    status: m.state,
    text: previewText(m, room)
  }
}

export function previewText(m, room) {
  if (m.state === 'revoked') return '[已撤回]'
  let body = m.type === 'text' ? m.body
    : { image: '[图片]', drawing: '[手绘]', voice: '[语音]', video: '[视频]', file: '[文件]', call: m.body || '[通话]', system: m.body }[m.type] || '[消息]'
  if (room?.kind === 'group' && m.type !== 'system' && m.sender !== state.me?.id) {
    const who = nameOf(m.sender, room.id)
    if (who) body = `${who}: ${body}`
  }
  return body
}

export function nameOf(uid, roomId) {
  if (!uid) return ''
  if (uid === state.me?.id) return state.me.display
  const member = state.members.get(roomId)?.get(uid)
  if (member) return member.display
  const contact = state.contacts.find(c => c.id === uid)
  if (contact) return contact.display
  const room = state.chats.get(roomId)
  if (room?.peer?.id === uid) return room.peer.display
  return ''
}

export function avatarOf(uid, roomId) {
  if (uid === state.me?.id) return state.me.avatar
  const member = state.members.get(roomId)?.get(uid)
  if (member) return member.avatar
  const room = state.chats.get(roomId)
  if (room?.peer?.id === uid) return room.peer.avatar
  const contact = state.contacts.find(c => c.id === uid)
  return contact?.avatar || ''
}

export function normMsg(m) {
  const meta = m.meta || {}
  return {
    id: m.id,
    chat: m.room,
    ts: m.ts,
    out: m.sender === state.me?.id,
    from: m.sender,
    fromName: nameOf(m.sender, m.room),
    type: m.type,
    text: m.body,
    status: m.state,
    meta,
    url: meta.url || '',
    w: meta.w,
    h: meta.h,
    dur: meta.dur,
    name: meta.name,
    size: meta.size,
    call: m.type === 'call' ? meta : null,
    replyTo: m.replyTo || null,
    reactions: m.reactions || []
  }
}

export function setMembers(roomId, users) {
  state.members.set(roomId, new Map(users.map(u => [u.id, u])))
}

// ---------------------------------------------------------------- rooms
export function setRooms(list) {
  state.chats = new Map(list.map(r => [r.id, normRoom(r)]))
  for (const id of state.chats.keys()) state.temp.delete(id)
  emit('chats', null)
}
export function upsertRoom(r) {
  const n = normRoom(r)
  state.chats.set(n.id, { ...state.chats.get(n.id), ...n })
  state.temp.delete(n.id)
  emit('chats', [n.id])
}
/** Shallow local patch (unread, flags) without a server round-trip. */
export function patchRoom(id, patch) {
  const prev = state.chats.get(id)
  if (!prev) return
  state.chats.set(id, { ...prev, ...patch })
  emit('chats', [id])
}
export function chatInfo(id) {
  return state.chats.get(id) || state.temp.get(id) || null
}
export function sortedChats() {
  return [...state.chats.values(), ...state.temp.values()]
    .sort((a, b) => (b.pinned - a.pinned) || (b.ts || 0) - (a.ts || 0))
}
export function unreadTotal(exclude) {
  let n = 0
  for (const c of state.chats.values()) if (c.id !== exclude && !c.muted) n += c.unread || 0
  return n
}

export function setContacts(list) {
  state.contacts = list || []
  emit('contacts')
}
export function setPresence(uids) {
  state.presence = new Set(uids || [])
  refreshPresence()
}
export function markPresence(uid, online) {
  if (online) state.presence.add(uid)
  else state.presence.delete(uid)
  refreshPresence()
}
function refreshPresence() {
  const changed = []
  for (const [id, c] of state.chats) {
    if (c.kind === 'dm' && c.peer) {
      const on = state.presence.has(c.peer.id)
      if (on !== c.online) { c.online = on; changed.push(id) }
    }
  }
  if (changed.length) emit('chats', changed)
  emit('presence')
}

// ---------------------------------------------------------------- messages
export function thread(chat) {
  let t = state.threads.get(chat)
  if (!t) {
    t = { chat, list: [], byId: new Map(), hasMore: true, loading: false, loaded: false }
    state.threads.set(chat, t)
  }
  return t
}
function sortThread(t) { t.list.sort((a, b) => a.ts - b.ts || (a.seq || 0) - (b.seq || 0)) }

let seq = 0
export function mergeMessages(chat, msgs, { older = false } = {}) {
  const t = thread(chat)
  const added = []
  for (const m of msgs) {
    const prev = t.byId.get(m.id)
    if (prev) { Object.assign(prev, m); continue }
    const copy = { ...m, seq: older ? -(++seq) : ++seq }
    t.byId.set(m.id, copy)
    t.list.push(copy)
    added.push(copy)
  }
  sortThread(t)
  return added
}
export function upsertMessage(m) {
  const t = thread(m.chat)
  const prev = t.byId.get(m.id)
  if (prev) { Object.assign(prev, m); emit('msg', prev, 'update'); return prev }
  const copy = { ...m, seq: ++seq }
  t.byId.set(m.id, copy)
  t.list.push(copy)
  sortThread(t)
  emit('msg', copy, 'new')
  return copy
}
export function replaceMessage(fromId, m) {
  const t = thread(m.chat)
  const prev = t.byId.get(fromId)
  if (!prev) return upsertMessage(m)
  t.byId.delete(fromId)
  if (t.byId.has(m.id)) {
    t.list = t.list.filter(x => x !== prev)
    emit('remove', fromId, m.chat)
    return upsertMessage(m)
  }
  Object.assign(prev, m)
  t.byId.set(m.id, prev)
  emit('replace', fromId, prev)
  return prev
}
export function removeMessage(id, chat) {
  const t = state.threads.get(chat)
  if (!t) return
  const m = t.byId.get(id)
  if (!m) return
  t.byId.delete(id)
  t.list = t.list.filter(x => x !== m)
  emit('remove', id, chat)
}

// ---------------------------------------------------------------- drafts
export function getDraft(chat) { return storage(`draft:${chat}`) || '' }
export function setDraft(chat, text) { storage(`draft:${chat}`, text || null) }
export function newCid() {
  return `${Date.now()}${String(Math.floor(Math.random() * 10000)).padStart(4, '0')}`
}
