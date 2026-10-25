// SQLite persistence for the Durable Object. Takes a plain
// `exec(sql, ...bindings) => rows[]` function so the same code runs on the
// Durable Object's storage.sql and on node:sqlite in tests.

import { previewOf, isRoomId } from './wx/normalize.js'

const SCHEMA = [
  `CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT NOT NULL)`,
  `CREATE TABLE IF NOT EXISTS contacts (id TEXT PRIMARY KEY, data TEXT NOT NULL, epoch INTEGER NOT NULL DEFAULT 0)`,
  `CREATE TABLE IF NOT EXISTS chats (
     id TEXT PRIMARY KEY,
     ts INTEGER NOT NULL DEFAULT 0,
     unread INTEGER NOT NULL DEFAULT 0,
     last TEXT,
     rank INTEGER NOT NULL DEFAULT 0,
     hidden INTEGER NOT NULL DEFAULT 0
   )`,
  `CREATE TABLE IF NOT EXISTS messages (id TEXT PRIMARY KEY, chat TEXT NOT NULL, ts INTEGER NOT NULL, data TEXT NOT NULL)`,
  `CREATE INDEX IF NOT EXISTS messages_chat_ts ON messages (chat, ts)`,
  `CREATE TABLE IF NOT EXISTS push_subs (endpoint TEXT PRIMARY KEY, data TEXT NOT NULL, created INTEGER NOT NULL)`
]

const KEEP_PER_CHAT = 3000

export class Store {
  constructor(exec) {
    this.exec = exec
    for (const s of SCHEMA) exec(s)
    this.inserts = 0
  }

  // ------------------------------------------------------------- kv

  get(k, fallback = null) {
    const row = this.exec('SELECT v FROM kv WHERE k = ?', k)[0]
    return row ? JSON.parse(row.v) : fallback
  }

  set(k, v) {
    if (v === undefined || v === null) this.exec('DELETE FROM kv WHERE k = ?', k)
    else this.exec('INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v = excluded.v', k, JSON.stringify(v))
  }

  // ------------------------------------------------------------- contacts

  loadContacts() {
    const map = new Map()
    for (const r of this.exec('SELECT data FROM contacts')) {
      const c = JSON.parse(r.data)
      map.set(c.id, c)
    }
    return map
  }

  putContact(c, epoch) {
    this.exec(
      'INSERT INTO contacts (id, data, epoch) VALUES (?, ?, ?) ON CONFLICT(id) DO UPDATE SET data = excluded.data, epoch = excluded.epoch',
      c.id, JSON.stringify(c), epoch
    )
  }

  deleteContact(id) {
    this.exec('DELETE FROM contacts WHERE id = ?', id)
  }

  // ------------------------------------------------------------- chats

  chatRow(id) {
    const r = this.exec('SELECT * FROM chats WHERE id = ?', id)[0]
    return r ? rowToChat(r) : null
  }

  listChats() {
    return this.exec('SELECT * FROM chats WHERE hidden = 0 ORDER BY ts DESC, rank ASC').map(rowToChat)
  }

  ensureChat(id, rank = 0) {
    this.exec('INSERT INTO chats (id, rank) VALUES (?, ?) ON CONFLICT(id) DO NOTHING', id, rank)
  }

  setRank(id, rank) {
    this.exec(
      'INSERT INTO chats (id, rank) VALUES (?, ?) ON CONFLICT(id) DO UPDATE SET rank = excluded.rank',
      id, rank
    )
  }

  setUnread(id, n) {
    this.exec('UPDATE chats SET unread = ? WHERE id = ?', n, id)
  }

  hideChat(id, hidden = true) {
    this.exec('UPDATE chats SET hidden = ? WHERE id = ?', hidden ? 1 : 0, id)
  }

