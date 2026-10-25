// WeChat web protocol client for Cloudflare Workers.
//
// Protocol flow and request shapes follow wechat4u (MIT,
// https://github.com/nodeWechat/wechat4u) src/core.js, rewritten for the
// Workers runtime: global fetch instead of axios, an explicit cookie jar,
// `redirect: 'manual'` for the login redirect, no eval, and all state in one
// plain object (`client.s`) the Durable Object can persist and restore.

import {
  APPID, UA_WEB, UA_UOS, LOGIN_MODES, UOS_CLIENT_VERSION, UOS_EXTSPAM, LOGOUT_CODES, hostsFor
} from './conf.js'
import {
  parseJsLogin, parseLoginCheck, parseSyncCheck, parseLoginXml, cookiePairs
} from './parse.js'

const MODE_LABEL = { desktop: '桌面版（UOS）', web: '网页版' }

export class WxError extends Error {
  constructor(message, { step, code, logout = false, detail } = {}) {
    super(message)
    this.name = 'WxError'
    this.step = step
    this.code = code
    this.logout = logout
    this.detail = detail
  }
}

const CHUNK = 512 * 1024

export function newClientMsgId() {
  // Same 17-digit shape the official web client generates.
  return (Date.now() + Math.random().toFixed(3)).replace('.', '')
}

function newDeviceId() {
  return 'e' + String(Math.random().toFixed(15)).slice(2, 17)
}

function pgv(prefix = '') {
  return prefix + Math.round(2147483647 * (Math.random() || 0.5)) * (Date.now() % 1e10)
}

export function emptySession() {
  return {
    host: 'wx.qq.com',
    cookies: { pgv_pvi: pgv(), pgv_si: pgv('s') },
    uin: '',
    sid: '',
    skey: '',
    passTicket: '',
    dataTicket: '',
    syncKey: null,
    syncCheckKey: '',
    deviceId: newDeviceId(),
    user: null,
    mode: '' // login that last worked: 'desktop' | 'web'
  }
}

export class WxClient {
  /**
   * @param {object} session  persisted state from snapshot(), or undefined
   * @param {object} opts
   *   fetch       fetch implementation (tests)
   *   rewrite     url => url, only used to point at the local mock server
   *   onRequest   called once per outbound request (subrequest budgeting)
   *   loginMode   'desktop' | 'web' to use only that login; anything else = auto
   *   clientVersion, extspam   override the UOS login headers
   */
  constructor(session, opts = {}) {
    this.s = { ...emptySession(), ...(session || {}) }
    this.fetchImpl = opts.fetch || ((...a) => fetch(...a))
    this.rewrite = opts.rewrite || null
    this.onRequest = opts.onRequest || null
    this.forcedMode = LOGIN_MODES.includes(opts.loginMode) ? opts.loginMode : null
    this.clientVersion = opts.clientVersion || UOS_CLIENT_VERSION
    this.extspam = opts.extspam || UOS_EXTSPAM
  }

  /** The login this client tries first: forced, else whichever worked last. */
  get mode() {
    return this.forcedMode || (LOGIN_MODES.includes(this.s.mode) ? this.s.mode : 'desktop')
  }

  /** Same browser identity before and after login. */
  get ua() {
    // A session from before login modes were recorded logged in with the
    // desktop-browser UA; don't change identity in the middle of it.
    if (!this.forcedMode && !this.s.mode && this.s.sid) return UA_WEB
    return this.mode === 'web' ? UA_WEB : UA_UOS
  }

  get hosts() {
    return hostsFor(this.s.host)
  }

  get loggedIn() {
    return Boolean(this.s.sid && this.s.uin && this.s.user)
  }

  snapshot() {
    return JSON.parse(JSON.stringify(this.s))
  }

  baseRequest() {
    return {
      Uin: Number(this.s.uin),
      Sid: this.s.sid,
      Skey: this.s.skey,
      DeviceID: this.s.deviceId
    }
  }

