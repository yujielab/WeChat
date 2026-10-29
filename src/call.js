// Voice/video calling on Cloudflare Realtime (the SFU formerly called Calls).
//
// Two halves:
//   signalling  — ring / accept / decline / hangup and "here are my track ids"
//                 are relayed between members over the existing WebSocket;
//                 a callee whose app isn't in front is rung by notification.
//   media       — each client speaks WebRTC to the Realtime SFU. The browser
//                 never sees the app secret: it calls our /rtc/* endpoints and
//                 we forward to rtc.live.cloudflare.com with the Bearer token.
//
// The SFU means a group call is N uploads + N downloads per client instead of
// N² peer connections.

const RTC_BASE = 'https://rtc.live.cloudflare.com/v1'

// How long an unanswered call rings, and how long a callee's app has to say
// it is ringing before the call goes out as a notification instead.
export const RING_MS = 45000
export const ALERT_MS = 2500

export class CallBroker {
  constructor(hub) {
    this.hub = hub
    this.env = hub.env
  }

  configured() {
    return { enabled: Boolean(this.env.REALTIME_APP_ID && this.env.REALTIME_APP_SECRET) }
  }

  // ---------------------------------------------------------------- calls in progress
  // A call is kept in storage while it rings or runs: a callee who comes back
  // from its notification finds it even if the Durable Object slept between.
  // { callId, media, caller, started, participants, ringing, alerted, notified }
  get(room) { return this.hub.store.kvGet(`call:${room}`) }
  put(room, call) { this.hub.store.kvSet(`call:${room}`, call) }
  drop(room) { this.hub.store.kvDelete(`call:${room}`) }
  all() { return this.hub.store.kvList('call:').map(([k, call]) => [k.slice(5), call]) }

  // ---------------------------------------------------------------- signalling (over WS)
  signal(from, msg) {
    const { kind, room, callId } = msg
    if (!room || !this.hub.store.isMember(room, from)) return
    const members = this.hub.store.roomMembers(room).filter(u => u !== from)
    const relay = extra => {
      const payload = { t: 'call', kind, room, callId, from, ...extra }
      if (msg.to) this.hub.sendToUser(msg.to, payload)
      else for (const u of members) this.hub.sendToUser(u, payload)
    }
    const call = this.get(room)
    const current = call?.callId === callId ? call : null

    switch (kind) {
      case 'invite': {
        const media = msg.media === 'video' ? 'video' : 'audio'
        this.put(room, { callId, media, caller: from, started: Date.now(), participants: [from], ringing: members, alerted: [], notified: [] })
        relay({ media, caller: this.callerOf(from) })
        this.alert(room, callId).catch(() => {})
        break
      }
      case 'ringing': {
        // The callee's app is showing the call.
        if (!current || !current.ringing.includes(from)) return
        if (!current.alerted.includes(from)) current.alerted.push(from)
        this.put(room, current)
        this.hub.sendToUser(current.caller, { t: 'call', kind: 'ringing', room, callId, from })
        break
      }
      case 'accept': {
        if (current) {
          current.ringing = current.ringing.filter(u => u !== from)
          if (!current.participants.includes(from)) current.participants.push(from)
          this.put(room, current)
        }
        relay({})
        break
      }
      case 'tracks':
        // "I pushed these SFU tracks" — others pull them.
        relay({ tracks: msg.tracks, sessionId: msg.sessionId })
        break
      case 'decline':
      case 'cancel':
      case 'hangup': {
        if (current) {
          current.participants = current.participants.filter(u => u !== from)
          current.ringing = current.ringing.filter(u => u !== from)
          if (kind === 'cancel' && from === current.caller) {
            // Unanswered: whoever was reached by notification learns they missed it.
            if (msg.missed) this.notifyMissed(room, current).catch(() => {})
            this.drop(room)
          } else if (!current.participants.length && !current.ringing.length) this.drop(room)
          else this.put(room, current)
        }
        relay({ missed: Boolean(msg.missed) })
        if (kind === 'cancel' || (kind === 'hangup' && !this.get(room))) this.logCall(room, from, msg)
        break
      }
      default:
        relay({})
    }
  }

