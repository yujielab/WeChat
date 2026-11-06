// The whole backend is one Durable Object. It owns the account registry,
// contacts, rooms, messages and presence, runs the realtime WebSocket fan-out,
// and (in call.js) brokers Cloudflare Realtime sessions for voice/video.

import { Store, REACTIONS, editProblem, NOTE_MAX } from './store.js'
import {
  hashPassword, verifyPassword, mintToken, readToken,
  cookieHeader, clearCookieHeader, readCookie, b64url
} from './auth.js'
import { sendWebPush, generateVapid, declarativeMessage } from './push/webpush.js'
import { CallBroker } from './call.js'
import { handleMedia } from './media.js'
import { assistConfigured, allowSuggestion, suggest, keywords, ask, transcribe, CONTEXT } from './assist.js'
import {
  readStyle, writeStyle, mergeStyle, styleOf, styleText, confidence, styleKey, digestKey,
  readDigest, writeDigest, digestPrompt, readDigestAnswer
} from './memory.js'
import { backdrop, readPrefs, patchPrefs } from './prefs.js'
import { routineKey, emptyRoutine, record, setLearning, summarizeRoutine, routineText, clampTz, localParts } from './routine.js'
import { insightRooms, analyze, photosToRead, describePhoto, allowRefresh } from './insights.js'
import { geocode, weatherAt } from './weather.js'
import { stickersConfigured, readSet, readSets, publicSet, catalog, warmSets, chosenSets, allowedName, allowedSets, sameSet, stickerFile, contentRange, STICKER_ID, STICKER_KINDS, SET_NAME, MAX_CHOSEN } from './stickers.js'

const json = (data, status = 200, headers = {}) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...headers }
  })

const USERNAME_RE = /^[a-zA-Z0-9_.-]{3,24}$/
const NAME_MAX = 40
const BIO_MAX = 120
const GROUP_MAX = 500
const RECENT_AVATARS = 8 // photos kept to go back to in the avatar editor
const MAX_AUDIO = 8 * 1024 * 1024 // a dictated clip, decoded from base64 (16 kHz mono WAV)
const DIGEST_EVERY = 10 * 60 * 1000 // how often a conversation's digest is rebuilt (10 minutes)

/** Free text from a client: a string on one line, at most `max` characters. */
export function cleanText(value, max) {
  if (typeof value !== 'string' && typeof value !== 'number') return ''
  const flat = String(value).replace(/[\u0000-\u001f\u007f\u2028\u2029]/g, ' ').trim()
  return Array.from(flat).slice(0, max).join('').trim()
}
/** Free text that may run over several lines (a moment's words): no control characters but line breaks, at most two blank lines in a row. */
export function cleanLines(value, max) {
  if (typeof value !== 'string') return ''
  const flat = value.replace(/\r\n?/g, '\n').replace(/[\u0000-\u0009\u000b-\u001f\u007f\u2028\u2029]/g, ' ').replace(/\n{3,}/g, '\n\n').trim()
  return Array.from(flat).slice(0, max).join('').trim()
}
const MOMENT_TEXT_MAX = 2000
const MOMENT_PHOTOS_MAX = 9
const COMMENT_MAX = 300
const ALT_MAX = 1000 // a photo's description, for people who can't see it
const TAGS_MAX = 10
const SCHEDULE_MIN = 60 * 1000 // a moment can be scheduled from a minute ahead…
const SCHEDULE_MAX = 30 * 24 * 60 * 60 * 1000 // …up to 30 days
/** A moment's pictures, as sent: only this account's own uploads; up to nine photos, or one video. Undefined when they won't do. */
export function momentMedia(list, uid) {
  if (list === undefined || list === null) return []
  if (!Array.isArray(list) || list.length > MOMENT_PHOTOS_MAX) return undefined
  const own = `/api/media/moment/${uid}/`
  const out = []
  for (const item of list) {
    const m = asObject(item)
    if (typeof m.url !== 'string' || !m.url.startsWith(own) || !/^[\w-]+$/.test(m.url.slice(own.length))) return undefined
    if (m.type !== 'image' && m.type !== 'video') return undefined
    const size = v => (Number.isFinite(Number(v)) && Number(v) > 0 ? Math.min(20000, Math.round(Number(v))) : 0)
    const alt = m.type === 'image' ? cleanText(m.alt, ALT_MAX) : ''
    out.push({ url: m.url, type: m.type, w: size(m.w), h: size(m.h), ...(alt && { alt }) })
  }
  if (out.some(m => m.type === 'video') && out.length > 1) return undefined
  return out
}
const parseTags = v => { try { const a = JSON.parse(v || '[]'); return Array.isArray(a) ? a.filter(x => typeof x === 'string') : [] } catch { return [] } }
/** A request body is a plain object, whatever was sent. */
const asObject = value => (value && typeof value === 'object' && !Array.isArray(value) ? value : {})
const LOCKOUT_FAILS = 6
const LOCKOUT_MS = 10 * 60 * 1000

export class Hub {
  constructor(ctx, env) {
    this.ctx = ctx
    this.env = env
    this.sql = (q, ...b) => ctx.storage.sql.exec(q, ...b).toArray()
    this.store = new Store(this.sql)
    this.secret = null
    this.fails = new Map() // ip -> { n, until }
    this.calls = new CallBroker(this)
    // The quarter hour last counted into each person's routine, and their
    // time zone, so opening the app and reading touch the store at most once
    // a quarter hour each (src/routine.js).
    this.routineSlot = new Map()
    this.routineTz = new Map()
  }

  // ---------------------------------------------------------------- secret
  async signingSecret() {
    if (this.secret) return this.secret
    let stored = this.store.kvGet('session_secret')
    if (!stored) {
      stored = b64url(crypto.getRandomValues(new Uint8Array(32)))
      this.store.kvSet('session_secret', stored)
    }
    this.secret = Uint8Array.from(atob(stored.replace(/-/g, '+').replace(/_/g, '/')), c => c.charCodeAt(0))
    return this.secret
  }

  async authed(request) {
    const token = readCookie(request)
    if (!token) return null
    const claims = await readToken(await this.signingSecret(), token)
    if (!claims) return null
    const user = this.store.getUser(claims.uid)
    if (!user || user.epoch !== claims.epoch) return null
    return user
  }

  // ---------------------------------------------------------------- routing
  async fetch(request) {
    const url = new URL(request.url)
    const path = url.pathname
    this.noteOrigin(url.origin)
    try {
      if (path.startsWith('/auth/')) return await this.auth(request, url)
      if (request.headers.get('upgrade') === 'websocket') return this.socket(request)
      const user = await this.authed(request)
      if (!user) return json({ ok: false, error: 'Not signed in' }, 401)
      if (path.startsWith('/api/media/')) return await handleMedia(request, url, user, this)
      if (path === '/api/stickers' || path.startsWith('/api/stickers/')) return await this.stickers(request, url, user)
      if (path.startsWith('/api/')) return await this.api(request, url, user)
      if (path.startsWith('/rtc/')) return await this.calls.http(request, url, user)
      return json({ ok: false, error: 'not found' }, 404)
    } catch (err) {
      return json({ ok: false, error: err.message || 'Server error' }, err.status || 500)
    }
  }

  // ---------------------------------------------------------------- auth routes
  async auth(request, url) {
    const path = url.pathname
    if (path === '/auth/status') {
      const user = await this.authed(request)
      return json({
        configured: true,
        needsCode: Boolean(this.env.SIGNUP_CODE),
        authed: Boolean(user),
        me: user ? this.store.pub(user) : null
      })
    }
    if (request.method !== 'POST') return json({ ok: false, error: 'method not allowed' }, 405)
    const ip = request.headers.get('cf-connecting-ip') || 'local'
    let body = {}
    try { body = asObject(await request.json()) } catch {}

    if (path === '/auth/register') return this.register(body, ip)
    if (path === '/auth/login') return this.login(body, ip)
    if (path === '/auth/logout') return json({ ok: true }, 200, { 'set-cookie': clearCookieHeader() })
    return json({ ok: false, error: 'not found' }, 404)
  }