  cookieHeader() {
    return Object.entries(this.s.cookies)
      .map(([k, v]) => `${k}=${v}`)
      .join('; ')
  }

  absorbCookies(res) {
    const lines = typeof res.headers.getSetCookie === 'function'
      ? res.headers.getSetCookie()
      : (res.headers.get('set-cookie') || '').split(/,(?=\s*[^;,=\s]+=)/)
    for (const { name, value, expired } of cookiePairs(lines)) {
      if (expired) delete this.s.cookies[name]
      else this.s.cookies[name] = value
      if (/^webwx_data_ticket$/i.test(name) && !expired) this.s.dataTicket = value
    }
  }

  /**
   * Build a URL. pass_ticket arrives from the server already URL-encoded and
   * the official client concatenates it verbatim, so it is not re-encoded.
   */
  url(base, params) {
    if (!params) return base
    const parts = []
    for (const [k, v] of Object.entries(params)) {
      if (v === undefined || v === null) continue
      parts.push(`${k}=${k === 'pass_ticket' ? v : encodeURIComponent(v)}`)
    }
    return parts.length ? `${base}${base.includes('?') ? '&' : '?'}${parts.join('&')}` : base
  }

  async request(url, { method = 'GET', json, body, headers = {}, redirect = 'follow', timeout = 30000, signal } = {}) {
    const h = new Headers({
      'User-Agent': this.ua,
      Accept: 'application/json, text/plain, */*',
      'Accept-Language': 'zh-CN,zh;q=0.9',
      Referer: `https://${this.s.host}/`,
      ...headers
    })
    const cookie = this.cookieHeader()
    if (cookie) h.set('Cookie', cookie)
    let payload = body
    if (json !== undefined) {
      h.set('Content-Type', 'application/json;charset=UTF-8')
      payload = JSON.stringify(json)
    }
    const target = this.rewrite ? this.rewrite(url) : url
    this.onRequest?.(url)
    const res = await this.fetchImpl(target, {
      method,
      headers: h,
      body: payload,
      redirect,
      signal: signal || AbortSignal.timeout(timeout)
    })
    this.absorbCookies(res)
    return res
  }

  async requestJson(url, opts, step) {
    let res
    try {
      res = await this.request(url, opts)
    } catch (err) {
      throw new WxError(`网络请求失败：${err.message || err}`, { step, detail: String(err) })
    }
    const text = await res.text()
    if (!res.ok) throw new WxError(`HTTP ${res.status}`, { step, code: res.status, detail: text.slice(0, 300) })
    let data
    try {
      data = JSON.parse(text)
    } catch {
      throw new WxError('服务器返回了无法解析的数据', { step, detail: text.slice(0, 300) })
    }
    const ret = data?.BaseResponse?.Ret
    if (ret !== undefined && ret !== 0) {
      throw new WxError(data.BaseResponse.ErrMsg || `Ret ${ret}`, {
        step,
        code: ret,
        logout: LOGOUT_CODES.has(ret),
        detail: data.BaseResponse
      })
    }
    return data
  }

  // ---------------------------------------------------------------- login

  async getUuid() {
    const page = 'https://wx.qq.com/cgi-bin/mmwebwx-bin/webwxnewloginpage'
    const redirect = this.mode === 'desktop' ? `${page}?mod=desktop` : page
    const url = this.url(`https://${this.hosts.login}/jslogin`, {
      appid: APPID,
      fun: 'new',
      lang: 'zh_CN',
      redirect_uri: redirect,
      _: Date.now()
    })
    let res
    try {
      res = await this.request(url, { method: 'GET' })
    } catch (err) {
      throw new WxError(`无法连接微信登录服务器：${err.message || err}`, { step: 'jslogin' })
    }
    const text = await res.text()
    const { code, uuid } = parseJsLogin(text)
    if (code !== 200 || !uuid) {
      throw new WxError(`获取登录二维码失败（code ${code || res.status}）`, { step: 'jslogin', code, detail: text.slice(0, 300) })
    }
    return uuid
  }

