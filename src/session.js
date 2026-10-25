// The WeChat session Durable Object.
//
// One instance (named "main") owns the web-protocol session: it runs the QR
// login poll and the synccheck/webwxsync loop from alarms, stores contacts,
// chats and messages in SQLite, proxies media with the session cookies and
// pushes live updates to every open tab over WebSockets.

import { DurableObject } from 'cloudflare:workers'
import qrcode from 'qrcode-generator'
import { WxClient, WxError, newClientMsgId } from './wx/client.js'
import { QR_LOGIN_URL, STATUS_NOTIFY } from './wx/conf.js'
import { normContact, normMessage, mergeContact, memberName, isRoomId } from './wx/normalize.js'
import { Store, summaryOf } from './store.js'
import { sendWebPush, pushConfigured } from './push/webpush.js'

const LOOP_WALL_MS = 5 * 60 * 1000
const QR_TTL_MS = 5 * 60 * 1000
const AUTH_MAX_FAILS = 6
const AUTH_LOCK_MS = 10 * 60 * 1000
const HEARTBEAT_MS = 30 * 60 * 1000

const sleep = ms => new Promise(r => setTimeout(r, ms))

const json = (data, init = {}) =>
  new Response(JSON.stringify(data), {
    ...init,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...(init.headers || {}) }
  })

const fail = (status, error, extra = {}) => json({ ok: false, error, ...extra }, { status })

export class WeChatSession extends DurableObject {
  constructor(ctx, env) {
    super(ctx, env)
    this.env = env
    this.reqCount = 0
    this.reqBase = 0
    this.gen = 0
    this.authFails = new Map()
    this.echoes = new Map()
    this.pendingTexts = new Map()
    this.roomRefreshAt = new Map()
    ctx.blockConcurrencyWhile(async () => {
      this.store = new Store((q, ...b) => ctx.storage.sql.exec(q, ...b).toArray())
      this.state = this.store.get('state', { phase: 'idle' })
      this.contacts = this.store.loadContacts()
      this.client = this.makeClient(this.store.get('session'))
    })
  }

  // ================================================================ plumbing