  async register({ username, password, display, code }, ip) {
    if (this.env.SIGNUP_CODE && code !== this.env.SIGNUP_CODE) {
      return json({ ok: false, error: 'Invalid invite code' }, 403)
    }
    username = String(username || '').trim()
    if (!USERNAME_RE.test(username)) return json({ ok: false, error: 'Username must be 3–24 letters, digits, or _ . -' }, 400)
    if (typeof password !== 'string' || password.length < 6) return json({ ok: false, error: 'Password must be at least 6 characters' }, 400)
    if (this.store.getUserByUsername(username)) return json({ ok: false, error: 'Username is already taken' }, 409)
    const { salt, hash } = await hashPassword(password)
    const user = this.store.createUser({ username, display: cleanText(display, NAME_MAX) || username, salt, hash })
    return this.grant(user)
  }

  async login({ username, password }, ip) {
    const lock = this.fails.get(ip)
    if (lock && lock.until > Date.now()) {
      const retry = Math.ceil((lock.until - Date.now()) / 1000)
      return json({ ok: false, error: `Too many attempts, try again in ${Math.ceil(retry / 60)} minutes` }, 429, { 'retry-after': String(retry) })
    }
    const user = this.store.getUserByUsername(String(username || ''))
    const ok = user && await verifyPassword(password, user.salt, user.hash)
    if (!ok) {
      const n = (lock?.n || 0) + 1
      this.fails.set(ip, { n, until: n >= LOCKOUT_FAILS ? Date.now() + LOCKOUT_MS : 0 })
      return json({ ok: false, error: 'Incorrect username or password' }, 401)
    }
    this.fails.delete(ip)
    return this.grant(user)
  }

  async grant(user) {
    const token = await mintToken(await this.signingSecret(), { uid: user.id, epoch: user.epoch })
    return json({ ok: true, me: this.store.pub(user) }, 200, { 'set-cookie': cookieHeader(token) })
  }

