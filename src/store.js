// SQLite data layer for the messenger, running in the Hub Durable Object's
// embedded SQLite. `exec(sql, ...binds)` runs a statement and returns the rows
// as plain objects (empty for writes), so the same class is unit-testable
// against node:sqlite.

const now = () => Date.now()
export const rid = () => crypto.randomUUID().replace(/-/g, '').slice(0, 20)
/** The tapbacks a message can carry; one per person, replaced when they pick another. */
export const REACTIONS = ['❤️', '😂', '👍', '😮', '😢', '🙏']
/** A text message can be rewritten by its sender for this long after sending, this many times (as in Messages). */
export const EDIT_WINDOW = 15 * 60 * 1000
export const EDIT_MAX = 5
/** Why `uid` can't rewrite message `m` as `text` now ('' when they can). */
export function editProblem(m, uid, text, at = now()) {
  if (!m || m.sender !== uid || m.type !== 'text' || m.state === 'revoked') return '无法编辑这条消息'
  if (!String(text).trim()) return '不能改成空消息'
  if (at - m.ts > EDIT_WINDOW) return '发出超过 15 分钟的消息不能再编辑'
  if ((m.edited || 0) >= EDIT_MAX) return `每条消息最多编辑 ${EDIT_MAX} 次`
  return ''
}

export class Store {
  constructor(exec) {
    this.exec = exec
    this.#schema()
  }

