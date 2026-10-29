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
    return { enabled: Boolean(secret(this.env.REALTIME_APP_ID) && secret(this.env.REALTIME_APP_SECRET)) }
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
    if (!this.configured().enabled) return j({ ok: false, code: 'RTC_CONFIG', error: '通话服务未配置（需要 REALTIME_APP_ID / REALTIME_APP_SECRET）' }, 503)
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
    try {
      const res = await fetch(`${RTC_BASE}/apps/${encodeURIComponent(secret(this.env.REALTIME_APP_ID))}${apiPath}`, {
        method,
        headers: { Authorization: `Bearer ${secret(this.env.REALTIME_APP_SECRET)}`, 'content-type': 'application/json' },
        body: body ? JSON.stringify(body) : undefined
      })
      if (res.status === 204) return new Response(null, { status: 204, headers: { 'cache-control': 'no-store' } })
      const data = await res.json().catch(() => null)
      if (!res.ok || upstreamError(data)) return upstreamFailure('RTC', res.status, data, apiPath)
      if (!record(data)) return failure('RTC_RESPONSE', '通话服务返回了无效响应，请稍后重试', 502)
      return j(data, res.status)
    } catch {
      return failure('RTC_SERVICE', '暂时无法连接 Cloudflare 通话服务，请稍后重试', 503)
    }
  }

  async turn() {
    if (!secret(this.env.REALTIME_TURN_KEY_ID) || !secret(this.env.REALTIME_TURN_KEY_TOKEN)) {
      // No TURN configured: hand back a public STUN server so same-network calls still work.
      return j({ ok: true, iceServers: [{ urls: 'stun:stun.cloudflare.com:3478' }] })
    }
    try {
      const res = await fetch(`${RTC_BASE}/turn/keys/${encodeURIComponent(secret(this.env.REALTIME_TURN_KEY_ID))}/credentials/generate-ice-servers`, {
        method: 'POST',
        headers: { Authorization: `Bearer ${secret(this.env.REALTIME_TURN_KEY_TOKEN)}`, 'content-type': 'application/json' },
        body: JSON.stringify({ ttl: 86400 })
      })
      const data = await res.json().catch(() => null)
      if (!res.ok || upstreamError(data)) return upstreamFailure('TURN', res.status, data)
      // The current endpoint returns an array; accept the older object shape
      // too. Never nest that array inside another array for RTCPeerConnection.
      const servers = Array.isArray(data?.iceServers) ? data.iceServers : record(data?.iceServers) ? [data.iceServers] : []
      if (!servers.length || !servers.every(validIceServer)) {
        return failure('TURN_RESPONSE', 'TURN 服务返回了无效连接配置，请检查 TURN Key 后重试', 502)
      }
      return j({ ok: true, iceServers: servers })
    } catch {
      return failure('TURN_SERVICE', '暂时无法连接 Cloudflare TURN 服务，请稍后重试', 503)
    }
  }
}

const j = (data, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } })

const secret = value => typeof value === 'string' ? value.trim() : ''
const record = value => value !== null && typeof value === 'object' && !Array.isArray(value)
const failure = (code, error, status, upstreamStatus) =>
  j({ ok: false, code, error, ...(upstreamStatus ? { upstreamStatus } : {}) }, status)

function upstreamError(data) {
  if (!record(data)) return null
  return data.errorCode || (data.error || data.ok === false || data.success === false ? 'upstream_error' : null) ||
    (Array.isArray(data.tracks) ? data.tracks.find(track => track?.errorCode)?.errorCode : null) ||
    (Array.isArray(data.errors) && data.errors.length ? 'upstream_error' : null)
}

function upstreamFailure(service, status, data, apiPath) {
  const code = upstreamError(data)
  if (status === 401 || status === 403 || code === 'unauthorized') {
    return failure(`${service}_AUTH`, service === 'RTC'
      ? 'SFU 凭据校验失败，请检查 REALTIME_APP_ID 和 REALTIME_APP_SECRET 是否来自同一个 Serverless SFU 应用'
      : 'TURN 凭据校验失败，请检查 REALTIME_TURN_KEY_ID 和 REALTIME_TURN_KEY_TOKEN', 502, status)
  }
  if (service === 'RTC' && (status === 404 || code === 'not_found')) {
    return apiPath === '/sessions/new'
      ? failure('RTC_APP_NOT_FOUND', 'SFU 应用不存在，请检查 REALTIME_APP_ID 是否来自 Serverless SFU', 502, status)
      : failure('RTC_MEDIA', '通话会话或媒体已失效，请重新发起通话', 502, status)
  }
  if (status === 429) return failure(`${service}_RATE_LIMIT`, '通话服务请求过于频繁，请稍后重试', 503, status)
  if (service === 'RTC' && ['decoding_error', 'invalid_params', 'invalid_session_description'].includes(code)) {
    return failure('RTC_NEGOTIATION', '通话媒体协商失败，请刷新页面后重新发起通话', 502, status)
  }
  if (service === 'RTC' && ['not_found_track_error', 'empty_track_error', 'session_error'].includes(code)) {
    return failure('RTC_MEDIA', '通话媒体连接尚未就绪，请重新发起通话', 502, status)
  }
  // Upstream descriptions and response bodies may contain credentials or SDP.
  // Only stable, public diagnostics leave the backend.
  return failure(`${service}_SERVICE`, service === 'RTC'
    ? 'Cloudflare 通话服务暂时不可用，请稍后重试'
    : 'Cloudflare TURN 服务请求失败，请检查 TURN 配置或稍后重试', status >= 500 ? 503 : 502, status)
}

function validIceServer(server) {
  if (!record(server)) return false
  const urls = Array.isArray(server.urls) ? server.urls : [server.urls]
  return urls.length > 0 && urls.every(url => typeof url === 'string' && /^(stun|stuns|turn|turns):\S+$/.test(url)) &&
    (server.username === undefined || typeof server.username === 'string') &&
    (server.credential === undefined || typeof server.credential === 'string')
}

async function safeBody(request) {
  try { return await request.json() } catch { return {} }
}

function fmtDur(s) {
  s = Math.round(s)
  const m = Math.floor(s / 60)
  return `${m}:${String(s % 60).padStart(2, '0')}`
}