  /** Long-polls (~25 s server side) until the phone scans, confirms or the code expires. */
  async checkLogin(uuid, tip = 0) {
    const url = this.url(`https://${this.hosts.login}/cgi-bin/mmwebwx-bin/login`, {
      loginicon: 'true',
      uuid,
      tip,
      r: ~Date.now(),
      _: Date.now()
    })
    const res = await this.request(url, { timeout: 40000 })
    const text = await res.text()
    const out = parseLoginCheck(text)
    if (!out.code) throw new WxError('登录状态返回异常', { step: 'login', detail: text.slice(0, 300) })
    return out
  }

  /**
   * Exchanges the confirmed-login redirect for session credentials.
   *
   * Tries the preferred login first. If WeChat refuses it (a non-zero ret,
   * e.g. 1203 "当前微信版本过低" for the UOS desktop identity), the same scan
   * is tried once with the other login before giving up, so a refusal of one
   * route doesn't cost a second scan. The mode that worked is remembered.
   */
  async completeLogin(redirectUri) {
    const host = (redirectUri.match(/^https?:\/\/([^/]+)/) || [])[1]
    if (host) this.s.host = host
    const order = this.forcedMode ? [this.forcedMode] : [this.mode, ...LOGIN_MODES.filter(m => m !== this.mode)]
    const refused = []
    for (const mode of order) {
      try {
        await this.loginPage(redirectUri, mode)
        this.s.mode = mode
        return { mode, refused }
      } catch (err) {
        // Only a refusal from WeChat is worth retrying the other way; a network
        // failure or a malformed answer would fail the same way again.
        if (!(err instanceof WxError) || !Number.isFinite(err.code) || err.code === 0) throw err
        err.mode = mode
        refused.push(err)
      }
    }
    const [first, second] = refused
    const message = second
      ? `${MODE_LABEL[first.mode]}登录被拒绝：${first.message}\n改用${MODE_LABEL[second.mode]}登录重试，也被拒绝：${second.message}`
      : first.message
    throw new WxError(message, {
      step: 'newloginpage',
      code: first.code,
      detail: refused.map(e => ({ mode: e.mode, code: e.code, message: e.message }))
    })
  }

  async loginPage(redirectUri, mode) {
    const desktop = mode === 'desktop'
    // The classic web client asks for the same page with fun=new&version=v2;
    // the desktop one keeps the redirect verbatim and adds the UOS headers.
    let url = redirectUri
    if (!desktop) {
      url = redirectUri.replace(/([?&])mod=desktop(&|$)/, (_, a, b) => (b ? a : ''))
      url += `${url.includes('?') ? '&' : '?'}fun=new&version=v2`
    }
    const headers = desktop
      ? { 'User-Agent': UA_UOS, 'client-version': this.clientVersion, extspam: this.extspam, Referer: 'https://wx.qq.com/?&lang=zh_CN&target=t' }
      : { 'User-Agent': UA_WEB, Referer: `https://${this.s.host}/` }
    let res
    try {
      res = await this.request(url, { redirect: 'manual', headers })
    } catch (err) {
      throw new WxError(`登录请求失败：${err.message || err}`, { step: 'newloginpage' })
    }
    const text = await res.text()
    const x = parseLoginXml(text)
    if (x.ret !== 0) {
      throw new WxError(x.message || `登录被拒绝（ret ${Number.isNaN(x.ret) ? res.status : x.ret}）`, {
        step: 'newloginpage',
        code: Number.isNaN(x.ret) ? res.status : x.ret,
        detail: text.slice(0, 500)
      })
    }
    this.s.skey = x.skey || this.s.skey
    this.s.sid = x.wxsid || this.s.cookies.wxsid || ''
    this.s.uin = x.wxuin || this.s.cookies.wxuin || ''
    this.s.passTicket = x.passTicket || this.s.cookies.pass_ticket || ''
    if (!this.s.sid || !this.s.uin) {
      throw new WxError('登录返回缺少会话信息', { step: 'newloginpage', detail: text.slice(0, 500) })
    }
  }

