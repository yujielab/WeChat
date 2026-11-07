// SQLite data layer for the messenger, running in the Hub Durable Object's
// embedded SQLite. `exec(sql, ...binds)` runs a statement and returns the rows
// as plain objects (empty for writes), so the same class is unit-testable
// against node:sqlite.

import { sharesReceipts } from './prefs.js'

const now = () => Date.now()
const parseList = v => { try { const a = JSON.parse(v); return Array.isArray(a) ? a : [] } catch { return [] } }
export const rid = () => crypto.randomUUID().replace(/-/g, '').slice(0, 20)
/** The tapbacks a message can carry; one per person, replaced when they pick another. */
export const REACTIONS = ['❤️', '😂', '👍', '😮', '😢', '🙏']
/** A text message can be rewritten by its sender for this long after sending, this many times (as in Messages). */
export const EDIT_WINDOW = 15 * 60 * 1000
export const EDIT_MAX = 5
/** A note lasts a day, and says this much at most. */
export const NOTE_TTL = 24 * 60 * 60 * 1000
export const NOTE_MAX = 60
/** Why `uid` can't rewrite message `m` as `text` now ('' when they can). */
export function editProblem(m, uid, text, at = now()) {
  if (!m || m.sender !== uid || m.type !== 'text' || m.state === 'revoked') return "Can't edit this message"
  if (!String(text).trim()) return "Can't change it to an empty message"
  if (at - m.ts > EDIT_WINDOW) return "Messages sent over 15 minutes ago can't be edited"
  if ((m.edited || 0) >= EDIT_MAX) return `Each message can be edited at most ${EDIT_MAX} times`
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
    // Added after the first release: a profile's cover, and a conversation
    // someone marked unread themselves.
    this.#column('users', 'cover', `TEXT NOT NULL DEFAULT ''`)
    this.#column('room_members', 'marked', 'INTEGER NOT NULL DEFAULT 0')
    // when last_read last moved on: the time a read receipt shows
    this.#column('room_members', 'read_at', 'INTEGER NOT NULL DEFAULT 0')
    // A client's own id for a message it sent (its localId): a send repeated
    // after a lost answer, or replayed after reconnecting, finds the message
    // that already landed instead of making a copy, even after the hub restarts.
    this.#column('messages', 'local_key', `TEXT NOT NULL DEFAULT ''`)
    s(`CREATE INDEX IF NOT EXISTS idx_msg_local ON messages (room, sender, local_key)`)
    // Moments: what someone shares with their friends — photos or a video and
    // a few words — with the likes and comments it gathers.
    s(`CREATE TABLE IF NOT EXISTS moments (
      id TEXT PRIMARY KEY,
      user TEXT NOT NULL,
      text TEXT NOT NULL DEFAULT '',
      media TEXT NOT NULL DEFAULT '[]', -- JSON [{ url, type: image | video, w, h }]
      created INTEGER NOT NULL
    )`)
    s(`CREATE INDEX IF NOT EXISTS idx_moments_user ON moments (user, created)`)
    // Who a moment is for: everyone (anyone signed in can find it in their
    // feed and on the author's page) or friends only. Those shared before
    // the choice existed were for friends.
    this.#column('moments', 'audience', `TEXT NOT NULL DEFAULT 'friends'`)
    // Friends it's with (a JSON list of ids), and who may comment on it:
    // everyone who sees it, the author's friends, or nobody.
    this.#column('moments', 'tags', `TEXT NOT NULL DEFAULT '[]'`)
    this.#column('moments', 'comments', `TEXT NOT NULL DEFAULT 'everyone'`)
    s(`CREATE TABLE IF NOT EXISTS moment_likes (
      moment TEXT NOT NULL,
      user TEXT NOT NULL,
      ts INTEGER NOT NULL,
      PRIMARY KEY (moment, user)
    )`)
    s(`CREATE TABLE IF NOT EXISTS moment_comments (
      id TEXT PRIMARY KEY,
      moment TEXT NOT NULL,
      user TEXT NOT NULL,
      text TEXT NOT NULL,
      ts INTEGER NOT NULL
    )`)
    s(`CREATE INDEX IF NOT EXISTS idx_moment_comments ON moment_comments (moment, ts)`)
    // A note: a line someone shares for their friends, above their photo in
    // the Messages list, for a day.
    s(`CREATE TABLE IF NOT EXISTS notes (
      user TEXT PRIMARY KEY,
      text TEXT NOT NULL,
      created INTEGER NOT NULL
    )`)
  }

  /** Add a column to a table made before it existed (once: then it's there). */
  #column(table, name, def) {
    try {
      this.exec(`SELECT ${name} FROM ${table} LIMIT 0`)
    } catch {
      this.exec(`ALTER TABLE ${table} ADD COLUMN ${name} ${def}`)
    }
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
      `SELECT id, username, display, avatar, bio, cover FROM users
       WHERE id<>? AND (uname_lc LIKE ? OR LOWER(display) LIKE ?) ORDER BY uname_lc LIMIT ?`,
      exclude || '', like, like, limit
    )
  }
  setProfile(id, { display, avatar, bio, cover }) {
    const u = this.getUser(id)
    if (!u) return null
    this.exec(`UPDATE users SET display=?, avatar=?, bio=?, cover=? WHERE id=?`,
      display ?? u.display, avatar ?? u.avatar, bio ?? u.bio, cover ?? u.cover, id)
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
    return { id: u.id, username: u.username, display: u.display, avatar: u.avatar, bio: u.bio, cover: u.cover || '' }
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

  // ---------------------------------------------------------------- memories
  /**
   * Every photo, video and drawing shared in `user`'s chats (by anyone, not
   * withdrawn), newest first: their memories, kept without anyone saving them.
   */
  memoriesFor(user, { before = Number.MAX_SAFE_INTEGER, limit = 60, type } = {}) {
    const types = type === 'photo' ? ['image'] : type === 'video' ? ['video'] : type === 'drawing' ? ['drawing'] : ['image', 'video', 'drawing']
    return this.exec(
      `SELECT m.* FROM messages m JOIN room_members rm ON rm.room = m.room AND rm.user = ?
       WHERE m.type IN (${types.map(() => '?').join(',')}) AND m.state <> 'revoked' AND m.ts < ?
       ORDER BY m.ts DESC, m.id DESC LIMIT ?`,
      user, ...types, before, limit
    ).map(r => this.#msg(r)).filter(m => typeof m.meta?.url === 'string' && m.meta.url.startsWith('/api/media/'))
  }

  // ---------------------------------------------------------------- notes
  /** Someone's note while it lasts (a day), or null. */
  noteOf(uid, at = now()) {
    const r = this.exec(`SELECT text, created FROM notes WHERE user=? AND created > ?`, uid, at - NOTE_TTL)[0]
    return r ? { text: r.text, created: r.created, expires: r.created + NOTE_TTL } : null
  }
  setNote(uid, text) {
    this.exec(`INSERT INTO notes (user, text, created) VALUES (?,?,?) ON CONFLICT(user) DO UPDATE SET text=excluded.text, created=excluded.created`, uid, text, now())
    return this.noteOf(uid)
  }
  clearNote(uid) {
    this.exec(`DELETE FROM notes WHERE user=?`, uid)
  }
  /** Friends' notes that last still, newest first. */
  notesFor(viewer, at = now()) {
    const friends = [...this.friendsOf(viewer)]
    if (!friends.length) return []
    return this.exec(
      `SELECT user, text, created FROM notes WHERE user IN (${friends.map(() => '?').join(',')}) AND created > ? ORDER BY created DESC`,
      ...friends, at - NOTE_TTL
    ).map(r => ({ user: this.pub(this.getUser(r.user)), text: r.text, created: r.created, expires: r.created + NOTE_TTL })).filter(n => n.user)
  }

  // ---------------------------------------------------------------- people
  /**
   * People `viewer` might want: `suggested`, to chat with (contacts with no
   * chat yet); `discover`, to add (friends of their friends, most in common
   * first, then people sharing moments for everyone, then those who joined
   * lately). Never themselves, anyone either of them blocked, anyone they
   * dismissed, and nobody twice.
   */
  peopleFor(viewer, { limit = 30 } = {}) {
    const friends = this.friendsOf(viewer)
    const blocked = this.blockedWith(viewer)
    const dismissed = new Set(this.kvGet(`dismissed:${viewer}`, []))
    const contacts = new Map(this.exec(`SELECT peer, state FROM contacts WHERE owner=?`, viewer).map(r => [r.peer, r.state]))
    const chatting = new Set(this.exec(
      `SELECT m2.user AS u FROM room_members m1
       JOIN rooms r ON r.id = m1.room AND r.kind = 'dm'
       JOIN room_members m2 ON m2.room = m1.room AND m2.user <> m1.user
       WHERE m1.user = ? AND m1.hidden = 0`, viewer).map(r => r.u))
    const taken = new Set([viewer, ...blocked])
    const out = (u, extra) => ({ ...this.pub(u), ...extra })

    const suggested = []
    for (const [peer, state] of contacts) {
      if (state !== 'accepted' || chatting.has(peer) || taken.has(peer) || dismissed.has(peer)) continue
      const u = this.getUser(peer)
      if (!u) continue
      taken.add(peer)
      suggested.push(out(u, { reason: 'Tap to chat' }))
      if (suggested.length >= 6) break
    }

    // Anyone you already know, or have asked, isn't someone to discover.
    for (const id of [...friends, ...contacts.keys(), ...chatting, ...dismissed]) taken.add(id)
    const discover = []
    const add = (id, reason, mutual = 0) => {
      if (taken.has(id) || discover.length >= limit) return
      const u = this.getUser(id)
      if (!u) return
      taken.add(id)
      discover.push(out(u, { reason, mutual }))
    }
    const mutual = new Map()
    for (const f of [...friends].slice(0, 60)) {
      for (const ff of this.friendsOf(f)) if (!taken.has(ff)) mutual.set(ff, (mutual.get(ff) || 0) + 1)
    }
    for (const [id, n] of [...mutual].sort((a, b) => b[1] - a[1])) add(id, n === 1 ? '1 mutual friend' : `${n} mutual friends`, n)
    for (const r of this.exec(`SELECT user, MAX(created) AS t FROM moments WHERE audience='everyone' GROUP BY user ORDER BY t DESC LIMIT 40`)) add(r.user, 'Shares moments')
    for (const r of this.exec(`SELECT id FROM users ORDER BY created DESC LIMIT 60`)) add(r.id, 'New on Cuven')
    return { suggested, discover }
  }
  /** `viewer` doesn't want `peer` suggested again (the last 300 kept). */
  dismissPerson(viewer, peer) {
    const list = this.kvGet(`dismissed:${viewer}`, []).filter(id => id !== peer)
    list.push(peer)
    this.kvSet(`dismissed:${viewer}`, list.slice(-300))
  }

  // ---------------------------------------------------------------- moments
  /**
   * Who sees someone's moments besides them: their accepted contacts and the
   * people they talk to one to one, less anyone either of them has blocked.
   * A one-to-one chat counts once both of them have written in it: anyone
   * may start one, and opening a chat with a stranger mustn't show them
   * what was shared only for friends.
   */
  friendsOf(uid) {
    const out = new Set()
    for (const r of this.exec(
      `SELECT DISTINCT m2.user AS u FROM room_members m1
       JOIN rooms r ON r.id = m1.room AND r.kind = 'dm'
       JOIN room_members m2 ON m2.room = m1.room AND m2.user <> m1.user
       WHERE m1.user = ?
         AND EXISTS (SELECT 1 FROM messages x WHERE x.room = m1.room AND x.sender = m1.user AND x.type <> 'system')
         AND EXISTS (SELECT 1 FROM messages y WHERE y.room = m1.room AND y.sender = m2.user AND y.type <> 'system')`, uid)) out.add(r.u)
    for (const r of this.exec(`SELECT peer FROM contacts WHERE owner=? AND state='accepted'`, uid)) out.add(r.peer)
    for (const r of this.exec(`SELECT peer FROM contacts WHERE owner=? AND state='blocked'`, uid)) out.delete(r.peer)
    for (const r of this.exec(`SELECT owner FROM contacts WHERE peer=? AND state='blocked'`, uid)) out.delete(r.owner)
    return out
  }
  /** Whether `viewer` sees everything `author` shares, friends-only included. */
  canSeeMoments(author, viewer) {
    return author === viewer || this.friendsOf(author).has(viewer)
  }
  /** Everyone either of them has blocked, or who blocked them. */
  blockedWith(uid) {
    const out = new Set()
    for (const r of this.exec(`SELECT peer FROM contacts WHERE owner=? AND state='blocked'`, uid)) out.add(r.peer)
    for (const r of this.exec(`SELECT owner FROM contacts WHERE peer=? AND state='blocked'`, uid)) out.add(r.owner)
    return out
  }
  /** Whether `viewer` may see this one moment: theirs, a friend's, or one for everyone (unless either blocked the other). */
  canSeeMoment(m, viewer) {
    if (!m) return false
    if (m.user === viewer) return true
    // Scheduled for later: only its author, until then.
    if (m.created > now()) return false
    if (this.blockedWith(viewer).has(m.user)) return false
    return m.audience === 'everyone' || this.friendsOf(m.user).has(viewer)
  }
  /** Whether a picture of `author`'s is in one of their moments for everyone. */
  isPublicMomentMedia(author, url) {
    // instr, not LIKE: the Durable Object's SQLite refuses LIKE patterns this long.
    return this.exec(`SELECT 1 AS ok FROM moments WHERE user=? AND audience='everyone' AND created <= ? AND instr(media, ?) > 0 LIMIT 1`, author, now(), JSON.stringify(url)).length > 0
  }
  /** A new moment; `at`, a time to come, schedules it (until then only its author sees it). */
  addMoment({ user, text = '', media = [], audience = 'everyone', tags = [], comments = 'everyone', at }) {
    const id = rid()
    this.exec(
      `INSERT INTO moments (id, user, text, media, created, audience, tags, comments) VALUES (?,?,?,?,?,?,?,?)`,
      id, user, text, JSON.stringify(media), at || now(), audience === 'friends' ? 'friends' : 'everyone',
      JSON.stringify(tags), ['friends', 'off'].includes(comments) ? comments : 'everyone'
    )
    return this.getMoment(id)
  }
  /** Whether `viewer` may comment on moment `m` (its author always may). */
  canComment(m, viewer) {
    if (m.user === viewer) return true
    if (m.comments === 'off') return false
    if (m.comments === 'friends') return this.friendsOf(m.user).has(viewer)
    return true
  }
  /**
   * The home feed for `viewer`: their own and their friends' moments, and
   * everyone's moments for everyone, newest first — never anyone either
   * of them has blocked.
   */
  feedFor(viewer, { before = Number.MAX_SAFE_INTEGER, limit = 20 } = {}) {
    const mine = [viewer, ...this.friendsOf(viewer)]
    const blocked = [...this.blockedWith(viewer)]
    return this.exec(
      `SELECT * FROM moments WHERE (user IN (${mine.map(() => '?').join(',')}) OR audience = 'everyone')
       ${blocked.length ? `AND user NOT IN (${blocked.map(() => '?').join(',')})` : ''}
       AND (created <= ? OR user = ?) AND created < ? ORDER BY created DESC, id DESC LIMIT ?`,
      ...mine, ...blocked, now(), viewer, before, limit
    ).map(r => ({ ...r, media: parseList(r.media) }))
  }
  /** One person's moments, newest first; only those for everyone when `publicOnly`; scheduled ones only with `scheduled` (their author). */
  momentsOf(author, { publicOnly = false, scheduled = false, before = Number.MAX_SAFE_INTEGER, limit = 20 } = {}) {
    return this.exec(
      `SELECT * FROM moments WHERE user=? ${publicOnly ? `AND audience='everyone'` : ''} ${scheduled ? '' : 'AND created <= ?'} AND created < ? ORDER BY created DESC, id DESC LIMIT ?`,
      author, ...(scheduled ? [] : [now()]), before, limit
    ).map(r => ({ ...r, media: parseList(r.media) }))
  }
  getMoment(id) {
    const r = this.exec(`SELECT * FROM moments WHERE id=?`, id)[0]
    return r ? { ...r, media: parseList(r.media) } : null
  }
  deleteMoment(id) {
    this.exec(`DELETE FROM moment_likes WHERE moment=?`, id)
    this.exec(`DELETE FROM moment_comments WHERE moment=?`, id)
    this.exec(`DELETE FROM moments WHERE id=?`, id)
  }
  /** The moments of these people, newest first, older than `before`. */
  momentsBy(users, { before = Number.MAX_SAFE_INTEGER, limit = 20 } = {}) {
    const ids = [...users]
    if (!ids.length) return []
    return this.exec(
      `SELECT * FROM moments WHERE user IN (${ids.map(() => '?').join(',')}) AND created < ? ORDER BY created DESC, id DESC LIMIT ?`,
      ...ids, before, limit
    ).map(r => ({ ...r, media: parseList(r.media) }))
  }
  countMoments(user, publicOnly = false, scheduled = false) {
    return this.exec(`SELECT COUNT(*) AS n FROM moments WHERE user=? ${publicOnly ? `AND audience='everyone'` : ''} ${scheduled ? '' : 'AND created <= ?'}`, user, ...(scheduled ? [] : [now()]))[0]?.n || 0
  }
  likeMoment(moment, user, on) {
    if (on) this.exec(`INSERT OR IGNORE INTO moment_likes (moment, user, ts) VALUES (?,?,?)`, moment, user, now())
    else this.exec(`DELETE FROM moment_likes WHERE moment=? AND user=?`, moment, user)
  }
  momentLikes(ids) {
    if (!ids.length) return []
    return this.exec(`SELECT moment, user, ts FROM moment_likes WHERE moment IN (${ids.map(() => '?').join(',')}) ORDER BY ts`, ...ids)
  }
  addMomentComment({ moment, user, text }) {
    const id = rid()
    this.exec(`INSERT INTO moment_comments (id, moment, user, text, ts) VALUES (?,?,?,?,?)`, id, moment, user, text, now())
    return this.exec(`SELECT * FROM moment_comments WHERE id=?`, id)[0]
  }
  getMomentComment(id) {
    return this.exec(`SELECT * FROM moment_comments WHERE id=?`, id)[0] || null
  }
  deleteMomentComment(id) {
    this.exec(`DELETE FROM moment_comments WHERE id=?`, id)
  }
  momentComments(ids) {
    if (!ids.length) return []
    return this.exec(`SELECT * FROM moment_comments WHERE moment IN (${ids.map(() => '?').join(',')}) ORDER BY ts`, ...ids)
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
    this.exec(`INSERT INTO rooms (id, kind, name, creator, created) VALUES (?,?,?,?,?)`, id, 'group', name || 'Group', creator, t)
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
    this.exec(`UPDATE room_members SET muted=?, pinned=?, hidden=?, marked=? WHERE room=? AND user=?`,
      flags.muted ?? m.muted, flags.pinned ?? m.pinned, flags.hidden ?? m.hidden, flags.marked ?? m.marked, room, user)
  }
  /** Reading a conversation also clears its own unread mark; reading
   *  further on than before records when (`at`). */
  markRead(room, user, ts, at = Date.now()) {
    this.exec(`UPDATE room_members SET read_at=CASE WHEN ? > last_read THEN ? ELSE read_at END, last_read=MAX(last_read, ?), marked=0 WHERE room=? AND user=?`, ts, at, ts, room, user)
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
      const count = this.exec(
        `SELECT COUNT(*) AS n FROM messages WHERE room=? AND ts>? AND sender<>? AND type<>'system' AND state<>'revoked'`,
        room.id, m.last_read, user
      )[0].n
      // Marked unread by hand: one, until it's read or something new arrives.
      const unread = count || (m.marked ? 1 : 0)
      // The earliest unread message that mentions this person (group @).
      const mention = room.kind === 'group' && count ? this.firstMention(room.id, user, m.last_read) : null
      const row = {
        id: room.id,
        kind: room.kind,
        name: room.name,
        avatar: room.avatar,
        pinned: Boolean(m.pinned),
        muted: Boolean(m.muted),
        lastRead: m.last_read,
        unread,
        marked: Boolean(m.marked && !count),
        mention,
        last,
        ts: last ? last.ts : room.created
      }
      if (room.kind === 'dm') {
        const peerId = this.roomMembers(room.id).find(u => u !== user)
        row.peer = this.pub(this.getUser(peerId))
        // How far they've read, and when — only if they let friends see it.
        const theirs = sharesReceipts(this.kvGet(`prefs:${peerId}`)) ? this.membership(room.id, peerId) : null
        row.peerRead = theirs?.last_read || 0
        row.peerReadAt = theirs?.read_at || 0
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
      `INSERT INTO messages (id, room, sender, ts, type, body, meta, reply_to, state, local_key)
       VALUES (?,?,?,?,?,?,?,?,?,?)
       ON CONFLICT(id) DO NOTHING`,
      id, m.room, m.sender, m.ts || now(), m.type || 'text', m.body || '',
      m.meta ? JSON.stringify(m.meta) : '', m.replyTo || '', m.state || 'sent', m.localKey || ''
    )
    // Something new brings a deleted conversation back, and replaces a
    // hand-made unread mark.
    if (m.type !== 'system') {
      this.exec(`UPDATE room_members SET hidden=0 WHERE room=? AND hidden=1`, m.room)
      this.exec(`UPDATE room_members SET marked=0 WHERE room=? AND user<>? AND marked=1`, m.room, m.sender)
    }
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
    if (m.replyTo) m.reply = this.replySnapshot(m.replyTo, m.room)
    return m
  }
  /** Who a message mentions (group @), as user ids. */
  mentions(m) {
    return Array.isArray(m?.meta?.mentions) ? m.meta.mentions : []
  }
  /** The first message after `since` in a room that mentions `user` (not taken back), or null. */
  firstMention(room, user, since = 0) {
    const rows = this.exec(
      `SELECT id, meta FROM messages WHERE room=? AND ts>? AND sender<>? AND state<>'revoked' AND instr(meta, ?)>0
       ORDER BY ts ASC, id ASC LIMIT 50`, room, since, user, `"${user}"`)
    return rows.find(r => { try { return (JSON.parse(r.meta).mentions || []).includes(user) } catch { return false } })?.id || null
  }
  /**
   * What a reply shows of the message it answers: who sent it, its kind and
   * a short preview (a photo's address for its thumbnail). A message taken
   * back says only that it was; one from another room, or gone, is null.
   */
  replySnapshot(id, room) {
    const r = this.exec(`SELECT id, room, sender, ts, type, body, meta, state FROM messages WHERE id=?`, id)[0]
    if (!r || r.room !== room) return null
    if (r.state === 'revoked') return { id: r.id, sender: r.sender, ts: r.ts, type: r.type, state: 'revoked' }
    const meta = r.meta ? JSON.parse(r.meta) : {}
    const out = { id: r.id, sender: r.sender, ts: r.ts, type: r.type, state: r.state, body: Array.from(r.body || '').slice(0, 120).join('') }
    if ((r.type === 'image' || r.type === 'drawing') && meta.url) out.url = meta.url
    if (r.type === 'sticker') out.emoji = meta.emoji || ''
    return out
  }
  /** The message a sender already sent with this localId in this room, if any. */
  findLocal(room, sender, localKey) {
    if (!localKey) return null
    const r = this.exec(`SELECT id FROM messages WHERE room=? AND sender=? AND local_key=? LIMIT 1`, room, sender, localKey)[0]
    return r ? this.getMessage(r.id) : null
  }
  /**
   * The texts of a room's messages, oldest first, for reading a conversation
   * or building a memory of it: no reactions, no replies, no per-message
   * lookups — just the words, so a long history costs one query.
   */
  listTexts(room, { limit = 100, before, sender } = {}) {
    const where = ["room=?", "type='text'", "state<>'revoked'", "body<>''"]
    const binds = [room]
    if (before !== undefined && before !== null) { where.push('ts<?'); binds.push(before) }
    if (sender) { where.push('sender=?'); binds.push(sender) }
    const rows = this.exec(
      `SELECT ts, sender, body FROM messages WHERE ${where.join(' AND ')} ORDER BY ts DESC, id DESC LIMIT ?`,
      ...binds, limit
    )
    return rows.reverse().map(r => ({ ts: r.ts, sender: r.sender, text: r.body }))
  }
  /**
   * Every text message a person sent, across their conversations, newest
   * first: what a style profile is counted from. The words are all they
   * wrote; nobody else's are included.
   */
  listTextsBy(user, { limit = 400, after } = {}) {
    const where = ["sender=?", "type='text'", "state<>'revoked'", "body<>''"]
    const binds = [user]
    if (after !== undefined && after !== null) { where.push('ts>?'); binds.push(after) }
    const rows = this.exec(
      `SELECT ts, room, body FROM messages WHERE ${where.join(' AND ')} ORDER BY ts DESC, id DESC LIMIT ?`,
      ...binds, limit
    )
    return rows.map(r => ({ ts: r.ts, room: r.room, text: r.body }))
  }
  /**
   * A time for the next message in a room: now, but never at or before the
   * last one, so the order the hub took them in is the order everyone sees
   * (and "before/after this ts" pages never split two messages sharing one).
   */
  nextTs(room) {
    const last = this.exec(`SELECT MAX(ts) AS ts FROM messages WHERE room=?`, room)[0]?.ts || 0
    return Math.max(now(), last + 1)
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
    for (const m of list) {
      m.reactions = groups[m.id] || []
      if (m.replyTo) m.reply = this.replySnapshot(m.replyTo, room)
    }
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
    const n = this.exec(
      `SELECT COUNT(*) AS n FROM messages m JOIN room_members r ON r.room=m.room
       WHERE r.user=? AND r.hidden=0 AND r.muted=0 AND m.ts>r.last_read AND m.sender<>? AND m.type<>'system' AND m.state<>'revoked'`,
      user, user
    )[0].n
    // A conversation marked unread counts once (new messages clear the mark).
    return n + this.exec(
      `SELECT COUNT(*) AS n FROM room_members r WHERE r.user=? AND r.hidden=0 AND r.muted=0 AND r.marked=1
       AND NOT EXISTS (SELECT 1 FROM messages m WHERE m.room=r.room AND m.ts>r.last_read AND m.sender<>? AND m.type<>'system' AND m.state<>'revoked')`,
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
