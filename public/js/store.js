// Client state: WeChat session state, chats, contacts and per-chat message
// lists, with a tiny event bus. Views subscribe and update only what changed.

import { storage } from './ui/dom.js'

const bus = new Map()

export function on(event, fn) {
  if (!bus.has(event)) bus.set(event, new Set())
  bus.get(event).add(fn)
  return () => bus.get(event)?.delete(fn)
}

export function emit(event, ...args) {
  for (const fn of bus.get(event) || []) {
    try {
      fn(...args)
    } catch (err) {
      console.error(err)
    }
  }
}

export const state = {
  wx: null,
  me: null,
  chats: new Map(),
  temp: new Map(), // chats opened from contacts that have no messages yet
  contacts: null,
  threads: new Map(),
  open: null,
  filter: 'all',
  socket: false,
  previews: new Map() // cid → object URL for images sent from this device
}

export function setWx(wx) {
  const prev = state.wx
  state.wx = wx
  emit('wx', wx, prev)
}

export function setChats(list) {
  state.chats = new Map(list.map(c => [c.id, c]))
  for (const id of state.chats.keys()) state.temp.delete(id)
  emit('chats', null)
}

export function upsertChats(list) {
  const changed = []
  for (const c of list) {
    if (!c) continue
    const prev = state.chats.get(c.id)
    state.chats.set(c.id, { ...prev, ...c })
    state.temp.delete(c.id)
    changed.push(c.id)
  }
  emit('chats', changed)
}

export function chatInfo(id) {
  return state.chats.get(id) || state.temp.get(id) || null
}

/** Ordered for the list: pinned chats are shown separately above. */
export function sortedChats() {
  const all = [...state.chats.values(), ...state.temp.values()]
  return all.sort((a, b) => (b.ts || 0) - (a.ts || 0) || (a.rank || 1e9) - (b.rank || 1e9))
}

export function unreadTotal(exclude) {
  let n = 0
  for (const c of state.chats.values()) if (c.id !== exclude && !c.muted) n += c.unread || 0
  return n
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

function sortThread(t) {
  t.list.sort((a, b) => a.ts - b.ts || (a.seq || 0) - (b.seq || 0))
}

let seq = 0

/** Merge a page from the server. Returns messages that were new. */
export function mergeMessages(chat, msgs, { older = false } = {}) {
  const t = thread(chat)
  const added = []
  for (const m of msgs) {
    const prev = t.byId.get(m.id)
    if (prev) {
      Object.assign(prev, m)
      continue
    }
    const copy = { ...m, seq: older ? -(++seq) : ++seq }
    t.byId.set(m.id, copy)
    t.list.push(copy)
    added.push(copy)
  }
  sortThread(t)
  return added
}

/** A single live message (new or updated). Emits 'msg'. */
export function upsertMessage(m) {
  const t = thread(m.chat)
  const prev = t.byId.get(m.id)
  if (prev) {
    Object.assign(prev, m)
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
    // The server copy already arrived; drop the local one.
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

export function clearThread(chat) {
  const t = state.threads.get(chat)
  if (!t) return
  t.list = []
  t.byId.clear()
  t.hasMore = false
  emit('cleared', chat)
}

// ---------------------------------------------------------------- drafts

export function getDraft(chat) {
  return storage(`draft:${chat}`) || ''
}

export function setDraft(chat, text) {
  storage(`draft:${chat}`, text ? text : null)
}

export function newCid() {
  // 17 digits like the official client's ClientMsgId.
  return `${Date.now()}${String(Math.floor(Math.random() * 10000)).padStart(4, '0')}`
}
