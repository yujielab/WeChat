// Client state for the messenger: the signed-in user, rooms (conversations),
// contacts, presence, per-room members and message lists, with a tiny event
// bus. Server objects are normalized here into the shapes the views consume.

import { storage } from './ui/dom.js'
import { callSummary } from './ui/format.js'

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
  stickers: false,
  assist: false,
  // Backdrops (views/backdrops.js): for every conversation, each one's own, and calls;
  // and whether friends see when you've read their messages (Settings › Messages).
  prefs: { chat: '', call: '', rooms: {}, receipts: true },
  vapid: null,
  previews: new Map(),    // localId -> object URL for just-sent media
  restored: false         // painted from the cached bootstrap at launch
}

export function setMe(me) {
  state.me = me
  emit('me', me)
}
export function setPrefs(prefs) {
  const p = prefs && typeof prefs === 'object' ? prefs : {}
  state.prefs = { chat: p.chat || '', call: p.call || '', rooms: { ...p.rooms }, receipts: p.receipts !== false }
  emit('prefs', state.prefs)
}

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
    peerReadAt: r.peerReadAt || 0, // when they read it (0: not known, or not shared)
    unread: r.unread || 0,
    lastRead: r.lastRead || 0,
    marked: Boolean(r.marked),
    mention: r.mention || null, // the first unread message that @-mentions me (groups)
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
  // A message taken back says who took it back (no "name:" prefix needed).
  if (m.state === 'revoked') return m.sender === state.me?.id ? 'You unsent a message' : `${nameOf(m.sender, room?.id) || 'Someone'} unsent a message`
  let body = m.type === 'text' ? m.body
    : m.type === 'call' ? callPreview(m)
    : m.type === 'sticker' ? `[Sticker]${m.meta?.emoji ? ` ${m.meta.emoji}` : ''}`
    : { image: '[Photo]', drawing: '[Drawing]', voice: '[Voice]', video: '[Video]', file: '[File]', system: m.body }[m.type] || '[Message]'
  if (room?.kind === 'group' && m.type !== 'system' && m.sender !== state.me?.id) {
    const who = nameOf(m.sender, room.id)
    if (who) body = `${who}: ${body}`
  }
  return body
}

// The list says what the conversation's own record says (ui/format.js).
function callPreview(m) {
  const call = m.meta || {}
  const s = callSummary(call, call.caller ? call.caller === state.me?.id : m.sender === state.me?.id)
  return `[${s.media} call] ${s.text}`
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
    reply: m.reply || null, // what it answers, as the server last saw it (src/store.js replySnapshot)
    reactions: m.reactions || [],
    edited: m.edited || 0 // rewritten by its sender this many times (meta.history: the earlier wordings)
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
  // A deleted conversation is gone at once, not at the next refresh.
  return [...state.chats.values(), ...state.temp.values()]
    .filter(c => !c.hidden)
    .sort((a, b) => (b.pinned - a.pinned) || (b.ts || 0) - (a.ts || 0))
}
export function unreadTotal(exclude) {
  let n = 0
  for (const c of state.chats.values()) if (c.id !== exclude && !c.muted && !c.hidden) n += c.unread || 0
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
// Still on its way (not yet given a place by the server): after everything
// that has one, in the order written. Once it lands it takes the server's
// time, which is later than whatever arrived meanwhile, so it doesn't jump.
const pending = m => m.status === 'sending' && String(m.id).startsWith('local:')
function sortThread(t) { t.list.sort((a, b) => pending(a) - pending(b) || a.ts - b.ts || (a.seq || 0) - (b.seq || 0)) }

// Messages deleted "from this device" stay deleted here: the server still
// has them (the other side still sees them), so every load filters them out.
const DELETED_KEY = 'deleted:msgs'
const DELETED_MAX = 1000
let deletedHere = null
function deletedSet() {
  if (!deletedHere) {
    try { deletedHere = new Set(JSON.parse(storage(DELETED_KEY) || '[]')) } catch { deletedHere = new Set() }
  }
  return deletedHere
}
export function isDeletedHere(id) { return deletedSet().has(String(id)) }
function rememberDeleted(id) {
  const set = deletedSet()
  set.add(String(id))
  const ids = [...set].slice(-DELETED_MAX)
  deletedHere = new Set(ids)
  storage(DELETED_KEY, JSON.stringify(ids))
}

/**
 * What the list shows as a conversation's latest message. One deleted on
 * this device never shows its words there: the one before it (when this
 * device has it) takes its place, or else nothing but the time.
 */
export function listLast(c) {
  const last = c?.last
  if (!last || !isDeletedHere(last.id)) return last || null
  const prev = state.threads.get(c.id)?.list.at(-1)
  if (!prev) return { ...last, status: 'sent', text: '' }
  return {
    id: prev.id, ts: prev.ts, out: prev.out, type: prev.type, status: prev.status,
    text: previewText({ state: prev.status, sender: prev.from, type: prev.type, body: prev.text, meta: prev.meta }, c)
  }
}

let seq = 0
export function mergeMessages(chat, msgs, { older = false } = {}) {
  const t = thread(chat)
  const added = []
  let skipped = false
  for (const m of msgs) {
    if (isDeletedHere(m.id)) { skipped = true; continue }
    const prev = t.byId.get(m.id)
    if (prev) { Object.assign(prev, m); continue }
    const copy = { ...m, seq: older ? -(++seq) : ++seq }
    t.byId.set(m.id, copy)
    t.list.push(copy)
    added.push(copy)
  }
  sortThread(t)
  // The list can now show the message before a deleted last one.
  if (skipped && isDeletedHere(state.chats.get(chat)?.last?.id)) emit('chats', [chat])
  return added
}
export function upsertMessage(m) {
  const t = thread(m.chat)
  const prev = t.byId.get(m.id)
  // An edit, reaction or recall of one deleted here doesn't bring it back.
  if (!prev && isDeletedHere(m.id)) return null
  if (prev) {
    // Sent again (failed → sending): it waits with the others at the end.
    const was = pending(prev)
    Object.assign(prev, m)
    if (pending(prev) !== was) sortThread(t)
    emit('msg', prev, 'update')
    return prev
  }
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
  sortThread(t)
  emit('replace', fromId, prev)
  return prev
}
/** Take a message out of its thread; { here: true } keeps it out after reloads too. */
export function removeMessage(id, chat, { here = false } = {}) {
  if (here && !String(id).startsWith('local:')) rememberDeleted(id)
  const t = state.threads.get(chat)
  if (!t) return
  const m = t.byId.get(id)
  if (!m) return
  t.byId.delete(id)
  t.list = t.list.filter(x => x !== m)
  emit('remove', id, chat)
  // Deleted here while it was the latest: the list's preview moves off it.
  if (here && state.chats.get(chat)?.last?.id === id) emit('chats', [chat])
}

// ---------------------------------------------------------------- drafts
export function getDraft(chat) { return storage(`draft:${chat}`) || '' }
export function setDraft(chat, text) { storage(`draft:${chat}`, text || null) }
export function newCid() {
  return `${Date.now()}${String(Math.floor(Math.random() * 10000)).padStart(4, '0')}`
}