  callerOf(uid) {
    return this.hub.store.pub(this.hub.store.getUser(uid))
  }

  /**
   * Reach everyone the call rings for. A member with no app open gets a
   * notification at once; one whose app is open but hasn't said it's ringing
   * a moment later (iOS keeps a suspended app's socket open for a while).
   * The caller hears how each was reached: 'ringing' (from the callee),
   * 'notified', or 'unreachable' (no app open and no notifications).
   */
  async alert(room, callId, { wait = ALERT_MS } = {}) {
    const offline = this.get(room)?.ringing.filter(u => !this.hub.isOnline(u)) || []
    await this.notify(room, callId, offline)
    await new Promise(r => setTimeout(r, wait))
    const call = this.get(room)
    if (call?.callId !== callId) return
    await this.notify(room, callId, call.ringing.filter(u => !call.alerted.includes(u) && !call.notified.includes(u)))
  }

  async notify(room, callId, uids) {
    for (const uid of uids) {
      const call = this.get(room)
      if (call?.callId !== callId || !call.ringing.includes(uid) || call.notified.includes(uid)) continue
      const caller = this.hub.store.getUser(call.caller)
      const sent = await this.hub.pushTo(uid, {
        title: caller?.display || '来电',
        body: call.media === 'video' ? '邀请你视频通话' : '邀请你语音通话',
        tag: `call-${callId}`,
        link: `/?chat=${encodeURIComponent(room)}&call=${encodeURIComponent(callId)}`
      }, { ttl: Math.round(RING_MS / 1000), topic: `call-${callId}` })
      const latest = this.get(room)
      if (latest?.callId !== callId) continue
      if (sent) {
        latest.notified.push(uid)
        this.put(room, latest)
      }
      if (!latest.alerted.includes(uid)) {
        this.hub.sendToUser(latest.caller, { t: 'call', kind: sent ? 'notified' : 'unreachable', room, callId, from: uid })
      }
    }
  }

  /** Those still being rung, reached by notification, are told they missed it. */
  async notifyMissed(room, call) {
    const caller = this.hub.store.getUser(call.caller)
    for (const uid of call.notified.filter(u => call.ringing.includes(u))) {
      await this.hub.pushTo(uid, {
        title: caller?.display || '未接来电',
        body: call.media === 'video' ? '未接视频通话' : '未接语音通话',
        tag: `call-${call.callId}`,
        link: `/?chat=${encodeURIComponent(room)}`
      }, { topic: `call-${call.callId}` })
    }
  }

  /** A device connected: a call still ringing for its user rings there too. */
  onConnect(uid) {
    for (const [room, call] of this.all()) {
      if (Date.now() - call.started > RING_MS + 15000) { this.drop(room); continue }
      if (!call.ringing.includes(uid)) continue
      this.hub.sendToUser(uid, { t: 'call', kind: 'invite', room, callId: call.callId, from: call.caller, media: call.media, caller: this.callerOf(call.caller) })
    }
  }

  /**
   * A user's last socket closed. Someone in the call has left it; someone it
   * rings for has only gone to the background (iOS closes sockets there) and
   * keeps ringing, reached by notification.
   */
  onDisconnect(uid) {
    for (const [room, call] of this.all()) {
      if (call.participants.includes(uid)) {
        call.participants = call.participants.filter(u => u !== uid)
        for (const u of [...call.participants, ...call.ringing]) {
          this.hub.sendToUser(u, { t: 'call', kind: 'hangup', room, callId: call.callId, from: uid })
        }
        if (!call.participants.length) this.drop(room)
        else this.put(room, call)
      } else if (call.alerted.includes(uid)) {
        call.alerted = call.alerted.filter(u => u !== uid)
        this.put(room, call)
        this.notify(room, call.callId, [uid]).catch(() => {})
      }
    }
  }