  #schema() {
    const s = this.exec
    s(`CREATE TABLE IF NOT EXISTS kv (k TEXT PRIMARY KEY, v TEXT)`)
    s(`CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY,
      username TEXT NOT NULL,
      uname_lc TEXT NOT NULL UNIQUE,
      display TEXT NOT NULL,
      salt TEXT NOT NULL,
      hash TEXT NOT NULL,
      avatar TEXT DEFAULT '',
      bio TEXT DEFAULT '',
      epoch INTEGER NOT NULL DEFAULT 0,
      created INTEGER NOT NULL
    )`)
    s(`CREATE TABLE IF NOT EXISTS contacts (
      owner TEXT NOT NULL,
      peer TEXT NOT NULL,
      state TEXT NOT NULL,            -- pending_out | pending_in | accepted | blocked
      created INTEGER NOT NULL,
      PRIMARY KEY (owner, peer)
    )`)
    s(`CREATE TABLE IF NOT EXISTS rooms (
      id TEXT PRIMARY KEY,
      kind TEXT NOT NULL,            -- dm | group
      name TEXT DEFAULT '',
      avatar TEXT DEFAULT '',
      creator TEXT DEFAULT '',
      dm_key TEXT UNIQUE,            -- sorted "a|b" for dm dedupe, null for groups
      created INTEGER NOT NULL
    )`)
    s(`CREATE TABLE IF NOT EXISTS room_members (
      room TEXT NOT NULL,
      user TEXT NOT NULL,
      role TEXT NOT NULL DEFAULT 'member',
      muted INTEGER NOT NULL DEFAULT 0,
      pinned INTEGER NOT NULL DEFAULT 0,
      hidden INTEGER NOT NULL DEFAULT 0,
      last_read INTEGER NOT NULL DEFAULT 0,
      joined INTEGER NOT NULL,
      PRIMARY KEY (room, user)
    )`)
    s(`CREATE INDEX IF NOT EXISTS idx_members_user ON room_members (user)`)
    s(`CREATE TABLE IF NOT EXISTS messages (
      id TEXT PRIMARY KEY,
      room TEXT NOT NULL,
      sender TEXT NOT NULL,
      ts INTEGER NOT NULL,
      type TEXT NOT NULL,            -- text | image | voice | video | file | call | system
      body TEXT DEFAULT '',
      meta TEXT DEFAULT '',          -- JSON for media/call payloads
      reply_to TEXT DEFAULT '',
      state TEXT NOT NULL DEFAULT 'sent',  -- sent | delivered | read | revoked
      edited INTEGER NOT NULL DEFAULT 0
    )`)
    s(`CREATE INDEX IF NOT EXISTS idx_msg_room_ts ON messages (room, ts)`)
    s(`CREATE TABLE IF NOT EXISTS reactions (
      msg TEXT NOT NULL,
      user TEXT NOT NULL,
      emoji TEXT NOT NULL,
      ts INTEGER NOT NULL,
      PRIMARY KEY (msg, user)
    )`)
    s(`CREATE TABLE IF NOT EXISTS push_subs (
      id TEXT PRIMARY KEY,
      user TEXT NOT NULL,
      data TEXT NOT NULL,
      created INTEGER NOT NULL
    )`)
    s(`CREATE INDEX IF NOT EXISTS idx_push_user ON push_subs (user)`)
  }

  // ---------------------------------------------------------------- kv
  kvGet(k, fallback = null) {
    const row = this.exec(`SELECT v FROM kv WHERE k=?`, k)[0]
    return row ? JSON.parse(row.v) : fallback
  }
  kvSet(k, v) {
    this.exec(`INSERT INTO kv (k, v) VALUES (?, ?) ON CONFLICT(k) DO UPDATE SET v=excluded.v`, k, JSON.stringify(v))
  }
  kvDelete(k) {
    this.exec(`DELETE FROM kv WHERE k=?`, k)
  }
  /** [key, value] pairs whose key starts with `prefix`. */
  kvList(prefix) {
    return this.exec(`SELECT k, v FROM kv WHERE substr(k, 1, ?)=?`, prefix.length, prefix).map(r => [r.k, JSON.parse(r.v)])
  }

  // ---------------------------------------------------------------- users
  createUser({ username, display, salt, hash }) {
    const id = rid()
    const lc = username.toLowerCase()
    this.exec(
      `INSERT INTO users (id, username, uname_lc, display, salt, hash, created) VALUES (?,?,?,?,?,?,?)`,
      id, username, lc, display || username, salt, hash, now()
    )
    return this.getUser(id)
  }
  getUser(id) {
    return this.exec(`SELECT * FROM users WHERE id=?`, id)[0] || null
  }
  getUserByUsername(username) {
    return this.exec(`SELECT * FROM users WHERE uname_lc=?`, String(username).toLowerCase())[0] || null
  }
  userCount() {
    return this.exec(`SELECT COUNT(*) AS n FROM users`)[0].n
  }
  searchUsers(q, exclude, limit = 20) {
    const like = `%${String(q).toLowerCase()}%`
    return this.exec(
      `SELECT id, username, display, avatar, bio FROM users
       WHERE id<>? AND (uname_lc LIKE ? OR LOWER(display) LIKE ?) ORDER BY uname_lc LIMIT ?`,
      exclude || '', like, like, limit
    )
  }
  setProfile(id, { display, avatar, bio }) {
    const u = this.getUser(id)
    if (!u) return null
    this.exec(`UPDATE users SET display=?, avatar=?, bio=? WHERE id=?`,
      display ?? u.display, avatar ?? u.avatar, bio ?? u.bio, id)
    return this.getUser(id)
  }
  setPassword(id, salt, hash) {
    this.exec(`UPDATE users SET salt=?, hash=?, epoch=epoch+1 WHERE id=?`, salt, hash, id)
  }
  bumpEpoch(id) {
    this.exec(`UPDATE users SET epoch=epoch+1 WHERE id=?`, id)
  }

  /** Public view of a user (no secrets). */
  pub(u) {
    if (!u) return null
    return { id: u.id, username: u.username, display: u.display, avatar: u.avatar, bio: u.bio }
  }

  // ---------------------------------------------------------------- contacts
  contactState(owner, peer) {
    const r = this.exec(`SELECT state FROM contacts WHERE owner=? AND peer=?`, owner, peer)[0]
    return r?.state || null
  }
  requestContact(owner, peer) {
    const existing = this.contactState(owner, peer)
    if (existing === 'accepted' || existing === 'pending_out') return existing
    const t = now()
    this.#putContact(owner, peer, 'pending_out', t)
    this.#putContact(peer, owner, 'pending_in', t)
    return 'pending_out'
  }
  acceptContact(owner, peer) {
    // owner accepts an incoming request from peer
    if (this.contactState(owner, peer) !== 'pending_in') return false
    const t = now()
    this.#putContact(owner, peer, 'accepted', t)
    this.#putContact(peer, owner, 'accepted', t)
    return true
  }
  removeContact(owner, peer) {
    this.exec(`DELETE FROM contacts WHERE owner=? AND peer=?`, owner, peer)
    this.exec(`DELETE FROM contacts WHERE owner=? AND peer=?`, peer, owner)
  }
  #putContact(owner, peer, state, t) {
    this.exec(
      `INSERT INTO contacts (owner, peer, state, created) VALUES (?,?,?,?)
       ON CONFLICT(owner,peer) DO UPDATE SET state=excluded.state`,
      owner, peer, state, t
    )
  }
  listContacts(owner, state) {
    const rows = state
      ? this.exec(`SELECT c.peer, c.state, c.created FROM contacts c WHERE c.owner=? AND c.state=?`, owner, state)
      : this.exec(`SELECT c.peer, c.state, c.created FROM contacts c WHERE c.owner=?`, owner)
    return rows.map(r => ({ ...this.pub(this.getUser(r.peer)), state: r.state, since: r.created })).filter(r => r.id)
  }

  // ---------------------------------------------------------------- rooms
  getRoom(id) {
    return this.exec(`SELECT * FROM rooms WHERE id=?`, id)[0] || null
  }
  dmKey(a, b) {
    return [a, b].sort().join('|')
  }
  getOrCreateDM(a, b) {
    const key = this.dmKey(a, b)
    const found = this.exec(`SELECT id FROM rooms WHERE dm_key=?`, key)[0]
    if (found) {
      // A hidden DM reappears for both when reused.
      this.exec(`UPDATE room_members SET hidden=0 WHERE room=?`, found.id)
      return found.id
    }
    const id = rid()
    const t = now()
    this.exec(`INSERT INTO rooms (id, kind, dm_key, created) VALUES (?,?,?,?)`, id, 'dm', key, t)
    this.#addMember(id, a, 'member', t)
    this.#addMember(id, b, 'member', t)
    return id
  }
  createGroup({ name, creator, members }) {
    const id = rid()
    const t = now()
    this.exec(`INSERT INTO rooms (id, kind, name, creator, created) VALUES (?,?,?,?,?)`, id, 'group', name || '群聊', creator, t)
    const all = new Set([creator, ...(members || [])])
    for (const u of all) this.#addMember(id, u, u === creator ? 'owner' : 'member', t)
    return id
  }
  #addMember(room, user, role, t) {
    this.exec(
      `INSERT INTO room_members (room, user, role, joined) VALUES (?,?,?,?)
       ON CONFLICT(room,user) DO UPDATE SET hidden=0`,
      room, user, role, t
    )
  }
  addMember(room, user) {
    this.#addMember(room, user, 'member', now())
  }
  removeMember(room, user) {
    this.exec(`DELETE FROM room_members WHERE room=? AND user=?`, room, user)
  }
  isMember(room, user) {
    return Boolean(this.exec(`SELECT 1 FROM room_members WHERE room=? AND user=?`, room, user)[0])
  }
  roomMembers(room) {
    return this.exec(`SELECT user FROM room_members WHERE room=?`, room).map(r => r.user)
  }
  roomMemberRows(room) {
    const rows = this.exec(`SELECT user, role, joined FROM room_members WHERE room=? ORDER BY joined`, room)
    return rows.map(r => ({ ...this.pub(this.getUser(r.user)), role: r.role, joined: r.joined })).filter(r => r.id)
  }
  membership(room, user) {
    return this.exec(`SELECT * FROM room_members WHERE room=? AND user=?`, room, user)[0] || null
  }
  setMemberFlag(room, user, flags) {
    const m = this.membership(room, user)
    if (!m) return
    this.exec(`UPDATE room_members SET muted=?, pinned=?, hidden=? WHERE room=? AND user=?`,
      flags.muted ?? m.muted, flags.pinned ?? m.pinned, flags.hidden ?? m.hidden, room, user)
  }
  markRead(room, user, ts) {
    this.exec(`UPDATE room_members SET last_read=MAX(last_read, ?) WHERE room=? AND user=?`, ts, room, user)
  }

  /** Conversation list for a user: enriched rooms sorted by latest activity. */
  listRoomsFor(user) {
    const mem = this.exec(
      `SELECT * FROM room_members WHERE user=? AND hidden=0`, user
    )
    const out = []
    for (const m of mem) {
      const room = this.getRoom(m.room)
      if (!room) continue
      const last = this.lastMessage(room.id)
      const unread = this.exec(
        `SELECT COUNT(*) AS n FROM messages WHERE room=? AND ts>? AND sender<>? AND type<>'system' AND state<>'revoked'`,
        room.id, m.last_read, user
      )[0].n
      const row = {
        id: room.id,
        kind: room.kind,
        name: room.name,
        avatar: room.avatar,
        pinned: Boolean(m.pinned),
        muted: Boolean(m.muted),
        lastRead: m.last_read,
        unread,
        last,
        ts: last ? last.ts : room.created
      }
      if (room.kind === 'dm') {
        const peerId = this.roomMembers(room.id).find(u => u !== user)
        row.peer = this.pub(this.getUser(peerId))
        row.peerRead = this.membership(room.id, peerId)?.last_read || 0
        if (row.peer) {
          row.name = row.peer.display
          row.avatar = row.peer.avatar
        }
      } else {
        row.count = this.roomMembers(room.id).length
      }
      out.push(row)
    }
    out.sort((a, b) => (b.pinned - a.pinned) || (b.ts - a.ts))
    return out
  }

  // ---------------------------------------------------------------- messages
  addMessage(m) {
    const id = m.id || rid()
    this.exec(
      `INSERT INTO messages (id, room, sender, ts, type, body, meta, reply_to, state)
       VALUES (?,?,?,?,?,?,?,?,?)
       ON CONFLICT(id) DO NOTHING`,
      id, m.room, m.sender, m.ts || now(), m.type || 'text', m.body || '',
      m.meta ? JSON.stringify(m.meta) : '', m.replyTo || '', m.state || 'sent'
    )
    return this.getMessage(id)
  }
  /** A sent message's key words (from src/assist.js), kept with its meta. */
  /** Key words for the message as it reads now (`body`): none for a wording since replaced. */
  setKeys(id, keys, body) {
    const m = this.getMessage(id)
    if (!m || m.state === 'revoked' || (body !== undefined && m.body !== body)) return null
    this.exec(`UPDATE messages SET meta=? WHERE id=?`, JSON.stringify({ ...(m.meta || {}), keys }), id)
    return this.getMessage(id)
  }
  getMessage(id) {
    const r = this.exec(`SELECT * FROM messages WHERE id=?`, id)[0]
    if (!r) return null
    const m = this.#msg(r)
    m.reactions = this.#reactionGroups(this.exec(`SELECT msg, user, emoji FROM reactions WHERE msg=? ORDER BY ts, rowid`, id))[id] || []
    return m
  }
  lastMessage(room) {
    const r = this.exec(`SELECT * FROM messages WHERE room=? ORDER BY ts DESC, id DESC LIMIT 1`, room)[0]
    return r ? this.#msg(r) : null
  }
  listMessages(room, { before, after, limit = 30 } = {}) {
    let rows
    if (before) {
      rows = this.exec(`SELECT * FROM messages WHERE room=? AND ts<? ORDER BY ts DESC, id DESC LIMIT ?`, room, before, limit)
      rows.reverse()
    } else if (after) {
      rows = this.exec(`SELECT * FROM messages WHERE room=? AND ts>? ORDER BY ts ASC, id ASC LIMIT ?`, room, after, limit)
    } else {
      rows = this.exec(`SELECT * FROM messages WHERE room=? ORDER BY ts DESC, id DESC LIMIT ?`, room, limit)
      rows.reverse()
    }
    const list = rows.map(r => this.#msg(r))
    if (!list.length) return list
    // One query per page, bounded by the page's time span rather than one
    // bound parameter per message (Durable Object SQL allows only 100).
    const groups = this.#reactionGroups(this.exec(
      `SELECT r.msg, r.user, r.emoji FROM reactions r JOIN messages m ON m.id = r.msg
       WHERE m.room=? AND m.ts BETWEEN ? AND ? ORDER BY r.ts, r.rowid`,
      room, list[0].ts, list[list.length - 1].ts
    ))
    for (const m of list) m.reactions = groups[m.id] || []
    return list
  }
  /** Set (or with no emoji, clear) one person's reaction to a message. */
  setReaction(id, user, emoji) {
    if (emoji) {
      this.exec(
        `INSERT INTO reactions (msg, user, emoji, ts) VALUES (?,?,?,?)
         ON CONFLICT(msg, user) DO UPDATE SET emoji=excluded.emoji, ts=excluded.ts`,
        id, user, emoji, now()
      )
    } else {
      this.exec(`DELETE FROM reactions WHERE msg=? AND user=?`, id, user)
    }
    return this.getMessage(id)
  }
  #reactionGroups(rows) {
    const out = {}
    for (const r of rows) {
      const list = (out[r.msg] ||= [])
      const group = list.find(g => g.emoji === r.emoji)
      if (group) group.users.push(r.user)
      else list.push({ emoji: r.emoji, users: [r.user] })
    }
    return out
  }
  setMessageState(id, state) {
    this.exec(`UPDATE messages SET state=? WHERE id=?`, state, id)
    return this.getMessage(id)
  }
  /**
   * A text message rewritten by its sender. Everyone in the conversation
   * can see that it was, and each earlier wording with when it was written
   * (meta.history, oldest first); key words of the old wording go.
   */
  editMessage(id, by, text, at = now()) {
    const m = this.getMessage(id)
    if (!m || m.sender !== by || m.type !== 'text' || m.state === 'revoked') return null
    if (m.body === text) return m
    const { keys, ...meta } = m.meta || {}
    const history = [...(meta.history || []), { text: m.body, ts: meta.editedAt || m.ts }]
    this.exec(`UPDATE messages SET body=?, meta=?, edited=edited+1 WHERE id=?`,
      text, JSON.stringify({ ...meta, history, editedAt: at }), id)
    return this.getMessage(id)
  }
  revokeMessage(id, by) {
    const m = this.getMessage(id)
    if (!m || m.sender !== by) return null
    this.exec(`UPDATE messages SET state='revoked', body='', meta='' WHERE id=?`, id)
    this.exec(`DELETE FROM reactions WHERE msg=?`, id)
    return this.getMessage(id)
  }
  #msg(r) {
    return {
      id: r.id,
      room: r.room,
      sender: r.sender,
      ts: r.ts,
      type: r.type,
      body: r.body,
      meta: r.meta ? JSON.parse(r.meta) : null,
      replyTo: r.reply_to || null,
      state: r.state,
      edited: r.edited || 0 // how many times its sender rewrote it
    }
  }

  // ---------------------------------------------------------------- push
  addSub(user, sub) {
    const id = rid()
    // One row per endpoint per user.
    this.exec(`DELETE FROM push_subs WHERE user=? AND json_extract(data,'$.endpoint')=?`, user, sub.endpoint)
    this.exec(`INSERT INTO push_subs (id, user, data, created) VALUES (?,?,?,?)`, id, user, JSON.stringify(sub), now())
    return id
  }
  listSubs(user) {
    return this.exec(`SELECT id, data FROM push_subs WHERE user=?`, user).map(r => ({ id: r.id, sub: JSON.parse(r.data) }))
  }
  /** Unread messages across the conversations a user hasn't hidden or muted (the app badge). */
  unreadTotal(user) {
    return this.exec(
      `SELECT COUNT(*) AS n FROM messages m JOIN room_members r ON r.room=m.room
       WHERE r.user=? AND r.hidden=0 AND r.muted=0 AND m.ts>r.last_read AND m.sender<>? AND m.type<>'system' AND m.state<>'revoked'`,
      user, user
    )[0].n
  }
  removeSub(id) {
    this.exec(`DELETE FROM push_subs WHERE id=?`, id)
  }
  removeSubByEndpoint(user, endpoint) {
    this.exec(`DELETE FROM push_subs WHERE user=? AND json_extract(data,'$.endpoint')=?`, user, endpoint)
  }
}