  // ---------------------------------------------------------------- REST api
  async api(request, url, user) {
    const path = url.pathname
    const method = request.method
    const seg = path.split('/').filter(Boolean) // ['api', ...]
    const body = method === 'POST' ? asObject(await request.json().catch(() => ({}))) : null

    // --- self / profile
    if (path === '/api/me' && method === 'GET') {
      return json({ ok: true, me: this.store.pub(user), vapid: (await this.vapid()).publicKey })
    }
    if (path === '/api/profile' && method === 'POST') {
      const patch = {}
      if (body.display !== undefined) patch.display = cleanText(body.display, NAME_MAX) || user.username
      if (body.bio !== undefined) patch.bio = cleanText(body.bio, BIO_MAX)
      // Only a picture this account uploaded (or, for the cover, one of the
      // app's own): anything else would have every peer's device fetch an
      // outside URL.
      if (body.avatar !== undefined) {
        const own = `/api/media/avatar/${user.id}/`
        const valid = body.avatar === '' || (typeof body.avatar === 'string' && body.avatar.startsWith(own) && /^[\w-]+$/.test(body.avatar.slice(own.length)))
        if (!valid) return json({ ok: false, error: 'Invalid avatar' }, 400)
        patch.avatar = body.avatar
      }
      if (body.cover !== undefined) {
        const cover = backdrop(body.cover, 'cover', user.id)
        if (cover === undefined) return json({ ok: false, error: 'Invalid cover' }, 400)
        patch.cover = cover
      }
      // The photo it replaces is kept among the recent ones, to go back to.
      if (patch.avatar !== undefined && user.avatar && patch.avatar !== user.avatar) this.rememberAvatar(user.id, user.avatar)
      const updated = this.store.setProfile(user.id, patch)
      this.fanoutToPeers(user.id, { t: 'profile', user: this.store.pub(updated) })
      return json({ ok: true, me: this.store.pub(updated) })
    }
    // Photos this account used before (the avatar editor's Recent), newest first, not the one in use.
    if (path === '/api/profile/avatars' && method === 'GET') {
      const recent = (this.store.kvGet(`avatars:${user.id}`) || []).filter(u => u !== user.avatar)
      return json({ ok: true, recent })
    }
    // --- moments: photos or a video and a few words, for friends to see (js/views/moments.js)
    if (seg[1] === 'moments') {
      const res = await this.moments(seg, method, body, url, user)
      if (res) return res
    }
    if (path === '/api/password' && method === 'POST') {
      if (!await verifyPassword(body.current, user.salt, user.hash)) return json({ ok: false, error: 'Current password is incorrect' }, 403)
      if (typeof body.next !== 'string' || body.next.length < 6) return json({ ok: false, error: 'New password must be at least 6 characters' }, 400)
      const { salt, hash } = await hashPassword(body.next)
      this.store.setPassword(user.id, salt, hash)
      return this.grant(this.store.getUser(user.id))
    }

    // --- bootstrap (rooms + contacts + presence in one shot)
    if (path === '/api/bootstrap' && method === 'GET') {
      return json({
        ok: true,
        me: this.store.pub(user),
        rooms: this.store.listRoomsFor(user.id),
        contacts: this.store.listContacts(user.id),
        presence: this.onlineUids(),
        vapid: (await this.vapid()).publicKey,
        calls: this.calls.configured(),
        assist: assistConfigured(this.env),
        stickers: stickersConfigured(this.env),
        prefs: readPrefs(this.store.kvGet(`prefs:${user.id}`))
      })
    }
    // Backdrops for conversations and calls (src/prefs.js), the same on each
    // of this account's devices.
    if (path === '/api/prefs' && method === 'POST') {
      const r = patchPrefs(this.store.kvGet(`prefs:${user.id}`), body, { uid: user.id, isMember: id => this.store.isMember(id, user.id) })
      if (r.error) return json({ ok: false, error: r.error }, 400)
      this.store.kvSet(`prefs:${user.id}`, r.prefs)
      this.sendToUser(user.id, { t: 'prefs', prefs: r.prefs })
      return json({ ok: true, prefs: r.prefs })
    }
    if (path === '/api/rooms' && method === 'GET') {
      return json({ ok: true, rooms: this.store.listRoomsFor(user.id) })
    }

    // --- users / contacts
    if (path === '/api/users/search' && method === 'GET') {
      const q = url.searchParams.get('q') || ''
      if (q.length < 1) return json({ ok: true, users: [] })
      const users = this.store.searchUsers(q, user.id).map(u => ({ ...u, state: this.store.contactState(user.id, u.id) }))
      return json({ ok: true, users })
    }
    if (path === '/api/contacts' && method === 'GET') {
      return json({ ok: true, contacts: this.store.listContacts(user.id) })
    }
    if (path === '/api/contacts/add' && method === 'POST') {
      const peer = this.store.getUser(body.user) || this.store.getUserByUsername(body.username || '')
      if (!peer || peer.id === user.id) return json({ ok: false, error: 'User not found' }, 404)
      // Reciprocal request auto-accepts.
      if (this.store.contactState(user.id, peer.id) === 'pending_in') {
        this.store.acceptContact(user.id, peer.id)
      } else {
        this.store.requestContact(user.id, peer.id)
      }
      this.sendToUser(peer.id, { t: 'contacts-dirty' })
      return json({ ok: true, state: this.store.contactState(user.id, peer.id), peer: this.store.pub(peer) })
    }
    if (path === '/api/contacts/accept' && method === 'POST') {
      if (!this.store.acceptContact(user.id, body.user)) return json({ ok: false, error: 'No pending request' }, 400)
      this.sendToUser(body.user, { t: 'contacts-dirty' })
      return json({ ok: true, peer: this.store.pub(this.store.getUser(body.user)) })
    }
    if (path === '/api/contacts/remove' && method === 'POST') {
      this.store.removeContact(user.id, body.user)
      return json({ ok: true })
    }

    // --- people: who to chat with, who to add; a suggestion set aside
    if (path === '/api/people' && method === 'GET') {
      return json({ ok: true, ...this.store.peopleFor(user.id) })
    }
    // Your friends (contacts, and people you've written with one to one), by name: whom a moment can be with.
    if (path === '/api/friends' && method === 'GET') {
      const friends = [...this.store.friendsOf(user.id)].map(id => this.store.pub(this.store.getUser(id))).filter(Boolean)
      friends.sort((a, b) => (a.display || a.username).localeCompare(b.display || b.username))
      return json({ ok: true, friends })
    }
    if (path === '/api/people/dismiss' && method === 'POST') {
      if (typeof body.user !== 'string' || body.user === user.id || !this.store.getUser(body.user)) return json({ ok: false, error: 'User not found' }, 404)
      this.store.dismissPerson(user.id, body.user)
      return json({ ok: true })
    }

    // --- notes: a line for friends, above your photo in their Messages list, for a day
    if (path === '/api/notes' && method === 'GET') {
      return json({ ok: true, mine: this.store.noteOf(user.id), notes: this.store.notesFor(user.id) })
    }
    if (path === '/api/note' && (method === 'POST' || method === 'DELETE')) {
      const text = method === 'POST' ? cleanText(String(body.text ?? '').replace(/\s+/g, ' '), NOTE_MAX) : ''
      const note = text ? this.store.setNote(user.id, text) : (this.store.clearNote(user.id), null)
      for (const uid of [user.id, ...this.store.friendsOf(user.id)]) this.sendToUser(uid, { t: 'note', user: user.id })
      return json({ ok: true, mine: note })
    }

    // --- rooms: open/create
    if (path === '/api/dm' && method === 'POST') {
      const peer = this.store.getUser(body.user) || this.store.getUserByUsername(body.username || '')
      if (!peer || peer.id === user.id) return json({ ok: false, error: 'User not found' }, 404)
      const roomId = this.store.getOrCreateDM(user.id, peer.id)
      this.sendToUser(peer.id, { t: 'rooms-dirty' })
      return json({ ok: true, room: this.roomFor(roomId, user.id) })
    }
    if (path === '/api/group' && method === 'POST') {
      const members = (Array.isArray(body.members) ? body.members : []).slice(0, GROUP_MAX).filter(id => typeof id === 'string' && this.store.getUser(id))
      const roomId = this.store.createGroup({ name: cleanText(body.name, NAME_MAX), creator: user.id, members })
      for (const m of members) this.sendToUser(m, { t: 'rooms-dirty' })
      this.systemMessage(roomId, `${user.display} created the group`)
      return json({ ok: true, room: this.roomFor(roomId, user.id) })
    }

    // --- a specific room: /api/room/:id[/members|/flags|/leave|/invite]
    if (seg[1] === 'room' && seg[2]) {
      const roomId = seg[2]
      if (!this.store.isMember(roomId, user.id)) return json({ ok: false, error: 'No access' }, 403)
      const action = seg[3]
      if (!action && method === 'GET') {
        return json({ ok: true, room: this.roomFor(roomId, user.id), members: this.store.roomMemberRows(roomId).map(m => ({ ...m, online: this.isOnline(m.id) })) })
      }
      if (action === 'flags' && method === 'POST') {
        // unread: marked unread by hand (cleared by reading it, or by anything new).
        const marked = body.unread === undefined ? undefined : body.unread ? 1 : 0
        this.store.setMemberFlag(roomId, user.id, { muted: body.muted, pinned: body.pinned, hidden: body.hidden, marked })
        return json({ ok: true })
      }
      if (action === 'read' && method === 'POST') {
        this.markRead(roomId, user.id, body.ts || Date.now())
        this.learn(user.id, { kind: 'read', tz: clampTz(request.headers.get('x-tz')) })
        return json({ ok: true })
      }
      if (action === 'invite' && method === 'POST') {
        const room = this.store.getRoom(roomId)
        if (room.kind !== 'group') return json({ ok: false, error: 'Can only invite to a group' }, 400)
        const added = []
        for (const id of (Array.isArray(body.members) ? body.members : []).slice(0, GROUP_MAX)) {
          if (this.store.getUser(id) && !this.store.isMember(roomId, id)) {
            this.store.addMember(roomId, id)
            this.sendToUser(id, { t: 'rooms-dirty' })
            added.push(this.store.getUser(id).display)
          }
        }
        if (added.length) this.systemMessage(roomId, `${user.display} added ${added.join(', ')} to the group`)
        return json({ ok: true })
      }
      if (action === 'leave' && method === 'POST') {
        this.store.removeMember(roomId, user.id)
        this.systemMessage(roomId, `${user.display} left the group`)
        return json({ ok: true })
      }
    }

    // --- messages
    if (path === '/api/messages' && method === 'GET') {
      const roomId = url.searchParams.get('room')
      if (!this.store.isMember(roomId, user.id)) return json({ ok: false, error: 'No access' }, 403)
      const before = Number(url.searchParams.get('before')) || undefined
      const after = Number(url.searchParams.get('after')) || undefined
      const limit = Math.min(100, Number(url.searchParams.get('limit')) || 30)
      return json({ ok: true, messages: this.store.listMessages(roomId, { before, after, limit }) })
    }
    if (path === '/api/messages' && method === 'POST') {
      return this.postMessage(body, user, { tz: clampTz(request.headers.get('x-tz')) })
    }
    // Writing help (src/assist.js): read from sent messages only, never from
    // anyone's live typing preview. Quietly nothing when it isn't available.
    if (path === '/api/ai/suggest' && method === 'POST') {
      const roomId = String(body.room || '')
      const draft = String(body.draft ?? '').slice(0, 200)
      if (!assistConfigured(this.env) || !this.store.isMember(roomId, user.id) || /\n/.test(draft) || !allowSuggestion(user.id)) return json({ ok: true, text: '' })
      const history = this.store.listTexts(roomId, { limit: CONTEXT })
        .map(m => ({ mine: m.sender === user.id, text: m.text }))
      try {
        return json({ ok: true, text: await suggest(this.env, {
          history,
          draft,
          digest: this.digestFor(user.id, roomId),
          style: this.styleFor(user.id),
          routine: routineText(summarizeRoutine(this.store.kvGet(routineKey(user.id))))
        }) })
      } catch (err) {
        console.warn('assist suggest', err.message)
        return json({ ok: true, text: '' })
      }
    }
    // Voice-to-text (src/assist.js): a short dictated clip (16 kHz mono WAV,
    // base64) → the words in it, for the composer. Nothing is stored.
    if (path === '/api/ai/transcribe' && method === 'POST') {
      if (!assistConfigured(this.env)) return json({ ok: false, error: 'Voice input is unavailable' }, 400)
      const b64 = String(body.audio || '')
      let bytes
      try { bytes = b64 ? Uint8Array.from(atob(b64), c => c.charCodeAt(0)) : new Uint8Array() } catch { return json({ ok: false, error: 'Invalid audio' }, 400) }
      if (!bytes.length) return json({ ok: false, error: 'No audio' }, 400)
      if (bytes.length > MAX_AUDIO) return json({ ok: false, error: 'Recording too long' }, 413)
      if (!allowSuggestion(user.id)) return json({ ok: false, error: 'Too many requests, try again shortly' }, 429)
      try {
        return json({ ok: true, text: await transcribe(this.env, bytes) })
      } catch (err) {
        console.warn('transcribe', err.message)
        return json({ ok: false, error: "Couldn't transcribe that" }, 502)
      }
    }
    // The writing help's memory (src/memory.js): what it remembers about
    // you, and the way to forget it. Only your own words are kept, so this
    // is yours to read and yours to clear.
    if (path === '/api/ai/memory' && method === 'GET') {
      const style = readStyle(this.store, user.id)
      return json({
        ok: true,
        style: { words: style.words || [], endings: style.endings || [], messages: style.messages || 0, at: style.at || 0 },
        confidence: confidence(style),
        digests: this.digestsOf(user.id),
        routine: this.routineView(user.id)
      })
    }
    if (path === '/api/ai/memory' && method === 'DELETE') {
      this.store.kvDelete(styleKey(user.id))
      for (const d of this.digestsOf(user.id)) this.store.kvDelete(digestKey(user.id, d.room))
      // The routine starts over; learning stays as it was set.
      const off = Boolean(this.store.kvGet(routineKey(user.id))?.off)
      this.store.kvSet(routineKey(user.id), off ? setLearning(null, false) : emptyRoutine())
      this.routineSlot.delete(user.id)
      return json({ ok: true })
    }
    // Learning the routine and habits, on or off. Off forgets what was learned.
    if (path === '/api/ai/memory/routine' && method === 'POST') {
      if (typeof body.learn !== 'boolean') return json({ ok: false, error: 'Invalid parameter' }, 400)
      this.store.kvSet(routineKey(user.id), setLearning(this.store.kvGet(routineKey(user.id)), body.learn))
      this.routineSlot.delete(user.id)
      return json({ ok: true, routine: this.routineView(user.id) })
    }
    // Smart panels (src/insights.js): what each recent one-to-one conversation
    // says about the other person, read for you alone, and the weather where
    // they are (or where you are). Reading happens when asked (refresh), one
    // conversation at a time; the list answers at once from what was read.
    if (path === '/api/insights' && method === 'GET') {
      if (!assistConfigured(this.env)) return json({ ok: true, enabled: false, rooms: [], weather: null })
      const only = url.searchParams.get('room')
      const all = this.store.listRoomsFor(user.id)
      const rooms = only ? all.filter(r => r.id === only && r.kind === 'dm' && r.peer) : insightRooms(all)
      const list = rooms.map(r => this.insightOf(user.id, r))
      let weather = null
      if (!only) {
        try {
          weather = await this.insightWeather(request, list, url.searchParams.get('unit'))
        } catch (err) {
          console.warn('weather', err.message)
        }
      }
      return json({ ok: true, enabled: true, rooms: list, weather })
    }
    if (path === '/api/insights/refresh' && method === 'POST') {
      if (!assistConfigured(this.env)) return json({ ok: false, error: 'Insights are unavailable' }, 400)
      const roomId = String(body.room || '')
      const room = this.store.isMember(roomId, user.id) ? this.roomFor(roomId, user.id) : null
      if (!room || room.kind !== 'dm' || !room.peer) return json({ ok: false, error: "Can't read this chat" }, 400)
      if (!allowRefresh(user.id, roomId)) return json({ ok: true, ...this.insightOf(user.id, room), limited: true })
      const tz = Math.max(-840, Math.min(840, Math.round(Number(body.tz) || 0)))
      const now = Date.now()
      const messages = this.store.listMessages(roomId, { limit: 80 })
      // Their photos, each described once (and kept).
      const photos = new Map()
      await Promise.all(photosToRead(messages, user.id, now).map(async m => {
        let said = this.store.kvGet(`vision:${m.id}`)
        if (said === null) {
          try {
            said = await describePhoto(this.env, this.env.MEDIA, m)
          } catch (err) {
            console.warn('vision', err.message)
            return
          }
          this.store.kvSet(`vision:${m.id}`, said)
        }
        if (said) photos.set(m.id, said)
      }))
      try {
        const insight = await analyze(this.env, { messages, me: user.id, tzOffset: tz, now, photos })
        this.store.kvSet(`insight:${user.id}:${roomId}`, { last: room.last?.id || '', at: now, data: insight })
      } catch (err) {
        // Quietly what was read before (as writing help is quietly nothing).
        console.warn('insights', err.message)
        return json({ ok: true, ...this.insightOf(user.id, room), failed: true })
      }
      return json({ ok: true, ...this.insightOf(user.id, room) })
    }
    if (path === '/api/react' && method === 'POST') {
      const target = this.store.getMessage(String(body.id || ''))
      if (!target || !this.store.isMember(target.room, user.id)) return json({ ok: false, error: 'Message not found' }, 404)
      if (target.type === 'system' || target.state === 'revoked') return json({ ok: false, error: "Can't react to this message" }, 400)
      const emoji = body.emoji ? String(body.emoji) : ''
      if (emoji && !REACTIONS.includes(emoji)) return json({ ok: false, error: 'Unsupported reaction' }, 400)
      const msg = this.store.setReaction(target.id, user.id, emoji)
      // A separate event: a reaction must not reorder the list or count as unread.
      this.fanoutToRoom(msg.room, { t: 'react', msg })
      return json({ ok: true, msg })
    }
    // Rewriting a text message you sent: in place for everyone, like a
    // reaction (nothing new to read, nothing moves up the list).
    if (path === '/api/edit' && method === 'POST') {
      const target = this.store.getMessage(String(body.id || ''))
      const text = String(body.text ?? '').slice(0, 8000)
      if (target && target.sender === user.id && text === target.body) return json({ ok: true, msg: target })
      const problem = editProblem(target, user.id, text)
      if (problem) return json({ ok: false, error: problem }, 400)
      const msg = this.store.editMessage(target.id, user.id, text)
      this.fanoutToRoom(msg.room, { t: 'edit', msg })
      // Its key words follow again, for the new wording.
      if (assistConfigured(this.env)) {
        const work = this.markKeys(msg)
        this.ctx.waitUntil?.(work)
      }
      return json({ ok: true, msg })
    }
    if (path === '/api/revoke' && method === 'POST') {
      const m = this.store.revokeMessage(body.id, user.id)
      if (!m) return json({ ok: false, error: "Can't unsend" }, 400)
      this.fanoutToRoom(m.room, { t: 'msg', msg: m })
      return json({ ok: true, msg: m })
    }

    // --- push
    if (path === '/api/push/subscribe' && method === 'POST') {
      if (!body.sub?.endpoint) return json({ ok: false, error: 'Invalid subscription' }, 400)
      // The origin goes with it: a notification's link must be absolute.
      const id = this.store.addSub(user.id, { endpoint: body.sub.endpoint, keys: body.sub.keys, origin: url.origin })
      return json({ ok: true, id })
    }
    if (path === '/api/push/unsubscribe' && method === 'POST') {
      if (body.id) this.store.removeSub(body.id)
      else if (body.endpoint) this.store.removeSubByEndpoint(user.id, body.endpoint)
      return json({ ok: true })
    }

    return json({ ok: false, error: 'not found' }, 404)
  }