  logCall(room, from, msg) {
    const label = msg.media === 'video' ? '视频通话' : '语音通话'
    const text = msg.missed ? `未接${label}` : `${label}已结束${msg.duration ? '，' + fmtDur(msg.duration) : ''}`
    this.hub.store.addMessage({ room, sender: from, ts: Date.now(), type: 'call', body: text, meta: { media: msg.media, duration: msg.duration || 0, missed: Boolean(msg.missed) } })
    const m = this.hub.store.lastMessage(room)
    this.hub.fanoutToRoom(room, { t: 'msg', msg: m })
  }

  // ---------------------------------------------------------------- media proxy (/rtc/*)
  async http(request, url, user) {
    if (!this.configured().enabled) return j({ ok: false, error: '通话服务未配置（需要 REALTIME_APP_ID / REALTIME_APP_SECRET）' }, 503)
    const path = url.pathname.replace(/^\/rtc/, '')

    if (path === '/turn' && request.method === 'POST') {
      return this.turn()
    }
    if (path === '/sessions/new' && request.method === 'POST') {
      return this.rtc('POST', '/sessions/new', await safeBody(request))
    }
    const mTracks = path.match(/^\/sessions\/([\w-]+)\/tracks\/new$/)
    if (mTracks && request.method === 'POST') {
      return this.rtc('POST', `/sessions/${mTracks[1]}/tracks/new`, await safeBody(request))
    }
    const mReneg = path.match(/^\/sessions\/([\w-]+)\/renegotiate$/)
    if (mReneg && request.method === 'PUT') {
      return this.rtc('PUT', `/sessions/${mReneg[1]}/renegotiate`, await safeBody(request))
    }
    const mClose = path.match(/^\/sessions\/([\w-]+)\/tracks\/close$/)
    if (mClose && request.method === 'PUT') {
      return this.rtc('PUT', `/sessions/${mClose[1]}/tracks/close`, await safeBody(request))
    }
    return j({ ok: false, error: 'not found' }, 404)
  }

  async rtc(method, apiPath, body) {
    const res = await fetch(`${RTC_BASE}/apps/${this.env.REALTIME_APP_ID}${apiPath}`, {
      method,
      headers: { Authorization: `Bearer ${this.env.REALTIME_APP_SECRET}`, 'content-type': 'application/json' },
      body: body ? JSON.stringify(body) : undefined
    })
    const text = await res.text()
    if (!res.ok) {
      // Say what the service said, so a failed call can be told apart from a refused microphone.
      let reason = ''
      try { reason = JSON.parse(text).errorDescription || '' } catch {}
      return j({ ok: false, error: `通话服务出错（${res.status}${reason ? `：${reason}` : ''}）` }, res.status)
    }
    return new Response(text, { status: res.status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } })
  }

  async turn() {
    if (!this.env.REALTIME_TURN_KEY_ID || !this.env.REALTIME_TURN_KEY_TOKEN) {
      // No TURN configured: hand back a public STUN server so same-network calls still work.
      return j({ ok: true, iceServers: [{ urls: 'stun:stun.cloudflare.com:3478' }] })
    }
    const res = await fetch(`${RTC_BASE}/turn/keys/${this.env.REALTIME_TURN_KEY_ID}/credentials/generate`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${this.env.REALTIME_TURN_KEY_TOKEN}`, 'content-type': 'application/json' },
      body: JSON.stringify({ ttl: 86400 })
    })
    const data = await res.json().catch(() => ({}))
    const ice = data.iceServers ? [data.iceServers].flat() : [{ urls: 'stun:stun.cloudflare.com:3478' }]
    return j({ ok: true, iceServers: ice })
  }
}

const j = (data, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } })

async function safeBody(request) {
  try { return await request.json() } catch { return {} }
}

function fmtDur(s) {
  s = Math.round(s)
  const m = Math.floor(s / 60)
  return `${m}:${String(s % 60).padStart(2, '0')}`
}
