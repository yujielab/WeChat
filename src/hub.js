// The whole backend is one Durable Object. It owns the account registry,
// contacts, rooms, messages and presence, runs the realtime WebSocket fan-out,
// and (in call.js) brokers Cloudflare Realtime sessions for voice/video.

import { Store, REACTIONS } from './store.js'
import {
  hashPassword, verifyPassword, mintToken, readToken,
  cookieHeader, clearCookieHeader, readCookie, b64url
} from './auth.js'
import { sendWebPush, generateVapid, declarativeMessage } from './push/webpush.js'
import { CallBroker } from './call.js'
import { handleMedia } from './media.js'
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

/** Free text from a client: a string on one line, at most `max` characters. */
export function cleanText(value, max) {
  if (typeof value !== 'string' && typeof value !== 'number') return ''
  const flat = String(value).replace(/[\u0000-\u001f\u007f\u2028\u2029]/g, ' ').trim()
  return Array.from(flat).slice(0, max).join('').trim()
}
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
      if (!user) return json({ ok: false, error: '未登录' }, 401)
      if (path.startsWith('/api/media/')) return await handleMedia(request, url, user, this)
      if (path === '/api/stickers' || path.startsWith('/api/stickers/')) return await this.stickers(request, url, user)
      if (path.startsWith('/api/')) return await this.api(request, url, user)
      if (path.startsWith('/rtc/')) return await this.calls.http(request, url, user)
      return json({ ok: false, error: 'not found' }, 404)
    } catch (err) {
      return json({ ok: false, error: err.message || '服务器错误' }, err.status || 500)
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
      return json({ ok: false, error: '邀请码不正确' }, 403)
    }
    username = String(username || '').trim()
    if (!USERNAME_RE.test(username)) return json({ ok: false, error: '用户名需为 3–24 位字母、数字或 _ . -' }, 400)
    if (typeof password !== 'string' || password.length < 6) return json({ ok: false, error: '密码至少 6 位' }, 400)
    if (this.store.getUserByUsername(username)) return json({ ok: false, error: '用户名已被占用' }, 409)
    const { salt, hash } = await hashPassword(password)
    const user = this.store.createUser({ username, display: cleanText(display, NAME_MAX) || username, salt, hash })
    return this.grant(user)
  }

  async login({ username, password }, ip) {
    const lock = this.fails.get(ip)
    if (lock && lock.until > Date.now()) {
      const retry = Math.ceil((lock.until - Date.now()) / 1000)
      return json({ ok: false, error: `尝试次数过多，请 ${Math.ceil(retry / 60)} 分钟后再试` }, 429, { 'retry-after': String(retry) })
    }
    const user = this.store.getUserByUsername(String(username || ''))
    const ok = user && await verifyPassword(password, user.salt, user.hash)
    if (!ok) {
      const n = (lock?.n || 0) + 1
      this.fails.set(ip, { n, until: n >= LOCKOUT_FAILS ? Date.now() + LOCKOUT_MS : 0 })
      return json({ ok: false, error: '用户名或密码不正确' }, 401)
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
      if (body.avatar !== undefined) {
        // Only a picture this account uploaded: anything else would have every
        // peer's device fetch an outside URL.
        const own = `/api/media/avatar/${user.id}/`
        const valid = body.avatar === '' || (typeof body.avatar === 'string' && body.avatar.startsWith(own) && /^[\w-]+$/.test(body.avatar.slice(own.length)))
        if (!valid) return json({ ok: false, error: '头像无效' }, 400)
        patch.avatar = body.avatar
      }
      const updated = this.store.setProfile(user.id, patch)
      this.fanoutToPeers(user.id, { t: 'profile', user: this.store.pub(updated) })
      return json({ ok: true, me: this.store.pub(updated) })
    }
    if (path === '/api/password' && method === 'POST') {
      if (!await verifyPassword(body.current, user.salt, user.hash)) return json({ ok: false, error: '当前密码不正确' }, 403)
      if (typeof body.next !== 'string' || body.next.length < 6) return json({ ok: false, error: '新密码至少 6 位' }, 400)
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
        stickers: stickersConfigured(this.env)
      })
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
      if (!peer || peer.id === user.id) return json({ ok: false, error: '找不到该用户' }, 404)
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
      if (!this.store.acceptContact(user.id, body.user)) return json({ ok: false, error: '没有待处理的请求' }, 400)
      this.sendToUser(body.user, { t: 'contacts-dirty' })
      return json({ ok: true, peer: this.store.pub(this.store.getUser(body.user)) })
    }
    if (path === '/api/contacts/remove' && method === 'POST') {
      this.store.removeContact(user.id, body.user)
      return json({ ok: true })
    }

    // --- rooms: open/create
    if (path === '/api/dm' && method === 'POST') {
      const peer = this.store.getUser(body.user) || this.store.getUserByUsername(body.username || '')
      if (!peer || peer.id === user.id) return json({ ok: false, error: '找不到该用户' }, 404)
      const roomId = this.store.getOrCreateDM(user.id, peer.id)
      this.sendToUser(peer.id, { t: 'rooms-dirty' })
      return json({ ok: true, room: this.roomFor(roomId, user.id) })
    }
    if (path === '/api/group' && method === 'POST') {
      const members = (Array.isArray(body.members) ? body.members : []).slice(0, GROUP_MAX).filter(id => typeof id === 'string' && this.store.getUser(id))
      const roomId = this.store.createGroup({ name: cleanText(body.name, NAME_MAX), creator: user.id, members })
      for (const m of members) this.sendToUser(m, { t: 'rooms-dirty' })
      this.systemMessage(roomId, `${user.display} 创建了群聊`)
      return json({ ok: true, room: this.roomFor(roomId, user.id) })
    }

    // --- a specific room: /api/room/:id[/members|/flags|/leave|/invite]
    if (seg[1] === 'room' && seg[2]) {
      const roomId = seg[2]
      if (!this.store.isMember(roomId, user.id)) return json({ ok: false, error: '无权访问' }, 403)
      const action = seg[3]
      if (!action && method === 'GET') {
        return json({ ok: true, room: this.roomFor(roomId, user.id), members: this.store.roomMemberRows(roomId).map(m => ({ ...m, online: this.isOnline(m.id) })) })
      }
      if (action === 'flags' && method === 'POST') {
        this.store.setMemberFlag(roomId, user.id, { muted: body.muted, pinned: body.pinned, hidden: body.hidden })
        return json({ ok: true })
      }
      if (action === 'read' && method === 'POST') {
        this.markRead(roomId, user.id, body.ts || Date.now())
        return json({ ok: true })
      }
      if (action === 'invite' && method === 'POST') {
        const room = this.store.getRoom(roomId)
        if (room.kind !== 'group') return json({ ok: false, error: '只能邀请进群聊' }, 400)
        const added = []
        for (const id of (Array.isArray(body.members) ? body.members : []).slice(0, GROUP_MAX)) {
          if (this.store.getUser(id) && !this.store.isMember(roomId, id)) {
            this.store.addMember(roomId, id)
            this.sendToUser(id, { t: 'rooms-dirty' })
            added.push(this.store.getUser(id).display)
          }
        }
        if (added.length) this.systemMessage(roomId, `${user.display} 邀请 ${added.join('、')} 加入群聊`)
        return json({ ok: true })
      }
      if (action === 'leave' && method === 'POST') {
        this.store.removeMember(roomId, user.id)
        this.systemMessage(roomId, `${user.display} 退出了群聊`)
        return json({ ok: true })
      }
    }

    // --- messages
    if (path === '/api/messages' && method === 'GET') {
      const roomId = url.searchParams.get('room')
      if (!this.store.isMember(roomId, user.id)) return json({ ok: false, error: '无权访问' }, 403)
      const before = Number(url.searchParams.get('before')) || undefined
      const after = Number(url.searchParams.get('after')) || undefined
      const limit = Math.min(100, Number(url.searchParams.get('limit')) || 30)
      return json({ ok: true, messages: this.store.listMessages(roomId, { before, after, limit }) })
    }
    if (path === '/api/messages' && method === 'POST') {
      return this.postMessage(body, user)
    }
    if (path === '/api/react' && method === 'POST') {
      const target = this.store.getMessage(String(body.id || ''))
      if (!target || !this.store.isMember(target.room, user.id)) return json({ ok: false, error: '找不到这条消息' }, 404)
      if (target.type === 'system' || target.state === 'revoked') return json({ ok: false, error: '这条消息无法回应' }, 400)
      const emoji = body.emoji ? String(body.emoji) : ''
      if (emoji && !REACTIONS.includes(emoji)) return json({ ok: false, error: '不支持这个回应' }, 400)
      const msg = this.store.setReaction(target.id, user.id, emoji)
      // A separate event: a reaction must not reorder the list or count as unread.
      this.fanoutToRoom(msg.room, { t: 'react', msg })
      return json({ ok: true, msg })
    }
    if (path === '/api/revoke' && method === 'POST') {
      const m = this.store.revokeMessage(body.id, user.id)
      if (!m) return json({ ok: false, error: '无法撤回' }, 400)
      this.fanoutToRoom(m.room, { t: 'msg', msg: m })
      return json({ ok: true, msg: m })
    }

    // --- push
    if (path === '/api/push/subscribe' && method === 'POST') {
      if (!body.sub?.endpoint) return json({ ok: false, error: '无效订阅' }, 400)
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
      if (!name) return json({ ok: false, error: '没有这个表情包' }, 400)
      let mine = this.myStickers(user).filter(n => !sameSet(n, name))
      if (body.add) {
        if (mine.length >= MAX_CHOSEN) return json({ ok: false, error: `最多 ${MAX_CHOSEN} 个表情包` }, 400)
        if (!(await readSet(this.env, bucket, name))?.stickers?.length) return json({ ok: false, error: '暂时取不到这个表情包' }, 502)
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
      return json({ ok: false, error: '暂时取不到这个表情' }, 502)
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

  /** Someone's packs: what they chose in the app, or the starting packs. */
  myStickers(user) {
    return chosenSets(this.env, this.store.kvGet(`stickers:${user.id}`))
  }

  // ---------------------------------------------------------------- message send + fan-out
  async postMessage(body, user) {
    const roomId = body.room
    if (!this.store.isMember(roomId, user.id)) return json({ ok: false, error: '无权发送' }, 403)
    const type = ['text', 'image', 'voice', 'video', 'file', 'drawing', 'sticker'].includes(body.type) ? body.type : 'text'
    if (type === 'text' && !String(body.text || '').trim()) return json({ ok: false, error: '不能发送空消息' }, 400)
    // A sticker is only a reference to one of the packs: its id, kind, emoji
    // and pack (so whoever receives it can load it).
    if (type === 'sticker') {
      const m = asObject(body.meta)
      if (!STICKER_ID.test(String(m.id || '')) || !STICKER_KINDS.includes(m.kind)) return json({ ok: false, error: '表情无效' }, 400)
      body.meta = { id: m.id, kind: m.kind, emoji: cleanText(m.emoji, 16), ...(SET_NAME.test(String(m.set || '')) && { set: m.set }) }
    }
    // A retry carries the same localId: if the first attempt landed (its
    // answer was lost on the way back), it gets that message, not a copy.
    const localKey = typeof body.localId === 'string' && body.localId ? `${user.id}:${roomId}:${body.localId.slice(0, 64)}` : ''
    const landed = localKey && this.sentLocal?.get(localKey)
    if (landed) return json({ ok: true, msg: landed, localId: body.localId })
    const msg = this.store.addMessage({
      room: roomId,
      sender: user.id,
      ts: Date.now(),
      type,
      body: type === 'text' ? String(body.text).slice(0, 8000) : (body.caption || ''),
      meta: body.meta || null,
      replyTo: body.replyTo || ''
    })
    this.markRead(roomId, user.id, msg.ts) // sending is reading
    // Others get the message; the sender's own devices get it tagged with the
    // localId so the optimistic bubble is replaced, not duplicated.
    for (const uid of this.store.roomMembers(roomId)) {
      if (uid === user.id) this.sendToUser(uid, { t: 'msg', msg, localId: body.localId || null })
      else this.sendToUser(uid, { t: 'msg', msg })
    }
    this.pushToOffline(roomId, user, msg)
    if (localKey) {
      this.sentLocal ||= new Map()
      this.sentLocal.set(localKey, msg)
      // Only recent sends can be retried; keep the memory small.
      if (this.sentLocal.size > 500) this.sentLocal.delete(this.sentLocal.keys().next().value)
    }
    return json({ ok: true, msg, localId: body.localId || null })
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
    const title = room.kind === 'dm' ? sender.display : (room.name || '群聊')
    const preview = room.kind === 'dm' ? this.preview(msg) : `${sender.display}: ${this.preview(msg)}`
    for (const uid of this.store.roomMembers(roomId)) {
      if (uid === sender.id || this.isOnline(uid)) continue
      if (this.store.membership(roomId, uid)?.muted) continue
      await this.pushTo(uid, {
        title, body: preview, tag: roomId, badge: this.store.unreadTotal(uid),
        link: `/?chat=${encodeURIComponent(roomId)}`
      }, { topic: roomId })
    }
  }

  preview(msg) {
    if (msg.type === 'text') return msg.body.slice(0, 120)
    return { image: '[图片]', drawing: '[手绘]', voice: '[语音]', video: '[视频]', file: '[文件]', call: '[通话]', sticker: `[表情]${msg.meta?.emoji ? ` ${msg.meta.emoji}` : ''}`, system: msg.body }[msg.type] || '[消息]'
  }
}