  // ---------------------------------------------------------------- stickers
  /**
   * Telegram sticker packs (src/stickers.js): your packs, the add list, adding
   * or removing one, and each sticker's file (img: the sticker or, with
   * ?thumb=1, its still picture; anim: an animated sticker's Lottie JSON),
   * from R2 or fetched once from Telegram.
   */
  async stickers(request, url, user) {
    const path = url.pathname
    const on = stickersConfigured(this.env)
    const bucket = this.env.MEDIA
    // Packs someone has (and the add list's covers) are fetched ahead of
    // time, behind the answer.
    const warm = (sets, opts) => {
      const work = warmSets(this.env, bucket, sets, opts)
      this.ctx.waitUntil?.(work)
    }
    if (request.method === 'GET' && path === '/api/stickers') {
      if (!on) return json({ ok: true, sets: [] })
      const sets = await readSets(this.env, bucket, this.myStickers(user))
      warm(sets)
      return json({ ok: true, sets: sets.map(publicSet) })
    }
    if (request.method === 'GET' && path === '/api/stickers/catalog') {
      if (!on) return json({ ok: true, packs: [] })
      const mine = this.myStickers(user)
      const sets = await readSets(this.env, bucket, allowedSets(this.env))
      warm(sets, { covers: true })
      return json({ ok: true, packs: catalog(sets, mine) })
    }
    if (request.method === 'POST' && path === '/api/stickers/mine' && on) {
      let body = {}
      try { body = asObject(await request.json()) } catch {}
      const name = allowedName(this.env, body.add || body.remove)
      if (!name) return json({ ok: false, error: 'No such sticker pack' }, 400)
      let mine = this.myStickers(user).filter(n => !sameSet(n, name))
      if (body.add) {
        if (mine.length >= MAX_CHOSEN) return json({ ok: false, error: `At most ${MAX_CHOSEN} sticker packs` }, 400)
        if (!(await readSet(this.env, bucket, name))?.stickers?.length) return json({ ok: false, error: "Can't load this sticker pack right now" }, 502)
        // The newest pack comes first, where the panel opens.
        mine = [name, ...mine]
      }
      this.store.kvSet(`stickers:${user.id}`, mine)
      const sets = await readSets(this.env, bucket, mine)
      if (body.add) warm(sets.filter(s => sameSet(s.name, name)))
      return json({ ok: true, sets: sets.map(publicSet) })
    }
    const [, , , what, id] = path.split('/')
    if (request.method !== 'GET' || !on || !['img', 'anim'].includes(what)) return json({ ok: false, error: 'not found' }, 404)
    let obj
    try {
      obj = await stickerFile(this.env, bucket, decodeURIComponent(id || ''), {
        set: url.searchParams.get('set'),
        thumb: url.searchParams.has('thumb'),
        anim: what === 'anim',
        range: request.headers
      })
    } catch (err) {
      console.warn('sticker file', id, err.message)
      return json({ ok: false, error: "Can't load this sticker right now" }, 502)
    }
    if (!obj) return json({ ok: false, error: 'not found' }, 404)
    const part = contentRange(obj)
    return new Response(obj.body, {
      status: part ? 206 : 200,
      headers: {
        'content-type': obj.httpMetadata?.contentType || 'application/octet-stream',
        'cache-control': 'private, max-age=31536000, immutable',
        'accept-ranges': 'bytes',
        ...(part && { 'content-range': part }),
        'content-security-policy': "default-src 'none'; sandbox; frame-ancestors 'none'",
        'x-content-type-options': 'nosniff'
      }
    })
  }