  /** Recompute the chat's last-message summary from stored messages. */
  refreshChatLast(id) {
    const last = this.exec('SELECT data FROM messages WHERE chat = ? ORDER BY ts DESC, rowid DESC LIMIT 1', id)[0]
    const m = last ? JSON.parse(last.data) : null
    this.exec(
      'UPDATE chats SET last = ?, ts = ? WHERE id = ?',
      m ? JSON.stringify(summaryOf(m)) : null,
      m ? m.ts : 0,
      id
    )
  }

  // ------------------------------------------------------------- messages

  hasMessage(id) {
    return this.exec('SELECT 1 AS x FROM messages WHERE id = ?', id).length > 0
  }

  getMessage(id) {
    const r = this.exec('SELECT data FROM messages WHERE id = ?', id)[0]
    return r ? JSON.parse(r.data) : null
  }

  /**
   * Store a new message and update its chat. Returns false if it was a duplicate.
   * `countUnread` decides whether an incoming message bumps the unread badge.
   */
  addMessage(m, { countUnread = true } = {}) {
    if (this.hasMessage(m.id)) return false
    this.exec('INSERT INTO messages (id, chat, ts, data) VALUES (?, ?, ?, ?)', m.id, m.chat, m.ts, JSON.stringify(m))
    const unreadDelta = !m.out && countUnread && m.type !== 'system' ? 1 : 0
    this.exec(
      `INSERT INTO chats (id, ts, unread, last, hidden) VALUES (?, ?, ?, ?, 0)
       ON CONFLICT(id) DO UPDATE SET
         ts = MAX(chats.ts, excluded.ts),
         last = CASE WHEN excluded.ts >= chats.ts THEN excluded.last ELSE chats.last END,
         unread = CASE WHEN ? THEN 0 ELSE chats.unread + excluded.unread END,
         hidden = 0`,
      m.chat, m.ts, unreadDelta, JSON.stringify(summaryOf(m)), m.out ? 1 : 0
    )
    if (++this.inserts % 200 === 0) this.prune(m.chat)
    return true
  }

  updateMessage(id, patch) {
    const m = this.getMessage(id)
    if (!m) return null
    const next = { ...m, ...patch }
    this.exec('UPDATE messages SET data = ? WHERE id = ?', JSON.stringify(next), id)
    this.refreshChatLast(m.chat)
    return next
  }

  /** Give a locally created message its server id. */
  rekeyMessage(oldId, newId, patch = {}) {
    const m = this.getMessage(oldId)
    if (!m) return null
    const next = { ...m, ...patch, id: newId }
    this.exec('DELETE FROM messages WHERE id = ?', oldId)
    this.exec('INSERT OR REPLACE INTO messages (id, chat, ts, data) VALUES (?, ?, ?, ?)', newId, next.chat, next.ts, JSON.stringify(next))
    this.refreshChatLast(next.chat)
    return next
  }

  deleteMessage(id) {
    const m = this.getMessage(id)
    if (!m) return null
    this.exec('DELETE FROM messages WHERE id = ?', id)
    this.refreshChatLast(m.chat)
    return m
  }

  /** Page of messages, oldest first. `before` is exclusive (ms). */
  listMessages(chat, { before = Number.MAX_SAFE_INTEGER, after = 0, limit = 60 } = {}) {
    const rows = this.exec(
      'SELECT data FROM messages WHERE chat = ? AND ts < ? AND ts > ? ORDER BY ts DESC, rowid DESC LIMIT ?',
      chat, before, after, limit
    )
    return rows.map(r => JSON.parse(r.data)).reverse()
  }

  clearChat(chat) {
    this.exec('DELETE FROM messages WHERE chat = ?', chat)
    this.exec('UPDATE chats SET last = NULL, unread = 0 WHERE id = ?', chat)
  }

  prune(chat) {
    this.exec(
      `DELETE FROM messages WHERE chat = ? AND rowid NOT IN
         (SELECT rowid FROM messages WHERE chat = ? ORDER BY ts DESC LIMIT ?)`,
      chat, chat, KEEP_PER_CHAT
    )
  }

  // ------------------------------------------------------------- re-login

