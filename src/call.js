// Voice/video calling on Cloudflare Realtime (the SFU formerly called Calls).
//
// Two halves:
//   signalling  — ring / accept / decline / hangup and "here are my track ids"
//                 are relayed between members over the existing WebSocket.
//   media       — each client speaks WebRTC to the Realtime SFU. The browser
//                 never sees the app secret: it calls our /rtc/* endpoints and
//                 we forward to rtc.live.cloudflare.com with the Bearer token.
//
// The SFU means a group call is N uploads + N downloads per client instead of
// N² peer connections.

const RTC_BASE = 'https://rtc.live.cloudflare.com/v1'

export class CallBroker {
  constructor(hub) {
    this.hub = hub
    this.env = hub.env
    this.active = new Map() // roomId -> { callId, media, participants:Set<uid>, ringing:Set<uid> }
  }

  configured() {
    return { enabled: Boolean(this.env.REALTIME_APP_ID && this.env.REALTIME_APP_SECRET) }
  }

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

    switch (kind) {
      case 'invite': {
        const media = msg.media === 'video' ? 'video' : 'audio'
        this.active.set(room, { callId, media, participants: new Set([from]), ringing: new Set(members) })
        relay({ media, caller: this.hub.store.pub(this.hub.store.getUser(from)) })
        break
      }
      case 'accept': {
        const call = this.active.get(room)
        if (call) { call.participants.add(from); call.ringing.delete(from) }
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
        const call = this.active.get(room)
        if (call) {
          call.participants.delete(from)
          call.ringing.delete(from)
          if (call.participants.size <= (call.ringing.size ? 1 : 0) && kind !== 'decline') {
            // last one standing or caller cancelled → end the call
          }
          if (call.participants.size === 0 && call.ringing.size === 0) this.active.delete(room)
        }
        relay({})
        if (kind === 'cancel' || (kind === 'hangup' && !this.active.get(room))) this.logCall(room, from, msg)
        break
      }
      default:
        relay({})
    }
  }

  onDisconnect(uid) {
    for (const [room, call] of this.active) {
      if (call.participants.has(uid) || call.ringing.has(uid)) {
        call.participants.delete(uid)
        call.ringing.delete(uid)
        for (const u of [...call.participants, ...call.ringing]) {
          this.hub.sendToUser(u, { t: 'call', kind: 'hangup', room, callId: call.callId, from: uid })
        }
        if (call.participants.size === 0) this.active.delete(room)
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
    const ice = data.iceServers ? [data.iceServers] : [{ urls: 'stun:stun.cloudflare.com:3478' }]
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