  /** What was last read from a conversation for this person, and whether it has moved on since. */
  insightOf(uid, room) {
    const kept = this.store.kvGet(`insight:${uid}:${room.id}`)
    return { room: room.id, peer: room.peer, stale: !kept || kept.last !== (room.last?.id || ''), at: kept?.at || 0, insight: kept?.data || null }
  }

  /** Weather where the person you talked to last says they are; otherwise where you are. */
  async insightWeather(request, list, unit) {
    const u = unit === 'f' ? 'f' : 'c'
    for (const r of list) {
      const city = r.insight?.city
      if (!city) continue
      const place = await geocode(city)
      const w = place && await weatherAt(place, { unit: u })
      if (w) return { ...w, place: place.name || city, who: r.peer.display, room: r.room }
    }
    let here = null
    try { here = JSON.parse(request.headers.get('x-viewer-place') || 'null') } catch {}
    if (!here) return null
    const w = await weatherAt(here, { unit: u })
    return w && { ...w, place: String(here.city || '').slice(0, 30), who: '', room: '' }
  }

  /** Someone's packs: what they chose in the app, or the starting packs. */
  myStickers(user) {
    return chosenSets(this.env, this.store.kvGet(`stickers:${user.id}`))
  }

  // ---------------------------------------------------------------- message send + fan-out
  async postMessage(body, user, { tz = null } = {}) {
    const roomId = body.room
    if (!this.store.isMember(roomId, user.id)) return json({ ok: false, error: 'Not allowed to send' }, 403)
    const type = ['text', 'image', 'voice', 'video', 'file', 'drawing', 'sticker'].includes(body.type) ? body.type : 'text'
    if (type === 'text' && !String(body.text || '').trim()) return json({ ok: false, error: "Can't send an empty message" }, 400)
    // A sticker is only a reference to one of the packs: its id, kind, emoji
    // and pack (so whoever receives it can load it).
    if (type === 'sticker') {
      const m = asObject(body.meta)
      if (!STICKER_ID.test(String(m.id || '')) || !STICKER_KINDS.includes(m.kind)) return json({ ok: false, error: 'Invalid sticker' }, 400)
      body.meta = { id: m.id, kind: m.kind, emoji: cleanText(m.emoji, 16), ...(SET_NAME.test(String(m.set || '')) && { set: m.set }) }
    }
    // A reply names a message in the same conversation; anything else is
    // dropped rather than refused, so the message itself still goes.
    const replyTo = typeof body.replyTo === 'string' && body.replyTo && this.store.replySnapshot(body.replyTo.slice(0, 64), roomId) ? body.replyTo.slice(0, 64) : ''
    // A retry, or a replay after reconnecting, carries the same localId: if
    // the first attempt landed (its answer was lost on the way back), it gets
    // that message, not a copy. Kept with the message, so a hub restart in
    // between doesn't forget it.
    const localKey = typeof body.localId === 'string' && body.localId ? body.localId.slice(0, 64) : ''
    const landed = this.store.findLocal(roomId, user.id, localKey)
    if (landed) return json({ ok: true, msg: landed, localId: body.localId, repeat: true })
    // Group @: the members a text names, kept with it (meta.mentions) so the
    // list can say Mentioned you and the push reaches them even when muted.
    // Only the server's own reading counts, never a list a client put in meta.
    let meta = body.meta && typeof body.meta === 'object' ? { ...body.meta } : null
    if (meta) delete meta.mentions
    if (type === 'text' && Array.isArray(body.mentions) && this.store.getRoom(roomId)?.kind === 'group') {
      const members = new Set(this.store.roomMembers(roomId))
      const named = [...new Set(body.mentions.filter(id => typeof id === 'string' && id !== user.id && members.has(id)))].slice(0, 50)
      if (named.length) meta = { ...meta, mentions: named }
    }
    if (meta && !Object.keys(meta).length) meta = null
    // How long the person took to answer: the message before theirs, if it was someone else's.
    const before = this.store.lastMessage(roomId)
    const answered = before && before.sender && before.sender !== user.id && before.type !== 'system' && before.state !== 'revoked' ? before.ts : null
    const msg = this.store.addMessage({
      room: roomId,
      sender: user.id,
      ts: this.store.nextTs(roomId),
      localKey,
      type,
      body: type === 'text' ? String(body.text).slice(0, 8000) : (body.caption || ''),
      meta,
      replyTo
    })
    this.markRead(roomId, user.id, msg.ts) // sending is reading
    // Others get the message; the sender's own devices get it tagged with the
    // localId so the optimistic bubble is replaced, not duplicated.
    for (const uid of this.store.roomMembers(roomId)) {
      if (uid === user.id) this.sendToUser(uid, { t: 'msg', msg, localId: body.localId || null })
      else this.sendToUser(uid, { t: 'msg', msg })
    }
    this.pushToOffline(roomId, user, msg)
    // Its key words follow a moment later, for everyone in the room.
    if (type === 'text' && assistConfigured(this.env)) {
      const work = this.markKeys(msg)
      this.ctx.waitUntil?.(work)
    }
    // Their routine and habits: when, what kind, to whom, how long, how soon.
    this.learn(user.id, {
      kind: type,
      room: roomId,
      text: type === 'text' ? msg.body : '',
      emoji: type === 'sticker' ? msg.meta?.emoji || '' : '',
      latency: answered ? msg.ts - answered : null,
      tz
    })
    // The writer's memory of their own words grows with what they sent.
    if (type === 'text') {
      const work = this.remember(user.id, roomId)
      this.ctx.waitUntil?.(work)
    }
    return json({ ok: true, msg, localId: body.localId || null })
  }

  async markKeys(msg) {
    try {
      const keys = await keywords(this.env, msg.body)
      if (!keys.length) return
      const updated = this.store.setKeys(msg.id, keys, msg.body)
      // Like a reaction: the message keeps its place and read state.
      if (updated) this.fanoutToRoom(msg.room, { t: 'keys', id: msg.id, room: msg.room, keys })
    } catch (err) {
      console.warn('assist keys', err.message)
    }
  }