  async init() {
    const url = this.url(`${this.hosts.cgi}/webwxinit`, {
      r: Math.ceil(Date.now() / -1579),
      pass_ticket: this.s.passTicket
    })
    const data = await this.requestJson(url, { method: 'POST', json: { BaseRequest: this.baseRequest() } }, 'webwxinit')
    this.s.skey = data.SKey || this.s.skey
    this.s.user = data.User
    this.updateSyncKey(data)
    return data
  }

  updateSyncKey(data) {
    if (data.SyncKey?.List) this.s.syncKey = data.SyncKey
    const list = data.SyncCheckKey?.List || (!this.s.syncCheckKey ? data.SyncKey?.List : null)
    if (list) this.s.syncCheckKey = list.map(k => `${k.Key}_${k.Val}`).join('|')
  }

  /** code 3 = client inited, 1 = mark chat read (to = chat). */
  async statusNotify(code, to) {
    const self = this.s.user?.UserName
    const url = this.url(`${this.hosts.cgi}/webwxstatusnotify`, { lang: 'zh_CN', pass_ticket: this.s.passTicket })
    return this.requestJson(url, {
      method: 'POST',
      json: {
        BaseRequest: this.baseRequest(),
        Code: code,
        FromUserName: self,
        ToUserName: to || self,
        ClientMsgId: Date.now()
      }
    }, 'statusnotify')
  }

  /** One page of the address book; returns { list, seq } where seq 0 means done. */
  async getContactPage(seq = 0) {
    const url = this.url(`${this.hosts.cgi}/webwxgetcontact`, {
      lang: 'zh_CN',
      pass_ticket: this.s.passTicket,
      r: Date.now(),
      seq,
      skey: this.s.skey
    })
    const data = await this.requestJson(url, { method: 'GET' }, 'webwxgetcontact')
    return { list: data.MemberList || [], seq: Number(data.Seq || 0) }
  }

  /** Details (incl. group member lists) for up to 50 users/rooms at a time. */
  async batchGetContacts(items) {
    const url = this.url(`${this.hosts.cgi}/webwxbatchgetcontact`, {
      type: 'ex',
      r: Date.now(),
      lang: 'zh_CN',
      pass_ticket: this.s.passTicket
    })
    const list = items.map(i => (typeof i === 'string' ? { UserName: i, EncryChatRoomId: '' } : i))
    const data = await this.requestJson(url, {
      method: 'POST',
      json: { BaseRequest: this.baseRequest(), Count: list.length, List: list }
    }, 'webwxbatchgetcontact')
    return data.ContactList || []
  }

  /** Long-poll (~25 s). Returns { retcode, selector }. */
  async syncCheck() {
    const url = this.url(`https://${this.hosts.push}/cgi-bin/mmwebwx-bin/synccheck`, {
      r: Date.now(),
      skey: this.s.skey,
      sid: this.s.sid,
      uin: this.s.uin,
      deviceid: this.s.deviceId,
      synckey: this.s.syncCheckKey,
      _: Date.now()
    })
    let res
    try {
      res = await this.request(url, { timeout: 45000 })
    } catch (err) {
      throw new WxError(`同步检查失败：${err.message || err}`, { step: 'synccheck' })
    }
    const text = await res.text()
    const out = parseSyncCheck(text)
    if (!out) throw new WxError('同步检查返回异常', { step: 'synccheck', detail: text.slice(0, 200) })
    if (LOGOUT_CODES.has(out.retcode)) {
      throw new WxError(out.retcode === 1101 ? '已在其他地方登录或在手机上退出了网页版' : '登录已失效', {
        step: 'synccheck',
        code: out.retcode,
        logout: true
      })
    }
    if (out.retcode !== 0) throw new WxError(`同步检查失败（retcode ${out.retcode}）`, { step: 'synccheck', code: out.retcode })
    return out
  }