  makeClient(session) {
    const mock = this.env.WX_MOCK_ORIGIN
    const rewrite = mock && /^http:\/\/(127\.0\.0\.1|localhost)(:\d+)?$/.test(mock)
      ? url => url.replace(/^https:\/\//, `${mock}/__host/`)
      : null
    return new WxClient(session, {
      rewrite,
      onRequest: () => this.reqCount++,
      loginMode: this.env.WX_LOGIN_MODE,
      clientVersion: this.env.WX_CLIENT_VERSION,
      extspam: this.env.WX_EXTSPAM
    })
  }

  get budgetLeft() {
    const limit = Number(this.env.ALARM_SUBREQUESTS) || 40
    return limit - (this.reqCount - this.reqBase)
  }

  setState(patch) {
    this.state = { ...this.state, ...patch }
    this.store.set('state', this.state)
    this.broadcast({ t: 'state', state: this.publicState() })
  }

  saveSession() {
    this.store.set('session', this.client.snapshot())
  }

  log(step, message, extra) {
    const entry = { at: Date.now(), step, message: String(message).slice(0, 300), ...(extra || {}) }
    const list = this.store.get('log', [])
    list.push(entry)
    this.store.set('log', list.slice(-40))
    console.log(`[wx] ${step}: ${entry.message}`)
  }

  publicState() {
    const s = this.state
    const me = this.me()
    return {
      phase: s.phase,
      uuid: s.phase === 'qr' || s.phase === 'scanned' ? s.uuid : undefined,
      qrAt: s.qrAt,
      avatar: s.phase === 'scanned' ? s.avatar : undefined,
      error: s.error || null,
      me: me ? { id: me.id, name: me.name, nick: me.nick } : null,
      lastSyncAt: s.lastSyncAt || 0,
      loginAt: s.loginAt || 0,
      contactsLoaded: Boolean(s.contactsLoaded),
      push: { configured: pushConfigured(this.env) }
    }
  }

  me() {
    const u = this.client.s.user
    return u ? normContact(u) : null
  }

  broadcast(obj) {
    const data = JSON.stringify(obj)
    for (const ws of this.ctx.getWebSockets()) {
      try {
        ws.send(data)
      } catch {
        // Socket already closing; the close handler cleans up.
      }
    }
  }

  async schedule(delay = 0) {
    await this.ctx.storage.setAlarm(Date.now() + Math.max(50, delay))
  }

  contactCtx() {
    return { self: this.client.s.user?.UserName || '', contacts: this.contacts }
  }

  upsertContacts(rawList, epoch = this.state.epoch || 0) {
    const changed = []
    for (const raw of rawList || []) {
      if (!raw?.UserName) continue
      const next = normContact(raw)
      const merged = mergeContact(this.contacts.get(next.id), next)
      this.contacts.set(merged.id, merged)
      this.store.putContact(merged, epoch)
      changed.push(merged)
    }
    return changed
  }

  // ================================================================ alarm loops

  async alarm() {
    this.reqBase = this.reqCount
    const gen = this.gen
    let delay = 0
    try {
      switch (this.state.phase) {
        case 'qr':
        case 'scanned':
          await this.loginLoop(gen)
          break
        case 'connecting':
          await this.resume()
          break
        case 'online':
          delay = await this.syncLoop(gen)
          break
        default:
          return
      }
    } catch (err) {
      this.log('alarm', err?.message || err)
      delay = 5000
    }
    if (['qr', 'scanned', 'connecting', 'online'].includes(this.state.phase)) await this.schedule(delay)
  }

  async startLogin() {
    this.gen++
    this.client = this.makeClient({ ...this.client.snapshot(), sid: '', skey: '', uin: '', passTicket: '', user: null, syncKey: null, syncCheckKey: '' })
    const uuid = await this.client.getUuid()
    this.setState({ phase: 'qr', uuid, qrAt: Date.now(), avatar: '', error: null })
    await this.schedule(0)
    return uuid
  }

  async loginLoop(gen) {
    const started = Date.now()
    let failures = 0
    while (gen === this.gen && (this.state.phase === 'qr' || this.state.phase === 'scanned')) {
      if (Date.now() - started > LOOP_WALL_MS || this.budgetLeft < 6) return
      if (Date.now() - this.state.qrAt > QR_TTL_MS) {
        this.setState({ phase: 'expired' })
        return
      }
      const uuid = this.state.uuid
      let r
      try {
        r = await this.client.checkLogin(uuid, this.state.phase === 'qr' ? 1 : 0)
        failures = 0
      } catch (err) {
        if (++failures > 4) {
          this.log('login', err.message)
          this.setState({ phase: 'expired', error: { message: '无法连接微信登录服务器', step: 'login', at: Date.now() } })
          return
        }
        await sleep(1500 * failures)
        continue
      }
      if (gen !== this.gen || uuid !== this.state.uuid) return
      if (r.code === 201) {
        if (this.state.phase !== 'scanned') this.setState({ phase: 'scanned', avatar: r.avatar || '' })
      } else if (r.code === 200) {
        this.setState({ phase: 'connecting' })
        await this.finishLogin(r.redirect)
        return
      } else if (r.code !== 408) {
        this.setState({ phase: 'expired' })
        return
      }
    }
  }

  async finishLogin(redirect) {
    try {
      const { mode, refused } = await this.client.completeLogin(redirect)
      for (const err of refused) this.log('newloginpage', `${err.mode} refused: ${err.message}`, { code: err.code })
      if (refused.length) this.log('login', `logged in via ${mode}`)
      this.saveSession()
      await this.initSession({ fresh: true })
    } catch (err) {
      this.log(err.step || 'login', err.message, { code: err.code })
      const tried = Array.isArray(err.detail) ? err.detail.map(d => d.mode) : undefined
      this.setState({
        phase: 'offline',
        error: { message: err.message, step: err.step, code: err.code, tried, at: Date.now() }
      })
    }
  }

  /** webwxinit + bookkeeping. Used after a fresh login and when resuming. */
  async initSession({ fresh }) {
    const prevUin = this.state.uin
    const data = await this.client.init()
    const uin = String(this.client.s.uin)
    if (prevUin && prevUin !== uin) {
      this.store.wipe()
      this.contacts = new Map()
    }
    const epoch = fresh ? (this.state.epoch || 0) + 1 : this.state.epoch || 1
    this.state.epoch = epoch
    this.upsertContacts([data.User, ...(data.ContactList || [])], epoch)
    const recent = String(data.ChatSet || '').split(',').filter(id => id && id !== data.User.UserName)
    recent.forEach((id, i) => this.store.setRank(id, i + 1))
    try {
      await this.client.statusNotify(STATUS_NOTIFY.INITED)
    } catch (err) {
      this.log('statusnotify', err.message)
    }
    this.saveSession()
    this.setState({
      phase: 'online',
      uin,
      epoch,
      loginAt: fresh ? Date.now() : this.state.loginAt || Date.now(),
      lastSyncAt: Date.now(),
      heartbeatAt: Date.now(),
      contactsLoaded: fresh ? false : this.state.contactsLoaded,
      contactSeq: fresh ? 0 : this.state.contactSeq || 0,
      needRemap: fresh && Boolean(prevUin) && prevUin === uin,
      error: null,
      avatar: '',
      uuid: ''
    })
    this.broadcast({ t: 'reload' })
  }

  /** After the object restarted with a saved session: re-init without a new scan. */
  async resume() {
    if (!this.client.s.sid) {
      this.setState({ phase: 'idle' })
      return
    }
    try {
      await this.initSession({ fresh: false })
    } catch (err) {
      this.log('resume', err.message, { code: err.code })
      if (err.logout || err.code === 1100 || err.code === 1101) return this.goOffline('会话已失效，请重新扫码登录')
      this.setState({ error: { message: err.message, step: 'resume', at: Date.now() } })
      await sleep(3000)
    }
  }

  goOffline(reason) {
    this.gen++
    this.client.s.sid = ''
    this.client.s.skey = ''
    this.saveSession()
    this.setState({ phase: 'offline', error: { message: reason, step: 'sync', at: Date.now() } })
    this.notifyAll({ title: '微信已退出', body: reason, tag: 'session' }).catch(() => {})
  }

  async loadContacts() {
    let seq = this.state.contactSeq || 0
    do {
      if (this.budgetLeft < 10) return false
      const page = await this.client.getContactPage(seq)
      this.upsertContacts(page.list)
      seq = page.seq
      this.state.contactSeq = seq
      this.store.set('state', this.state)
    } while (seq)

    // Group member lists come from batchgetcontact, 50 rooms at a time.
    const rooms = [...this.contacts.values()].filter(c => c.room && !c.stale && !c.members?.length)
    for (let i = 0; i < rooms.length; i += 50) {
      if (this.budgetLeft < 10) return false
      const list = await this.client.batchGetContacts(rooms.slice(i, i + 50).map(r => ({ UserName: r.id, EncryChatRoomId: '' })))
      this.upsertContacts(list)
    }

    if (this.state.needRemap) {
      const moved = this.store.remapAfterLogin(this.state.epoch)
      this.contacts = this.store.loadContacts()
      this.log('remap', `carried over ${moved} chats`)
    }
    this.setState({ contactsLoaded: true, needRemap: false, contactSeq: 0 })
    this.broadcast({ t: 'contacts' })
    this.broadcast({ t: 'reload' })
    return true
  }

  async syncLoop(gen) {
    const started = Date.now()
    let failures = this.state.syncFailures || 0
    if (!this.state.contactsLoaded) {
      try {
        if (!(await this.loadContacts())) return 0
      } catch (err) {
        if (err.logout) return this.goOffline('登录已失效，请重新扫码登录')
        this.log('contacts', err.message)
      }
    }
    while (gen === this.gen && this.state.phase === 'online') {
      if (Date.now() - started > LOOP_WALL_MS || this.budgetLeft < 8) return 0
      const t0 = Date.now()
      try {
        const { selector } = await this.client.syncCheck()
        if (selector !== 0) {
          let data
          let rounds = 0
          do {
            data = await this.client.sync()
            await this.applySync(data)
          } while (data.ContinueFlag && ++rounds < 5 && this.budgetLeft > 6)
          this.saveSession()
        }
        failures = 0
        this.state.lastSyncAt = Date.now()
        this.state.syncFailures = 0
        this.store.set('state', this.state)
        if (Date.now() - (this.state.heartbeatAt || 0) > HEARTBEAT_MS) {
          this.state.heartbeatAt = Date.now()
          this.client.statusNotify(STATUS_NOTIFY.INITED).catch(() => {})
        }
      } catch (err) {
        if (gen !== this.gen) return 0
        if (err instanceof WxError && err.logout) {
          this.log('sync', err.message, { code: err.code })
          this.goOffline(err.message)
          return 0
        }
        failures++
        this.state.syncFailures = failures
        this.store.set('state', this.state)
        this.log('sync', err.message, { code: err.code, failures })
        if (failures % 4 === 0) {
          // Same recovery wechat4u uses: re-run webwxinit to refresh keys.
          try {
            await this.client.init()
            this.saveSession()
          } catch (e) {
            if (e.logout) return this.goOffline('登录已失效，请重新扫码登录')
          }
        }
        return Math.min(60000, 2000 * 2 ** Math.min(failures, 5))
      }
      // A selector that never settles would otherwise spin; keep a floor.
      const spent = Date.now() - t0
      if (spent < 1000) await sleep(1000 - spent)
    }
    return 0
  }

  async applySync(data) {
    const ctx = this.contactCtx()
    const changed = []
    if (data.ModContactList?.length) changed.push(...this.upsertContacts(data.ModContactList))
    if (data.ModChatRoomMemberList?.length) changed.push(...this.upsertContacts(data.ModChatRoomMemberList))
    for (const d of data.DelContactList || []) {
      if (d?.UserName && this.contacts.has(d.UserName)) {
        const c = { ...this.contacts.get(d.UserName), friend: false }
        this.contacts.set(c.id, c)
        this.store.putContact(c, this.state.epoch)
      }
    }

    const raws = data.AddMsgList || []
    await this.resolveUnknown(raws, ctx.self)

    const added = []
    const touched = new Set()
    const openChats = this.visibleChats()
    for (const raw of raws) {
      const m = normMessage(raw, this.contactCtx())
      if (m.kind === 'notify') {
        this.handleNotify(m, touched)
        continue
      }
      if (!m.id || m.type === 'ignore') continue
      if (m.type === 'recall') {
        const target = m.target && this.store.getMessage(m.target)
        if (target) {
          const next = this.store.updateMessage(target.id, { type: 'recalled', text: m.text, recalled: m.text })
          this.broadcast({ t: 'msg', msg: next })
          touched.add(target.chat)
          continue
        }
        m.type = 'system'
      }
      if (m.out && m.type === 'text') {
        // Our own send echoed back before the send call returned.
        const key = `${m.chat}\u0000${m.text}`
        const localId = this.pendingTexts.get(key)
        if (localId) {
          this.echoes.set(m.id, localId)
          continue
        }
      }
      const isOpen = openChats.has(m.chat)
      if (!this.store.addMessage(m, { countUnread: !isOpen })) continue
      this.store.ensureChat(m.chat)
      added.push(m)
      touched.add(m.chat)
    }
    for (const m of added) this.broadcast({ t: 'msg', msg: m })
    if (changed.length) this.broadcast({ t: 'contacts' })
    if (touched.size) this.broadcast({ t: 'chats', chats: [...touched].map(id => this.chatView(id)).filter(Boolean) })
    const incoming = added.filter(m => !m.out && m.type !== 'system' && !openChats.has(m.chat))
    if (incoming.length) await this.pushMessages(incoming)
  }

  /** Fetch contact details for chats / group senders we have not seen yet. */
  async resolveUnknown(raws, self) {
    const need = new Map()
    for (const raw of raws) {
      const type = Number(raw.MsgType)
      const ids = type === 51
        ? String(raw.StatusNotifyUserName || '').split(',')
        : [raw.FromUserName === self ? raw.ToUserName : raw.FromUserName]
      for (const id of ids) {
        if (!id || id === self) continue
        const c = this.contacts.get(id)
        if (!c) need.set(id, { UserName: id, EncryChatRoomId: '' })
        else if (c.room && type !== 51) {
          const sender = /^(@[0-9A-Za-z]+):<br/.exec(raw.Content || '')?.[1]
          const missing = !c.members?.length || (sender && !c.members.some(x => x.id === sender))
          const last = this.roomRefreshAt.get(id) || 0
          if (missing && Date.now() - last > 60000) {
            this.roomRefreshAt.set(id, Date.now())
            need.set(id, { UserName: id, EncryChatRoomId: '' })
          }
        }
      }
    }
    const list = [...need.values()]
    for (let i = 0; i < list.length && this.budgetLeft > 6; i += 50) {
      try {
        this.upsertContacts(await this.client.batchGetContacts(list.slice(i, i + 50)))
      } catch (err) {
        this.log('batchgetcontact', err.message)
        break
      }
    }
  }

  handleNotify(n, touched) {
    if (n.code === STATUS_NOTIFY.SYNC_CONV) {
      n.targets.forEach((id, i) => {
        if (id !== this.client.s.user?.UserName) this.store.setRank(id, i + 1)
      })
      this.broadcast({ t: 'reload' })
    } else if (n.code === STATUS_NOTIFY.ENTER_SESSION || n.code === STATUS_NOTIFY.READ) {
      // Read on the phone: clear the badge here too.
      const row = this.store.chatRow(n.chat)
      if (row?.unread) {
        this.store.setUnread(n.chat, 0)
        touched.add(n.chat)
      }
    }
  }

  visibleChats() {
    const open = new Set()
    for (const ws of this.ctx.getWebSockets()) {
      const a = ws.deserializeAttachment() || {}
      if (a.visible && a.chat) open.add(a.chat)
    }
    return open
  }

  // ================================================================ views

  contactView(c, full = false) {
    if (!c) return null
    const v = {
      id: c.id,
      name: c.name,
      nick: c.nick,
      remark: c.remark,
      room: c.room,
      biz: c.biz,
      special: c.special,
      friend: c.friend,
      pinned: c.pinned,
      muted: c.muted,
      py: c.py,
      pyi: c.pyi,
      count: c.count,
      stale: Boolean(c.stale)
    }
    if (full) {
      v.alias = c.alias
      v.sig = c.sig
      v.region = c.region
      v.sex = c.sex
      v.members = c.members
    }
    return v
  }

  chatView(id) {
    const row = this.store.chatRow(id)
    if (!row) return null
    const c = this.contacts.get(id)
    return {
      ...row,
      name: c?.name || (isRoomId(id) ? '群聊' : '未知联系人'),
      room: isRoomId(id),
      pinned: Boolean(c?.pinned),
      muted: Boolean(c?.muted),
      count: c?.count || 0,
      biz: Boolean(c?.biz),
      stale: Boolean(c?.stale)
    }
  }

  chatList() {
    const self = this.client.s.user?.UserName
    return this.store
      .listChats()
      .filter(r => r.id !== self && !this.contacts.get(r.id)?.special)
      .map(r => this.chatView(r.id))
      .filter(c => c && (c.last || c.rank || c.pinned))
  }

  // ================================================================ HTTP

  async fetch(request) {
    const url = new URL(request.url)
    const path = url.pathname.replace(/^\/api/, '')
    const method = request.method

    if (path === '/ws') return this.acceptSocket(request)

    try {
      if (method === 'GET') {
        if (path === '/state') return json(this.publicState())
        if (path === '/bootstrap') return this.bootstrap()
        if (path === '/contacts') return json([...this.contacts.values()].filter(c => !c.stale).map(c => this.contactView(c)))
        if (path.startsWith('/contact/')) {
          const c = this.contacts.get(decodeURIComponent(path.slice(9)))
          return c ? json(this.contactView(c, true)) : fail(404, '联系人不存在')
        }
        if (path === '/messages') return this.messages(url)
        if (path === '/login/qr.svg') return this.qrSvg()
        if (path.startsWith('/avatar/')) return this.avatar(decodeURIComponent(path.slice(8)), url)
        if (path.startsWith('/media/')) return this.media(path, request)
        if (path === '/diag') return this.diag()
        if (path === '/push/key') return json({ key: this.env.VAPID_PUBLIC_KEY || '' })
      }
      if (method === 'POST') {
        const body = await readBody(request)
        if (path === '/login') return json({ ok: true, uuid: await this.startLogin(), state: this.publicState() })
        if (path === '/logout') return this.logout(body)
        if (path === '/send') return this.sendText(body)
        if (path === '/send-image') return this.sendImage(body)
        if (path === '/read') return this.markRead(body)
        if (path === '/revoke') return this.revoke(body)
        if (path === '/delete') return this.deleteLocal(body)
        if (path === '/pin') return this.pin(body)
        if (path === '/hide') return this.hide(body)
        if (path === '/clear') return this.clearChat(body)
        if (path === '/push/subscribe') return this.pushSubscribe(body)
        if (path === '/push/unsubscribe') return this.pushUnsubscribe(body)
        if (path === '/push/test') return this.pushTest()
      }
      return fail(404, 'not found')
    } catch (err) {
      this.log('api', `${path}: ${err.message}`, { code: err.code })
      if (err instanceof WxError && err.logout) this.goOffline(err.message)
      const status = err.code === 'offline' ? 409 : err instanceof WxError ? 502 : 500
      return fail(status, err.message || '服务器错误', { step: err.step, code: err.code })
    }
  }

  async ensureLoop() {
    if (['qr', 'scanned', 'connecting', 'online'].includes(this.state.phase)) {
      const at = await this.ctx.storage.getAlarm()
      if (!at) await this.schedule(0)
    }
  }

  async bootstrap() {
    await this.ensureLoop()
    const me = this.me()
    return json({
      state: this.publicState(),
      me: me ? this.contactView(me, true) : null,
      chats: this.state.phase === 'idle' ? [] : this.chatList()
    })
  }

  messages(url) {
    const chat = url.searchParams.get('chat') || ''
    const before = Number(url.searchParams.get('before')) || undefined
    const after = Number(url.searchParams.get('after')) || 0
    const limit = Math.min(200, Number(url.searchParams.get('limit')) || 60)
    return json({ chat, messages: this.store.listMessages(chat, { before, after, limit }) })
  }

  qrSvg() {
    const uuid = this.state.uuid
    if (!uuid || !['qr', 'scanned'].includes(this.state.phase)) return fail(404, 'no qr')
    const qr = qrcode(0, 'M')
    qr.addData(QR_LOGIN_URL(uuid))
    qr.make()
    const n = qr.getModuleCount()
    let path = ''
    for (let r = 0; r < n; r++) {
      for (let c = 0; c < n; c++) if (qr.isDark(r, c)) path += `M${c} ${r}h1v1h-1z`
    }
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="-2 -2 ${n + 4} ${n + 4}" shape-rendering="crispEdges"><rect x="-2" y="-2" width="${n + 4}" height="${n + 4}" fill="#fff"/><path d="${path}" fill="#000"/></svg>`
    return new Response(svg, { headers: { 'content-type': 'image/svg+xml', 'cache-control': 'no-store' } })
  }

  diag() {
    const s = this.client.s
    return json({
      state: this.publicState(),
      host: s.host,
      hasSession: Boolean(s.sid),
      counts: {
        contacts: this.contacts.size,
        chats: this.store.exec('SELECT COUNT(*) AS n FROM chats')[0].n,
        messages: this.store.exec('SELECT COUNT(*) AS n FROM messages')[0].n
      },
      sockets: this.ctx.getWebSockets().length,
      log: this.store.get('log', []).slice(-20)
    })
  }

  async logout(body) {
    this.gen++
    if (this.client.s.sid) await this.client.logout()
    this.client = this.makeClient()
    this.store.set('session', null)
    if (body?.wipe) {
      this.store.wipe()
      this.contacts = new Map()
      this.setState({ phase: 'idle', uin: '', error: null, epoch: this.state.epoch })
    } else {
      this.setState({ phase: 'idle', error: null })
    }
    await this.ctx.storage.deleteAlarm()
    this.broadcast({ t: 'reload' })
    return json({ ok: true })
  }

  requireOnline() {
    if (this.state.phase !== 'online' || !this.client.loggedIn) {
      throw new WxError('微信未登录', { step: 'api', code: 'offline' })
    }
  }

  async sendText(body) {
    this.requireOnline()
    const chat = String(body.chat || '')
    const text = String(body.text || '').replace(/\r\n/g, '\n')
    if (!chat || !text.trim()) return fail(400, '消息为空')
    if (text.length > 8000) return fail(400, '消息太长')
    if (this.contacts.get(chat)?.stale) return fail(409, '这是上次登录的会话，无法发送')
    const cid = /^\d{10,20}$/.test(body.cid) ? body.cid : newClientMsgId()
    const local = {
      id: `local:${cid}`,
      cid,
      chat,
      ts: Date.now(),
      out: true,
      from: this.client.s.user.UserName,
      fromName: '',
      type: 'text',
      text,
      status: 'sending'
    }
    if (!this.store.addMessage(local)) return json({ ok: true, msg: this.store.getMessage(local.id) })
    this.store.setUnread(chat, 0)
    this.broadcast({ t: 'msg', msg: local })
    this.broadcast({ t: 'chats', chats: [this.chatView(chat)] })

    const key = `${chat}\u0000${text}`
    this.pendingTexts.set(key, local.id)
    try {
      const { msgId } = await this.client.sendText(chat, text, cid)
      return json({ ok: true, msg: this.settleSend(local.id, msgId, chat) })
    } catch (err) {
      const echoed = [...this.echoes].find(([, l]) => l === local.id)
      if (echoed) return json({ ok: true, msg: this.settleSend(local.id, echoed[0], chat) })
      const msg = this.store.updateMessage(local.id, { status: 'failed', error: err.message })
      this.broadcast({ t: 'msg', msg })
      this.broadcast({ t: 'chats', chats: [this.chatView(chat)] })
      if (err instanceof WxError && err.logout) this.goOffline(err.message)
      return json({ ok: false, error: err.message, msg }, { status: 502 })
    } finally {
      if (this.pendingTexts.get(key) === local.id) this.pendingTexts.delete(key)
    }
  }

  settleSend(localId, msgId, chat) {
    for (const [echoId, l] of this.echoes) if (l === localId) this.echoes.delete(echoId)
    let msg
    if (!msgId) {
      msg = this.store.updateMessage(localId, { status: 'sent' })
      this.broadcast({ t: 'msg', msg })
    } else if (this.store.hasMessage(msgId)) {
      this.store.deleteMessage(localId)
      msg = this.store.getMessage(msgId)
      this.broadcast({ t: 'replace', from: localId, msg })
    } else {
      msg = this.store.rekeyMessage(localId, msgId, { status: 'sent' })
      this.broadcast({ t: 'replace', from: localId, msg })
    }
    this.broadcast({ t: 'chats', chats: [this.chatView(chat)] })
    return msg
  }

  async sendImage(form) {
    this.requireOnline()
    if (!(form instanceof FormData)) return fail(400, '需要 multipart/form-data')
    const chat = String(form.get('chat') || '')
    const file = form.get('file')
    if (!chat || !file || typeof file === 'string') return fail(400, '缺少图片')
    if (file.size > 20 * 1024 * 1024) return fail(413, '图片超过 20 MB')
    if (this.contacts.get(chat)?.stale) return fail(409, '这是上次登录的会话，无法发送')
    const cidIn = String(form.get('cid') || '')
    const cid = /^\d{10,20}$/.test(cidIn) ? cidIn : newClientMsgId()
    const local = {
      id: `local:${cid}`,
      cid,
      chat,
      ts: Date.now(),
      out: true,
      from: this.client.s.user.UserName,
      fromName: '',
      type: 'image',
      w: Number(form.get('w')) || 0,
      h: Number(form.get('h')) || 0,
      status: 'sending'
    }
    this.store.addMessage(local)
    this.broadcast({ t: 'msg', msg: local })
    this.broadcast({ t: 'chats', chats: [this.chatView(chat)] })
    try {
      const type = file.type || 'image/jpeg'
      const name = file.name || `IMG_${Date.now()}.jpg`
      const mediaId = await this.client.uploadMedia(file, { name, type, to: chat, mediaType: 'pic' })
      const { msgId } = await this.client.sendImage(chat, mediaId, cid)
      return json({ ok: true, msg: this.settleSend(local.id, msgId, chat) })
    } catch (err) {
      const msg = this.store.updateMessage(local.id, { status: 'failed', error: err.message })
      this.broadcast({ t: 'msg', msg })
      if (err instanceof WxError && err.logout) this.goOffline(err.message)
      return json({ ok: false, error: err.message, msg }, { status: 502 })
    }
  }

  async markRead(body) {
    const chat = String(body.chat || '')
    const row = this.store.chatRow(chat)
    if (!row) return json({ ok: true })
    if (body.unread) {
      // "Mark as unread" is local only; the web protocol has no such call.
      this.store.setUnread(chat, Math.max(1, row.unread))
      this.broadcast({ t: 'chats', chats: [this.chatView(chat)] })
      return json({ ok: true })
    }
    const had = row.unread
    this.store.setUnread(chat, 0)
    this.broadcast({ t: 'chats', chats: [this.chatView(chat)] })
    if (had && this.state.phase === 'online' && !this.contacts.get(chat)?.stale) {
      this.client.statusNotify(STATUS_NOTIFY.READ, chat).catch(err => this.log('read', err.message))
    }
    return json({ ok: true })
  }

  async revoke(body) {
    this.requireOnline()
    const m = this.store.getMessage(String(body.id || ''))
    if (!m || !m.out || !m.cid || m.id.startsWith('local:')) return fail(400, '这条消息不能撤回')
    if (Date.now() - m.ts > 2 * 60 * 1000) return fail(400, '发送超过 2 分钟的消息不能撤回')
    await this.client.revoke(m.chat, m.id, m.cid)
    const msg = this.store.updateMessage(m.id, { type: 'recalled', text: '你撤回了一条消息', recalled: '你撤回了一条消息', revokedText: m.type === 'text' ? m.text : undefined })
    this.broadcast({ t: 'msg', msg })
    this.broadcast({ t: 'chats', chats: [this.chatView(m.chat)] })
    return json({ ok: true, msg })
  }

  deleteLocal(body) {
    const m = this.store.deleteMessage(String(body.id || ''))
    if (m) {
      this.broadcast({ t: 'remove', id: m.id, chat: m.chat })
      this.broadcast({ t: 'chats', chats: [this.chatView(m.chat)] })
    }
    return json({ ok: true })
  }

  async pin(body) {
    this.requireOnline()
    const c = this.contacts.get(String(body.chat || ''))
    if (!c) return fail(404, '联系人不存在')
    const on = Boolean(body.on)
    await this.client.setTop(c.id, on, c.remark || '')
    const next = { ...c, pinned: on }
    this.contacts.set(c.id, next)
    this.store.putContact(next, this.state.epoch)
    this.broadcast({ t: 'chats', chats: [this.chatView(c.id)].filter(Boolean) })
    this.broadcast({ t: 'contacts' })
    return json({ ok: true })
  }

  hide(body) {
    const chat = String(body.chat || '')
    this.store.hideChat(chat, true)
    this.store.setUnread(chat, 0)
    this.broadcast({ t: 'reload' })
    return json({ ok: true })
  }

  clearChat(body) {
    const chat = String(body.chat || '')
    this.store.clearChat(chat)
    this.broadcast({ t: 'cleared', chat })
    this.broadcast({ t: 'chats', chats: [this.chatView(chat)].filter(Boolean) })
    return json({ ok: true })
  }

  // ================================================================ media

  async avatar(id, url) {
    if (!this.client.s.skey) return fail(404, 'offline')
    const c = this.contacts.get(id)
    const inRoom = url.searchParams.get('in')
    let target
    if (c?.img && !c.stale && /^\/cgi-bin\/mmwebwx-bin\/webwxget(icon|headimg)\?/.test(c.img)) {
      // Never follow an absolute URL here: the request carries the session cookies.
      const u = new URL(c.img, this.client.hosts.origin)
      u.searchParams.set('skey', this.client.s.skey)
      target = u.toString()
    } else if (inRoom) {
      const room = this.contacts.get(inRoom)
      target = this.client.mediaUrl('avatar', { user: id, chatroom: room?.enc || '' })
    } else if (id === this.client.s.user?.UserName || c) {
      target = this.client.mediaUrl('avatar', { user: id, room: isRoomId(id) })
    } else {
      return fail(404, 'unknown')
    }
    return this.proxy(target, { cache: 'private, max-age=86400' })
  }

  async media(path, request) {
    const [, , kind, rawId] = path.split('/')
    const id = decodeURIComponent(rawId || '')
    if (!/^\d+$/.test(id)) return fail(400, 'bad id')
    if (!this.client.s.skey) return fail(404, 'offline')
    const range = request.headers.get('range')
    switch (kind) {
      case 'image':
      case 'thumb':
      case 'sticker':
      case 'voice':
        return this.proxy(this.client.mediaUrl(kind, { id }), { cache: 'private, max-age=31536000, immutable' })
      case 'video':
        return this.proxy(this.client.mediaUrl('video', { id }), { range: range || 'bytes=0-', cache: 'private, max-age=86400' })
      case 'file': {
        const m = this.store.getMessage(id)
        if (!m || m.type !== 'file') return fail(404, 'no file')
        const sender = m.out ? this.client.s.user.UserName : m.chat
        const res = await this.proxy(this.client.mediaUrl('file', { sender, mediaId: m.mediaId, name: m.name }), { cache: 'private, max-age=86400' })
        const h = new Headers(res.headers)
        h.set('content-disposition', `attachment; filename*=UTF-8''${encodeURIComponent(m.name)}`)
        return new Response(res.body, { status: res.status, headers: h })
      }
      default:
        return fail(404, 'unknown media')
    }
  }

  async proxy(target, { range, cache } = {}) {
    let res
    try {
      res = await this.client.fetchMedia(target, { range })
    } catch (err) {
      return fail(502, err.message)
    }
    const type = res.headers.get('content-type') || 'application/octet-stream'
    if (!res.ok || /text\/html|application\/json/.test(type)) {
      await res.body?.cancel()
      return fail(res.ok ? 404 : res.status, 'media unavailable')
    }
    const h = new Headers({
      'content-type': type,
      'cache-control': cache || 'private, max-age=3600',
      // Media is third-party content served from our origin: never let it run script.
      'content-security-policy': "default-src 'none'; img-src data:; style-src 'unsafe-inline'; sandbox",
      'x-content-type-options': 'nosniff'
    })
    for (const k of ['content-length', 'content-range', 'accept-ranges']) {
      const v = res.headers.get(k)
      if (v) h.set(k, v)
    }
    return new Response(res.body, { status: res.status, headers: h })
  }

  // ================================================================ websockets

  acceptSocket(request) {
    if (request.headers.get('upgrade') !== 'websocket') return fail(426, 'websocket expected')
    const pair = new WebSocketPair()
    const [client, server] = Object.values(pair)
    this.ctx.acceptWebSocket(server)
    server.serializeAttachment({ visible: true, chat: null })
    server.send(JSON.stringify({ t: 'state', state: this.publicState() }))
    this.ensureLoop()
    return new Response(null, { status: 101, webSocket: client })
  }

  async webSocketMessage(ws, message) {
    let msg
    try {
      msg = JSON.parse(typeof message === 'string' ? message : new TextDecoder().decode(message))
    } catch {
      return
    }
    if (msg.t === 'ping') ws.send(JSON.stringify({ t: 'pong', at: Date.now() }))
    else if (msg.t === 'focus') {
      ws.serializeAttachment({ visible: Boolean(msg.visible), chat: msg.chat || null })
      if (msg.visible && msg.chat) {
        const row = this.store.chatRow(msg.chat)
        if (row?.unread) await this.markRead({ chat: msg.chat })
      }
    }
  }

  webSocketClose(ws, code) {
    try {
      ws.close(code === 1005 ? 1000 : code, 'bye')
    } catch {
      // Already closed.
    }
  }

  webSocketError() {}

  // ================================================================ auth gate (RPC from the Worker)

  authGate(ip) {
    const f = this.authFails.get(ip)
    if (f && f.until > Date.now()) return { allowed: false, retryAfter: Math.ceil((f.until - Date.now()) / 1000) }
    return { allowed: true }
  }

  authResult(ip, ok) {
    if (ok) {
      this.authFails.delete(ip)
      return
    }
    const f = this.authFails.get(ip) || { count: 0, until: 0 }
    f.count++
    if (f.count >= AUTH_MAX_FAILS) {
      f.until = Date.now() + AUTH_LOCK_MS
      f.count = 0
    }
    this.authFails.set(ip, f)
  }

  // ================================================================ push

  async pushSubscribe(body) {
    const sub = body?.subscription
    if (!sub?.endpoint || !sub?.keys?.p256dh || !sub?.keys?.auth) return fail(400, '订阅信息不完整')
    if (!/^https:\/\//.test(sub.endpoint)) return fail(400, 'endpoint 无效')
    this.store.addPushSub({ endpoint: sub.endpoint, keys: { p256dh: sub.keys.p256dh, auth: sub.keys.auth } })
    return json({ ok: true })
  }

  pushUnsubscribe(body) {
    if (body?.endpoint) this.store.removePushSub(String(body.endpoint))
    return json({ ok: true })
  }

  async pushTest() {
    const n = await this.notifyAll({ title: '通知已开启', body: '新消息会在这里提醒你。', tag: 'test' })
    return json({ ok: n > 0, sent: n })
  }

  async pushMessages(list) {
    if (!pushConfigured(this.env)) return
    // Someone is looking at the app right now; the live socket is enough.
    if (this.ctx.getWebSockets().some(ws => ws.deserializeAttachment()?.visible)) return
    const byChat = new Map()
    for (const m of list) {
      const c = this.contacts.get(m.chat)
      if (c?.muted || c?.special || c?.biz) continue
      if (!byChat.has(m.chat)) byChat.set(m.chat, [])
      byChat.get(m.chat).push(m)
    }
    for (const [chat, msgs] of byChat) {
      if (this.budgetLeft < 4) break
      const c = this.contacts.get(chat)
      const last = msgs[msgs.length - 1]
      const sender = c?.room ? (last.fromName || memberName(c, last.from, this.contacts)) : ''
      const preview = summaryOf(last).text
      const unread = this.store.chatRow(chat)?.unread || msgs.length
      await this.notifyAll({
        title: c?.name || '新消息',
        body: c?.room && sender && !preview.startsWith(sender) ? `${sender}: ${preview}` : preview,
        tag: chat,
        chat,
        count: unread
      })
    }
  }

  async notifyAll(payload) {
    if (!pushConfigured(this.env)) return 0
    let sent = 0
    for (const sub of this.store.pushSubs()) {
      try {
        this.reqCount++
        const res = await sendWebPush(this.env, sub, payload)
        if (res.status === 404 || res.status === 410) this.store.removePushSub(sub.endpoint)
        else if (res.ok) sent++
      } catch (err) {
        this.log('push', err.message)
      }
    }
    return sent
  }
}

async function readBody(request) {
  const type = request.headers.get('content-type') || ''
  if (type.includes('multipart/form-data')) return request.formData()
  if (type.includes('application/json')) {
    try {
      return await request.json()
    } catch {
      return {}
    }
  }
  return {}
}