  // ---------------------------------------------------------------- memory
  /**
   * The long-context memory of the writing help (src/memory.js): how this
   * person writes, and what this conversation was about before it scrolled
   * out of the window.
   *
   * Both are built from messages already sent. The style crosses
   * conversations but holds only the writer's own habitual words; the digest
   * never leaves the conversation it came from.
   */
  /**
   * How this person writes, as a hint for the model — or nothing, when there
   * is too little of it to be worth saying. A profile built from a handful
   * of messages would talk over the conversation rather than colour it, so
   * it is left out until there is enough of it to be a voice.
   */
  styleFor(userId) {
    const style = readStyle(this.store, userId)
    // A profile with nothing in it yet is not worth reading; build it.
    if (!style.messages) this.buildStyle(userId)
    const built = readStyle(this.store, userId)
    return confidence(built) === 'none' ? '' : styleText(built)
  }

  /**
   * What this conversation was about before it scrolled out of the window.
   * Read only: the digest is built in the background when messages are sent
   * (see remember), never here — a suggestion must not wait on a model.
   */
  digestFor(userId, roomId) {
    return readDigest(this.store, userId, roomId).text
  }

  /**
   * This person's digests, one per conversation. The key holds the person
   * and the conversation, so it is read apart: a digest is only ever the
   * one it belongs to.
   */
  digestsOf(userId) {
    const prefix = 'memory:digest:'
    const mine = `${prefix}${userId}:`
    return this.store.kvList(prefix)
      .filter(([k]) => k.startsWith(mine))
      .map(([k, v]) => ({ room: k.slice(mine.length), text: v?.text || '', at: v?.at || 0 }))
      .sort((a, b) => b.at - a.at)
  }

  /**
   * Recount the style from what this person has written. Cheap — it is
   * counting, not asking a model — so it runs whenever they send a message.
   *
   * Only what they wrote since the last count is read again; the rest is
   * already in the style. A full recount happens now and then, so a habit
   * that stopped being used can fall away.
   */
  buildStyle(userId) {
    const old = readStyle(this.store, userId)
    const since = old.counted || 0
    const fresh = since
      ? this.store.listTextsBy(userId, { limit: 200, after: since })
      : this.store.listTextsBy(userId, { limit: 400 })
    if (!fresh.length) return
    const counted = styleOf(fresh)
    // Every so often, count everything again from the start: a habit that is
    // no longer used should stop being remembered.
    const recount = !since || (old.messages || 0) > 200
    const merged = recount
      ? mergeStyle(old, styleOf(this.store.listTextsBy(userId, { limit: 400 })))
      : mergeStyle(old, counted)
    writeStyle(this.store, userId, merged)
  }

  /**
   * Compress what a conversation was about before the recent window, so a
   * suggestion still knows about a plan agreed three hundred messages ago.
   * This one asks the model, so it is bounded and only runs when it can.
   */
  async buildDigest(userId, roomId, { force = false } = {}) {
    if (!assistConfigured(this.env)) return
    const held = readDigest(this.store, userId, roomId)
    // A digest that is still fresh is left alone: rebuilding it on every
    // message would ask the model far more often than it is worth.
    if (!force && held.text && Date.now() - (held.at || 0) < DIGEST_EVERY) return
    // Only what is older than the window the suggestion already sees.
    const older = this.store.listTexts(roomId, { limit: 120, before: this.digestBoundary(roomId) })
    if (older.length < 8) return
    const lines = older.slice(-60).map(m => `${m.sender === userId ? 'Me' : 'Them'}: ${m.text.slice(0, 200)}`).join('\n')
    try {
      const raw = await ask(this.env, digestPrompt(lines), 300, { timeout: 15000 })
      const text = readDigestAnswer(raw)
      if (text) writeDigest(this.store, userId, roomId, text)
    } catch (err) {
      console.warn('assist digest', err.message)
    }
  }

  /**
   * The point where the recent window begins: everything older than it is
   * what the digest is about.
   */
  digestBoundary(roomId) {
    const recent = this.store.listTexts(roomId, { limit: CONTEXT })
    return recent[0]?.ts || 0
  }

  // ---------------------------------------------------------------- routine and habits
  /**
   * Count a moment of this person's own use into their routine and habits
   * (src/routine.js) — only where the memory can be seen and cleared (the
   * writing help is there). Opening the app and reading are counted once a
   * quarter hour, so the store is touched at most that often for them.
   */
  learn(userId, event = {}) {
    if (!assistConfigured(this.env)) return
    try {
      const now = Date.now()
      const passive = event.kind === 'open' || event.kind === 'read'
      const tz = clampTz(event.tz) ?? this.routineTz.get(userId)
      if (passive && tz !== undefined && this.routineSlot.get(userId) === localParts(now, tz ?? 0).slot) return
      const stored = this.store.kvGet(routineKey(userId))
      if (stored?.off) {
        this.routineTz.set(userId, tz ?? null)
        this.routineSlot.set(userId, localParts(now, tz ?? 0).slot)
        return
      }
      const next = record(stored, event, now)
      this.store.kvSet(routineKey(userId), next)
      this.routineTz.set(userId, next.tz)
      this.routineSlot.set(userId, next.slot)
    } catch (err) {
      console.warn('routine', err.message)
    }
  }

  /** The routine as the memory sheet shows it, with each conversation named as this person sees it. */
  routineView(userId) {
    const summary = summarizeRoutine(this.store.kvGet(routineKey(userId)))
    const rooms = new Map(this.store.listRoomsFor(userId).map(r => [r.id, r]))
    const peers = summary.peers
      .map(p => ({ band: p.band, name: rooms.get(p.room) ? (rooms.get(p.room).kind === 'dm' ? rooms.get(p.room).peer?.display : rooms.get(p.room).name) || '' : '' }))
      .filter(p => p.name)
    return { ...summary, peers }
  }