  async sync() {
    const url = this.url(`${this.hosts.cgi}/webwxsync`, {
      sid: this.s.sid,
      skey: this.s.skey,
      lang: 'zh_CN',
      pass_ticket: this.s.passTicket
    })
    const data = await this.requestJson(url, {
      method: 'POST',
      json: { BaseRequest: this.baseRequest(), SyncKey: this.s.syncKey, rr: ~Date.now() }
    }, 'webwxsync')
    this.updateSyncKey(data)
    this.s.skey = data.SKey || this.s.skey
    return data
  }

  // ---------------------------------------------------------------- sending

  async sendText(to, content, clientMsgId = newClientMsgId()) {
    const url = this.url(`${this.hosts.cgi}/webwxsendmsg`, { lang: 'zh_CN', pass_ticket: this.s.passTicket })
    const data = await this.requestJson(url, {
      method: 'POST',
      json: {
        BaseRequest: this.baseRequest(),
        Scene: 0,
        Msg: {
          Type: 1,
          Content: content,
          FromUserName: this.s.user.UserName,
          ToUserName: to,
          LocalID: clientMsgId,
          ClientMsgId: clientMsgId
        }
      }
    }, 'webwxsendmsg')
    return { msgId: String(data.MsgID || ''), localId: String(data.LocalID || clientMsgId) }
  }

  /** Uploads a Blob; chunks above 512 KB like the official client. Returns MediaId. */
  async uploadMedia(blob, { name, type, to, mediaType = 'pic' }) {
    const size = blob.size
    const md5 = await md5Hex(await blob.arrayBuffer())
    const clientMediaId = Date.now()
    const request = JSON.stringify({
      UploadType: 2,
      BaseRequest: this.baseRequest(),
      ClientMediaId: clientMediaId,
      TotalLen: size,
      StartPos: 0,
      DataLen: size,
      MediaType: 4,
      FromUserName: this.s.user.UserName,
      ToUserName: to,
      FileMd5: md5
    })
    const url = this.url(`https://${this.hosts.file}/cgi-bin/mmwebwx-bin/webwxuploadmedia`, { f: 'json' })
    const chunks = Math.max(1, Math.ceil(size / CHUNK))
    let mediaId = ''
    for (let i = 0; i < chunks; i++) {
      const form = new FormData()
      form.append('id', 'WU_FILE_0')
      form.append('name', name)
      form.append('type', type)
      form.append('lastModifiedDate', new Date().toUTCString())
      form.append('size', String(size))
      if (chunks > 1) {
        form.append('chunks', String(chunks))
        form.append('chunk', String(i))
      }
      form.append('mediatype', mediaType)
      form.append('uploadmediarequest', request)
      form.append('webwx_data_ticket', this.s.dataTicket || this.s.cookies.webwx_data_ticket || '')
      form.append('pass_ticket', this.s.passTicket)
      form.append('filename', blob.slice(i * CHUNK, Math.min(size, (i + 1) * CHUNK), type), name)
      const data = await this.requestJson(url, { method: 'POST', body: form, timeout: 60000 }, 'webwxuploadmedia')
      if (data.MediaId) mediaId = data.MediaId
    }
    if (!mediaId) throw new WxError('上传失败：没有返回 MediaId', { step: 'webwxuploadmedia' })
    return mediaId
  }

  async sendImage(to, mediaId, clientMsgId = newClientMsgId()) {
    const url = this.url(`${this.hosts.cgi}/webwxsendmsgimg`, {
      fun: 'async',
      f: 'json',
      lang: 'zh_CN',
      pass_ticket: this.s.passTicket
    })
    const data = await this.requestJson(url, {
      method: 'POST',
      json: {
        BaseRequest: this.baseRequest(),
        Scene: 0,
        Msg: {
          Type: 3,
          MediaId: mediaId,
          Content: '',
          FromUserName: this.s.user.UserName,
          ToUserName: to,
          LocalID: clientMsgId,
          ClientMsgId: clientMsgId
        }
      }
    }, 'webwxsendmsgimg')
    return { msgId: String(data.MsgID || ''), localId: String(data.LocalID || clientMsgId) }
  }