  /**
   * WeChat hands out new session-scoped user names on every login. Map the
   * previous login's chats onto the new contacts by (kind, remark, nickname)
   * when that match is unique, so history survives a re-scan.
   * Returns the number of chats carried over.
   */
  remapAfterLogin(epoch) {
    const rows = this.exec('SELECT id, data, epoch FROM contacts')
    const fresh = new Map()
    const stale = new Map()
    for (const r of rows) {
      const c = JSON.parse(r.data)
      ;(r.epoch === epoch ? fresh : stale).set(c.id, c)
    }
    const keyOf = c => `${c.room ? 1 : 0}|${c.remark}|${c.nick}`
    const byKey = new Map()
    for (const c of fresh.values()) {
      if (!c.remark && !c.nick) continue
      const k = keyOf(c)
      byKey.set(k, byKey.has(k) ? null : c)
    }
    let moved = 0
    for (const chat of this.exec('SELECT id FROM chats').map(r => r.id)) {
      if (fresh.has(chat)) continue
      const old = stale.get(chat)
      const target = old && (old.remark || old.nick) ? byKey.get(keyOf(old)) : null
      if (!target) {
        if (!this.exec('SELECT 1 AS x FROM messages WHERE chat = ? LIMIT 1', chat).length) {
          this.exec('DELETE FROM chats WHERE id = ?', chat)
        }
        continue
      }
      const prevRow = this.chatRow(chat)
      const targetRow = this.chatRow(target.id)
      if (targetRow) {
        this.exec('DELETE FROM chats WHERE id = ?', chat)
        this.exec('UPDATE chats SET unread = ? WHERE id = ?', targetRow.unread + (prevRow?.unread || 0), target.id)
      } else {
        this.exec('UPDATE chats SET id = ? WHERE id = ?', target.id, chat)
      }
      for (const r of this.exec('SELECT id, data FROM messages WHERE chat = ?', chat)) {
        const m = JSON.parse(r.data)
        m.chat = target.id
        if (!m.out && !isRoomId(chat)) m.from = target.id
        if (isRoomId(chat) && !m.out && old.members && target.members) {
          const was = old.members.find(x => x.id === m.from)
          const now = was && target.members.filter(x => (x.dn || x.nick) === (was.dn || was.nick))
          if (now?.length === 1) m.from = now[0].id
        }
        this.exec('UPDATE messages SET chat = ?, data = ? WHERE id = ?', target.id, JSON.stringify(m), r.id)
      }
      this.refreshChatLast(target.id)
      moved++
    }
    // Contacts from the previous login: drop them unless a chat still shows
    // their history, in which case keep the name but mark them read-only.
    const referenced = new Set(this.exec('SELECT id FROM chats').map(r => r.id))
    for (const [id, c] of stale) {
      if (!referenced.has(id)) this.deleteContact(id)
      else if (!c.stale) this.putContact({ ...c, stale: true }, -1)
    }
    return moved
  }

  wipe() {
    for (const t of ['contacts', 'chats', 'messages']) this.exec(`DELETE FROM ${t}`)
  }

  // ------------------------------------------------------------- push

  pushSubs() {
    return this.exec('SELECT data FROM push_subs').map(r => JSON.parse(r.data))
  }

  addPushSub(sub) {
    this.exec(
      'INSERT INTO push_subs (endpoint, data, created) VALUES (?, ?, ?) ON CONFLICT(endpoint) DO UPDATE SET data = excluded.data',
      sub.endpoint, JSON.stringify(sub), Date.now()
    )
  }

  removePushSub(endpoint) {
    this.exec('DELETE FROM push_subs WHERE endpoint = ?', endpoint)
  }
}

export function summaryOf(m) {
  return {
    id: m.id,
    text: previewOf(m),
    out: Boolean(m.out),
    type: m.type,
    status: m.status || 'sent',
    ts: m.ts
  }
}

function rowToChat(r) {
  return {
    id: r.id,
    ts: r.ts,
    unread: r.unread,
    last: r.last ? JSON.parse(r.last) : null,
    rank: r.rank,
    hidden: Boolean(r.hidden)
  }
}