  // ---------------------------------------------------------------- moments
  /** The moments routes: the feed, someone's own, one; post, delete; like and comment. Null when none matches. */
  async moments(seg, method, body, url, user) {
    const store = this.store
    const before = Number(url.searchParams.get('before')) || undefined
    // A page of 20 at most (0: just the profile).
    const limit = url.searchParams.has('limit') ? Math.max(0, Math.min(20, Number(url.searchParams.get('limit')) || 0)) : 20
    // GET /api/moments — the home feed: yours, your friends', and everyone's moments for everyone, newest first.
    if (!seg[2] && method === 'GET') {
      return json({ ok: true, moments: limit ? this.momentsView(store.feedFor(user.id, { before, limit }), user.id) : [] })
    }
    // GET /api/moments/user/:id — someone's profile and the moments you may see: all of a friend's (and your
    // own), only the ones for everyone of anyone else, none where either of you blocked the other.
    if (seg[2] === 'user' && seg[3] && method === 'GET') {
      const author = store.getUser(seg[3])
      if (!author) return json({ ok: false, error: 'No such user' }, 404)
      const friend = store.canSeeMoments(author.id, user.id)
      const blocked = author.id !== user.id && store.blockedWith(user.id).has(author.id)
      const publicOnly = !friend
      return json({
        ok: true,
        user: { ...store.pub(author), joined: author.created },
        friend: friend && author.id !== user.id,
        visible: friend,
        count: blocked ? 0 : store.countMoments(author.id, publicOnly, author.id === user.id),
        friends: author.id === user.id ? store.friendsOf(author.id).size : undefined,
        moments: blocked || !limit ? [] : this.momentsView(store.momentsOf(author.id, { publicOnly, scheduled: author.id === user.id, before, limit }), user.id)
      })
    }
    // POST /api/moments — share one.
    if (!seg[2] && method === 'POST') {
      const text = cleanLines(body.text, MOMENT_TEXT_MAX)
      const media = momentMedia(body.media, user.id)
      if (media === undefined) return json({ ok: false, error: 'Up to 9 photos, or 1 video, of your own' }, 400)
      if (!text && !media.length) return json({ ok: false, error: 'Write something or add a photo' }, 400)
      // With friends of yours: up to ten, each once.
      const friends = store.friendsOf(user.id)
      const tags = body.tags === undefined ? [] : Array.isArray(body.tags) ? [...new Set(body.tags)] : null
      if (!tags || tags.length > TAGS_MAX || tags.some(id => typeof id !== 'string' || !friends.has(id))) return json({ ok: false, error: `Tag up to ${TAGS_MAX} of your friends` }, 400)
      // For later: from a minute ahead to 30 days.
      let at
      if (body.at !== undefined && body.at !== null) {
        at = Math.round(Number(body.at))
        if (!Number.isFinite(at) || at < Date.now() + SCHEDULE_MIN || at > Date.now() + SCHEDULE_MAX) return json({ ok: false, error: 'Schedule it between a minute and 30 days from now' }, 400)
      }
      const moment = store.addMoment({
        user: user.id, text, media, tags, at,
        audience: body.audience === 'friends' ? 'friends' : 'everyone',
        comments: ['friends', 'off'].includes(body.comments) ? body.comments : 'everyone'
      })
      // Your friends' feeds have something new (once it's out); your other devices too.
      for (const uid of [user.id, ...(at ? [] : friends)]) this.sendToUser(uid, { t: 'moment', id: moment.id, user: user.id })
      return json({ ok: true, moment: this.momentsView([moment], user.id)[0] })
    }
    const moment = seg[2] && seg[2] !== 'user' ? store.getMoment(seg[2]) : null
    if (seg[2] && seg[2] !== 'user' && !store.canSeeMoment(moment, user.id)) return json({ ok: false, error: 'This moment is gone' }, 404)
    if (!moment) return null
    const changed = () => {
      for (const uid of [moment.user, ...store.friendsOf(moment.user)]) this.sendToUser(uid, { t: 'moment-changed', id: moment.id })
    }
    // GET /api/moments/:id
    if (!seg[3] && method === 'GET') return json({ ok: true, moment: this.momentsView([moment], user.id)[0] })
    // DELETE /api/moments/:id — your own; its pictures go with it.
    if (!seg[3] && method === 'DELETE') {
      if (moment.user !== user.id) return json({ ok: false, error: "Can't delete someone else's moment" }, 403)
      store.deleteMoment(moment.id)
      const keys = moment.media.map(m => m.url.replace(/^\/api\/media\//, '')).filter(k => k.startsWith(`moment/${user.id}/`))
      if (keys.length) await this.env.MEDIA?.delete(keys).catch(() => {})
      for (const uid of [user.id, ...store.friendsOf(user.id)]) this.sendToUser(uid, { t: 'moment-deleted', id: moment.id })
      return json({ ok: true })
    }
    // POST /api/moments/:id/like { on }
    if (seg[3] === 'like' && method === 'POST') {
      store.likeMoment(moment.id, user.id, body.on !== false)
      changed()
      return json({ ok: true, moment: this.momentsView([moment], user.id)[0] })
    }
    // POST /api/moments/:id/comments { text }
    if (seg[3] === 'comments' && !seg[4] && method === 'POST') {
      const text = cleanText(body.text, COMMENT_MAX)
      if (!text) return json({ ok: false, error: 'Write a comment' }, 400)
      if (!store.canComment(moment, user.id)) return json({ ok: false, error: moment.comments === 'off' ? 'Comments are off for this moment' : 'Only friends can comment on this moment' }, 403)
      store.addMomentComment({ moment: moment.id, user: user.id, text })
      changed()
      return json({ ok: true, moment: this.momentsView([moment], user.id)[0] })
    }
    // DELETE /api/moments/:id/comments/:cid — your comment, or any on your moment.
    if (seg[3] === 'comments' && seg[4] && method === 'DELETE') {
      const c = store.getMomentComment(seg[4])
      if (!c || c.moment !== moment.id) return json({ ok: false, error: 'This comment is gone' }, 404)
      if (c.user !== user.id && moment.user !== user.id) return json({ ok: false, error: "Can't delete someone else's comment" }, 403)
      store.deleteMomentComment(c.id)
      changed()
      return json({ ok: true, moment: this.momentsView([moment], user.id)[0] })
    }
    return null
  }

  /**
   * Moments as `viewer` sees them. On a moment for friends, as in WeChat,
   * the likes and comments shown are only those of the viewer's own friends
   * (and the author's and their own): a friend of the author never sees what
   * strangers to them said. A moment for everyone shows them all.
   */
  momentsView(rows, viewer) {
    const store = this.store
    const ids = rows.map(r => r.id)
    const likes = store.momentLikes(ids)
    const comments = store.momentComments(ids)
    const friends = store.friendsOf(viewer)
    const people = new Map()
    const person = id => {
      if (!people.has(id)) {
        const u = store.getUser(id)
        people.set(id, u ? { id: u.id, username: u.username, display: u.display, avatar: u.avatar } : { id, username: '', display: 'Deleted account', avatar: '' })
      }
      return people.get(id)
    }
    const blocked = store.blockedWith(viewer)
    const now = Date.now()
    const circles = new Map()
    const friendsOfAuthor = uid => { if (!circles.has(uid)) circles.set(uid, uid === viewer ? friends : store.friendsOf(uid)); return circles.get(uid) }
    const seen = (uid, m) => !blocked.has(uid) && (m.audience === 'everyone' || uid === viewer || uid === m.user || friends.has(uid))
    return rows.map(m => ({
      id: m.id,
      user: { ...(store.pub(store.getUser(m.user)) || person(m.user)), friend: friends.has(m.user) },
      text: m.text,
      media: m.media,
      created: m.created,
      audience: m.audience === 'friends' ? 'friends' : 'everyone',
      // Who it's with (but nobody either of you blocked), who may comment, and whether it's still to come.
      tags: parseTags(m.tags).filter(id => !blocked.has(id)).map(person),
      commenting: ['friends', 'off'].includes(m.comments) ? m.comments : 'everyone',
      canComment: m.user === viewer || (m.comments !== 'off' && (m.comments !== 'friends' || friendsOfAuthor(m.user).has(viewer))),
      scheduled: m.created > now,
      mine: m.user === viewer,
      liked: likes.some(l => l.moment === m.id && l.user === viewer),
      likes: likes.filter(l => l.moment === m.id && seen(l.user, m)).map(l => person(l.user)),
      comments: comments.filter(c => c.moment === m.id && seen(c.user, m)).map(c => ({ id: c.id, user: person(c.user), text: c.text, created: c.ts, mine: c.user === viewer }))
    }))
  }

  /** Keep a replaced avatar among the recent ones: its own, newest first, a handful. */
  rememberAvatar(userId, url) {
    const own = `/api/media/avatar/${userId}/`
    if (typeof url !== 'string' || !url.startsWith(own)) return
    const list = [url, ...(this.store.kvGet(`avatars:${userId}`) || []).filter(u => u !== url)].slice(0, RECENT_AVATARS)
    this.store.kvSet(`avatars:${userId}`, list)
  }

  /** Keep a writer's memory in step with what they just sent. */
  async remember(userId, roomId) {
    try {
      this.buildStyle(userId)
      // The digest is only worth asking for once there is enough history.
      const recent = this.store.listTexts(roomId, { limit: CONTEXT })
      if (recent.length >= CONTEXT) await this.buildDigest(userId, roomId)
    } catch (err) {
      console.warn('assist memory', err.message)
    }
  }

  systemMessage(roomId, text) {
    const msg = this.store.addMessage({ room: roomId, sender: '', ts: Date.now(), type: 'system', body: text })
    this.fanoutToRoom(roomId, { t: 'msg', msg })
    return msg
  }

  roomFor(roomId, uid) {
    return this.store.listRoomsFor(uid).find(r => r.id === roomId) || null
  }

  markRead(roomId, uid, ts) {
    this.store.markRead(roomId, uid, ts)
    // Let the other DM side show a read receipt.
    const room = this.store.getRoom(roomId)
    if (room?.kind === 'dm') {
      const peer = this.store.roomMembers(roomId).find(u => u !== uid)
      if (peer) this.sendToUser(peer, { t: 'read', room: roomId, by: uid, ts })
    }
  }

  // ---------------------------------------------------------------- websockets
  socket(request) {
    const pair = new WebSocketPair()
    const [client, server] = Object.values(pair)
    this.ctx.acceptWebSocket(server)
    // uid is attached once the first authenticated frame arrives; but we can
    // authenticate from the cookie on the upgrade request directly.
    this.bindSocket(server, request)
    return new Response(null, { status: 101, webSocket: client })
  }

  async bindSocket(server, request) {
    const user = await this.authed(request)
    if (!user) {
      try { server.close(4001, 'unauthorized') } catch {}
      return
    }
    const wasOnline = this.isOnline(user.id)
    server.serializeAttachment({ uid: user.id })
    server.send(JSON.stringify({
      t: 'hello',
      me: this.store.pub(user),
      presence: this.onlineUids()
    }))
    // A call still ringing for this user (they may have come from its
    // notification) rings again on the device that just connected.
    this.calls.onConnect(user.id)
    // The app opened (or came back): a moment of their routine.
    this.learn(user.id, { kind: 'open', tz: clampTz(new URL(request.url).searchParams.get('tz')) })
    if (!wasOnline) this.fanoutToPeers(user.id, { t: 'presence', uid: user.id, online: true })
  }

  webSocketMessage(ws, data) {
    const att = ws.deserializeAttachment()
    if (!att?.uid) return
    let msg
    try { msg = JSON.parse(data) } catch { return }
    const uid = att.uid
    if (msg.t === 'ping') { ws.send('{"t":"pong"}'); return }
    if (msg.t === 'read' && msg.room && this.store.isMember(msg.room, uid)) {
      this.markRead(msg.room, uid, msg.ts || Date.now())
      this.learn(uid, { kind: 'read' })
      return
    }
    if (msg.t === 'typing' && msg.room && this.store.isMember(msg.room, uid)) {
      const text = typeof msg.text === 'string' ? msg.text.slice(0, 500) : ''
      // relay only to others, not back to the sender
      for (const u of this.store.roomMembers(msg.room)) if (u !== uid) this.sendToUser(u, { t: 'typing', room: msg.room, uid, text })
      return
    }
    if (msg.t === 'call') { this.calls.signal(uid, msg); return }
  }

  webSocketClose(ws) {
    const att = ws.deserializeAttachment()
    if (!att?.uid) return
    // Presence drops only when this user's last socket closed.
    if (!this.isOnline(att.uid, ws)) {
      this.fanoutToPeers(att.uid, { t: 'presence', uid: att.uid, online: false })
      this.calls.onDisconnect(att.uid)
    }
  }

  webSocketError(ws) { this.webSocketClose(ws) }

  // The one storage alarm: a call's grace period for someone who dropped off.
  async alarm() { this.calls.settle() }

  // --- presence helpers
  sockets() {
    return this.ctx.getWebSockets()
  }
  onlineUids() {
    const set = new Set()
    for (const ws of this.sockets()) {
      const a = ws.deserializeAttachment()
      if (a?.uid) set.add(a.uid)
    }
    return [...set]
  }
  isOnline(uid, except) {
    for (const ws of this.sockets()) {
      if (ws === except) continue
      if (ws.deserializeAttachment()?.uid === uid) return true
    }
    return false
  }

  // --- delivery
  sendToUser(uid, payload) {
    const data = JSON.stringify(payload)
    for (const ws of this.sockets()) {
      if (ws.deserializeAttachment()?.uid === uid) {
        try { ws.send(data) } catch {}
      }
    }
  }
  sendToSocket(ws, payload) {
    try { ws.send(JSON.stringify(payload)) } catch {}
  }
  fanoutToRoom(roomId, payload, exceptUid) {
    for (const uid of this.store.roomMembers(roomId)) {
      if (uid === exceptUid) continue
      this.sendToUser(uid, payload)
    }
    // The sender's other devices also want it (so their list updates).
    if (exceptUid) this.sendToUser(exceptUid, payload)
  }
  /** Notify everyone who shares a room with uid (contacts + co-members). */
  fanoutToPeers(uid, payload) {
    const peers = new Set()
    for (const m of this.sql(`SELECT DISTINCT room FROM room_members WHERE user=?`, uid)) {
      for (const other of this.store.roomMembers(m.room)) if (other !== uid) peers.add(other)
    }
    for (const c of this.store.listContacts(uid, 'accepted')) peers.add(c.id)
    for (const p of peers) this.sendToUser(p, payload)
  }

  // --- push
  /** The app's own origin, for links in notifications sent with no request at hand. */
  noteOrigin(origin) {
    if (!origin || origin === this.origin) return
    this.origin = origin
    if (this.store.kvGet('origin') !== origin) this.store.kvSet('origin', origin)
  }
  appOrigin(sub) {
    return sub?.origin || this.origin || (this.origin = this.store.kvGet('origin'))
  }

  /**
   * Push works with no setup: VAPID keys set as secrets win; otherwise the
   * hub makes a pair the first time one is needed and keeps it, so every
   * device subscribes to the same key from then on. Concurrent first calls
   * share one generation.
   */
  vapid() {
    this.vapidReady ||= (async () => {
      if (this.env.VAPID_PUBLIC_KEY && this.env.VAPID_PRIVATE_KEY) {
        return { publicKey: this.env.VAPID_PUBLIC_KEY, privateKey: this.env.VAPID_PRIVATE_KEY }
      }
      let keys = this.store.kvGet('vapid')
      if (!keys?.publicKey || !keys?.privateKey) {
        keys = await generateVapid()
        this.store.kvSet('vapid', keys)
      }
      return keys
    })().catch(err => {
      this.vapidReady = null
      throw err
    })
    return this.vapidReady
  }

  /**
   * Sends a Declarative Web Push notification to every device a user has
   * subscribed. `link` is a path in the app. Returns how many were accepted.
   * The sender identifies itself by the app's own address unless a subject
   * is set.
   */
  async pushTo(uid, { link, ...notification }, options) {
    const subs = this.store.listSubs(uid)
    if (!subs.length) return 0
    const keys = await this.vapid()
    let sent = 0
    for (const { id, sub } of subs) {
      const origin = this.appOrigin(sub)
      if (!origin) continue
      try {
        const vapid = { ...keys, subject: this.env.VAPID_SUBJECT || origin }
        const res = await sendWebPush(vapid, sub, declarativeMessage({ ...notification, navigate: origin + link }), options)
        if (res && (res.status === 404 || res.status === 410)) this.store.removeSub(id)
        else if (res?.ok) sent++
      } catch {}
    }
    return sent
  }

  async pushToOffline(roomId, sender, msg) {
    const room = this.store.getRoom(roomId)
    const title = room.kind === 'dm' ? sender.display : (room.name || 'Group')
    const preview = room.kind === 'dm' ? this.preview(msg) : `${sender.display}: ${this.preview(msg)}`
    const named = this.store.mentions(msg)
    for (const uid of this.store.roomMembers(roomId)) {
      if (uid === sender.id || this.isOnline(uid)) continue
      // Being mentioned gets through a muted group, and says so.
      const mentioned = named.includes(uid)
      if (this.store.membership(roomId, uid)?.muted && !mentioned) continue
      await this.pushTo(uid, {
        title: mentioned ? `${sender.display} mentioned you in ${title}` : title, body: preview, tag: roomId, badge: this.store.unreadTotal(uid),
        link: `/?chat=${encodeURIComponent(roomId)}`
      }, { topic: roomId })
    }
  }

  preview(msg) {
    if (msg.type === 'text') return msg.body.slice(0, 120)
    return { image: '[Photo]', drawing: '[Drawing]', voice: '[Voice]', video: '[Video]', file: '[File]', call: '[Call]', sticker: `[Sticker]${msg.meta?.emoji ? ` ${msg.meta.emoji}` : ''}`, system: msg.body }[msg.type] || '[Message]'
  }
}