  async revoke(to, svrMsgId, clientMsgId) {
    const url = this.url(`${this.hosts.cgi}/webwxrevokemsg`, { lang: 'zh_CN', pass_ticket: this.s.passTicket })
    return this.requestJson(url, {
      method: 'POST',
      json: {
        BaseRequest: this.baseRequest(),
        ClientMsgId: clientMsgId || newClientMsgId(),
        SvrMsgId: svrMsgId,
        ToUserName: to
      }
    }, 'webwxrevokemsg')
  }

  /** Pin / unpin a chat (syncs to the phone). */
  async setTop(userName, top, remarkName = '') {
    const url = this.url(`${this.hosts.cgi}/webwxoplog`, { lang: 'zh_CN', pass_ticket: this.s.passTicket })
    return this.requestJson(url, {
      method: 'POST',
      json: {
        BaseRequest: this.baseRequest(),
        CmdId: 3,
        OP: top ? 1 : 0,
        RemarkName: remarkName,
        UserName: userName
      }
    }, 'webwxoplog')
  }

  async logout() {
    const url = this.url(`${this.hosts.cgi}/webwxlogout`, { redirect: 1, type: 0, skey: this.s.skey })
    try {
      const res = await this.request(url, {
        method: 'POST',
        body: `sid=${encodeURIComponent(this.s.sid)}&uin=${encodeURIComponent(this.s.uin)}`,
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        redirect: 'manual',
        timeout: 10000
      })
      await res.body?.cancel()
    } catch {
      // Logging out is best effort; the local session is dropped either way.
    }
  }

  // ---------------------------------------------------------------- media

  /** URL for a media resource. kind: image | thumb | sticker | voice | video | file | avatar */
  mediaUrl(kind, p) {
    const { cgi } = this.hosts
    const skey = this.s.skey
    switch (kind) {
      case 'image':
        return this.url(`${cgi}/webwxgetmsgimg`, { MsgID: p.id, skey })
      case 'thumb':
        return this.url(`${cgi}/webwxgetmsgimg`, { MsgID: p.id, skey, type: 'slave' })
      case 'sticker':
        return this.url(`${cgi}/webwxgetmsgimg`, { MsgID: p.id, skey, type: 'big' })
      case 'voice':
        return this.url(`${cgi}/webwxgetvoice`, { msgid: p.id, skey })
      case 'video':
        return this.url(`${cgi}/webwxgetvideo`, { msgid: p.id, skey })
      case 'file':
        return this.url(`https://${this.hosts.file}/cgi-bin/mmwebwx-bin/webwxgetmedia`, {
          sender: p.sender,
          mediaid: p.mediaId,
          encryfilename: p.name,
          fromuser: this.s.uin,
          pass_ticket: this.s.passTicket,
          webwx_data_ticket: this.s.dataTicket || this.s.cookies.webwx_data_ticket || ''
        })
      case 'avatar': {
        if (p.room) return this.url(`${cgi}/webwxgetheadimg`, { username: p.user, skey, seq: p.seq })
        return this.url(`${cgi}/webwxgeticon`, { username: p.user, skey, chatroomid: p.chatroom || undefined, seq: p.seq })
      }
      default:
        throw new Error(`unknown media kind ${kind}`)
    }
  }

  async fetchMedia(url, { range } = {}) {
    const headers = {}
    if (range) headers.Range = range
    return this.request(url, { headers, timeout: 60000 })
  }
}

async function md5Hex(buf) {
  try {
    const digest = await crypto.subtle.digest('MD5', buf)
    return [...new Uint8Array(digest)].map(b => b.toString(16).padStart(2, '0')).join('')
  } catch {
    // Node's WebCrypto has no MD5; the field is advisory, so send it empty.
    return ''
  }
}
