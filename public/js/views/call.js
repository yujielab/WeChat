// Voice / video calling. Signalling (ring, accept, decline, hangup and "here
// are my published tracks") rides the app WebSocket; media goes through the
// Cloudflare Realtime SFU via our /rtc/* proxy, so each client uploads its
// tracks once and pulls everyone else's — no mesh.

import { h, icon } from '../ui/dom.js'
import { symbolEffect, replaceSymbol } from '../ui/symbols.js'
import { haptic } from '../ui/haptics.js'
import { state, chatInfo } from '../store.js'
import { api } from '../api.js'
import { toast } from './overlay.js'
import { placeOnSide } from '../ui/fold.js'
import { avatar } from './avatar.js'

export function createCalls({ socketSend }) {
  let active = null
  const current = call => active === call && !call.ended && !call.ending

  function browserProblem() {
    if (globalThis.isSecureContext === false) return '请使用 HTTPS 页面进行通话'
    if (!navigator.mediaDevices?.getUserMedia || typeof RTCPeerConnection !== 'function' || typeof MediaStream !== 'function') {
      return '当前浏览器不支持通话，请使用新版 Safari 或 Chrome'
    }
    return null
  }

  function start(roomId, media = 'audio') {
    if (active) return toast('已有通话进行中', { type: 'error' })
    if (!state.calls?.enabled) return toast('通话服务未配置（需要在 Cloudflare 开通 Realtime 应用）', { type: 'error', duration: 5000 })
    const problem = browserProblem()
    if (problem) return toast(problem, { type: 'error', duration: 6000 })
    const callId = `${Date.now()}${Math.floor(Math.random() * 1000)}`
    const call = active = newCall({ room: roomId, callId, media, role: 'caller' })
    socketSend({ t: 'call', kind: 'invite', room: roomId, callId, media })
    call.ringTimer = setTimeout(() => {
      if (!current(call) || call.answered) return
      toast('对方暂时无人接听')
      end(call)
    }, 35000)
    begin(call).catch(err => fail(call, err))
  }

  function onSignal(msg) {
    const { kind, room, callId } = msg
    if (kind === 'invite') return incoming(msg)
    const call = active
    if (!call || !current(call) || call.callId !== callId || call.room !== room) return
    if (kind === 'accept') {
      clearTimeout(call.ringTimer)
      call.answered = true
      call.ui.setStatus(call.pc?.connectionState === 'connected' ? (call.media === 'video' ? '' : '通话中') : '正在连接…')
      announceTracks(call)
    } else if (kind === 'tracks') queueTracks(call, msg.from, msg.sessionId, msg.tracks)
    else if (kind === 'decline') endSoon(call, '对方已拒绝')
    else if (kind === 'cancel') end(call, true)
    else if (kind === 'hangup') {
      if (call.answered) endSoon(call, '通话结束')
      else end(call, true)
    }
  }

  function incoming(msg) {
    if (active && active.callId === msg.callId && active.room === msg.room) return
    const problem = browserProblem()
    if (active || problem) {
      socketSend({ t: 'call', kind: 'decline', room: msg.room, callId: msg.callId, to: msg.from })
      if (problem && !active) toast(problem, { type: 'error', duration: 6000 })
      return
    }
    const call = active = newCall({ room: msg.room, callId: msg.callId, media: msg.media, role: 'callee', caller: msg.caller })
    call.ui.showIncoming(msg.caller, msg.media, {
      accept: () => {
        if (!current(call) || call.answered) return
        clearTimeout(call.ringTimer)
        call.answered = true
        call.ui.setStatus('正在连接…')
        socketSend({ t: 'call', kind: 'accept', room: call.room, callId: call.callId })
        begin(call).catch(err => fail(call, err))
      },
      decline: () => { if (current(call)) end(call) }
    })
    haptic()
    call.ringTimer = setTimeout(() => {
      if (!current(call) || call.answered) return
      socketSend({ t: 'call', kind: 'decline', room: call.room, callId: call.callId, missed: true })
      end(call, true)
    }, 35000)
  }

  async function begin(call) {
    const wantVideo = call.media === 'video'
    call.stage = 'media'
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: wantVideo ? { facingMode: 'user', width: 1280, height: 720 } : false })
    if (!current(call)) { stream.getTracks().forEach(track => track.stop()); return }
    call.stream = stream
    call.ui.attachLocal(stream, wantVideo)
    call.setupTimer = setTimeout(() => fail(call, setupError('通话连接超时，请检查网络或 Realtime 配置后重试')), 30000)

    call.stage = 'turn'
    const ice = await api.post('/rtc/turn')
    if (!current(call)) return
    if (!Array.isArray(ice?.iceServers) || ice.iceServers.some(server => !server || Array.isArray(server) || !server.urls)) {
      throw setupError('通话网络配置无效，请检查 TURN 配置')
    }
    call.stage = 'session'
    const session = await api.post('/rtc/sessions/new')
    if (!current(call)) return
    validResult(session)
    if (typeof session.sessionId !== 'string' || !/^[\w-]+$/.test(session.sessionId)) throw setupError('通话服务未返回有效会话，请检查 Realtime SFU 配置')
    call.sessionId = session.sessionId

    call.stage = 'publish'
    const pc = new RTCPeerConnection({ iceServers: ice.iceServers, bundlePolicy: 'max-bundle' })
    call.pc = pc
    pc.ontrack = e => { if (current(call)) call.ui.addRemoteTrack(e.track, e.streams[0]) }
    pc.onconnectionstatechange = () => {
      if (!current(call)) return
      if (['failed', 'closed'].includes(pc.connectionState)) endSoon(call, '连接已断开，请检查网络', false)
      if (pc.connectionState === 'connected') {
        if (call.answered) call.ui.setStatus(call.media === 'video' ? '' : '通话中')
        if (call.ready) clearTimeout(call.setupTimer)
        announceTracks(call)
      }
    }
    const transceivers = stream.getTracks().map(track => pc.addTransceiver(track, { direction: 'sendonly' }))
    const offer = await pc.createOffer()
    if (!current(call)) return
    await pc.setLocalDescription(offer)
    if (!current(call)) return
    await gatherIce(call)
    if (!current(call)) return
    const tracks = transceivers.map(tr => ({
      location: 'local', mid: tr.mid, trackName: `${call.userId}-${tr.sender.track.kind}`
    }))
    if (!tracks.length || tracks.some(track => typeof track.mid !== 'string')) throw setupError('浏览器未能准备音视频轨道，请刷新后重试')
    const res = await api.post(`/rtc/sessions/${call.sessionId}/tracks/new`, {
      sessionDescription: localDescription(pc), tracks
    })
    if (!current(call)) return
    validResult(res)
    validDescription(res.sessionDescription, 'answer')
    await pc.setRemoteDescription(res.sessionDescription)
    if (!current(call)) return
    call.localTracks = tracks.map(track => track.trackName)
    call.ready = true
    if (pc.connectionState === 'connected') clearTimeout(call.setupTimer)
    if (!call.startedAt) call.startedAt = Date.now()
    announceTracks(call)
    drainTracks(call)
  }

  function announceTracks(call) {
    if (!current(call) || !call.answered || !call.ready || call.pc?.connectionState !== 'connected') return
    socketSend({ t: 'call', kind: 'tracks', room: call.room, callId: call.callId, sessionId: call.sessionId, tracks: call.localTracks })
  }

  function queueTracks(call, uid, sessionId, trackNames) {
    if (!sessionId || typeof sessionId !== 'string' || uid === call.userId || !Array.isArray(trackNames)) return
    const names = [...new Set(trackNames.filter(name => typeof name === 'string' && name.length))]
    if (!names.length) return
    const key = JSON.stringify([uid, sessionId, names])
    if (call.peers.has(key)) return
    call.peers.add(key)
    call.pendingTracks.push({ sessionId, names })
    drainTracks(call)
  }

  function drainTracks(call) {
    if (!current(call) || !call.ready) return
    for (const item of call.pendingTracks.splice(0)) {
      // One SDP exchange at a time on this peer connection, including its PUT.
      call.negotiation = call.negotiation.then(() => current(call) && pullFrom(call, item)).catch(err => fail(call, err))
    }
  }

  async function pullFrom(call, { sessionId, names }) {
    call.stage = 'subscribe'
    const res = await api.post(`/rtc/sessions/${call.sessionId}/tracks/new`, {
      tracks: names.map(trackName => ({ location: 'remote', sessionId, trackName }))
    })
    if (!current(call)) return
    validResult(res)
    if (res.requiresImmediateRenegotiation) {
      validDescription(res.sessionDescription, 'offer')
      await call.pc.setRemoteDescription(res.sessionDescription)
      if (!current(call)) return
      const answer = await call.pc.createAnswer()
      if (!current(call)) return
      await call.pc.setLocalDescription(answer)
      if (!current(call)) return
      await gatherIce(call)
      if (!current(call)) return
      const updated = await api.put(`/rtc/sessions/${call.sessionId}/renegotiate`, { sessionDescription: localDescription(call.pc) })
      if (current(call)) validResult(updated)
    }
  }

  function gatherIce(call) {
    const pc = call.pc
    if (pc.iceGatheringState === 'complete') return Promise.resolve()
    return new Promise((resolve, reject) => {
      let timer
      const finish = error => {
        clearTimeout(timer)
        pc.removeEventListener('icegatheringstatechange', change)
        call.cleanups.delete(cancel)
        error ? reject(error) : resolve()
      }
      const change = () => { if (pc.iceGatheringState === 'complete') finish() }
      const cancel = () => finish()
      call.cleanups.add(cancel)
      pc.addEventListener('icegatheringstatechange', change)
      timer = setTimeout(() => finish(setupError('网络穿透协商超时，请检查网络或 TURN 配置')), 12000)
      change()
    })
  }

  function localDescription(pc) {
    validDescription(pc.localDescription, pc.localDescription?.type)
    return { type: pc.localDescription.type, sdp: pc.localDescription.sdp }
  }

  function validDescription(description, type) {
    if (!description || !['offer', 'answer'].includes(type) || description.type !== type || typeof description.sdp !== 'string' || !description.sdp.trim()) {
      throw setupError('通话服务未返回有效的媒体协商信息，请重试')
    }
  }

  function validResult(data) {
    if (!data || typeof data !== 'object' || data.errorCode || data.ok === false || data.tracks?.some?.(track => track?.errorCode)) {
      throw setupError('通话媒体协商失败，请检查 Realtime SFU 配置后重试')
    }
  }

  function setupError(message) {
    return Object.assign(new Error(message), { name: 'CallSetupError' })
  }

  function errorMessage(call, err) {
    const devices = call.media === 'video' ? '麦克风和摄像头' : '麦克风'
    if (['NotAllowedError', 'SecurityError'].includes(err?.name)) return `请允许${devices}权限后重试`
    if (['NotFoundError', 'DevicesNotFoundError'].includes(err?.name)) return `未找到可用的${devices}`
    if (['NotReadableError', 'TrackStartError'].includes(err?.name)) return `${devices}无法使用，请关闭占用它的其他应用后重试`
    if (err?.name === 'OverconstrainedError') return '摄像头不支持当前采集设置，请更换摄像头或浏览器'
    if (err?.status === 401) return '登录已过期，请刷新页面后重试'
    if (err?.name === 'CallSetupError' || typeof err?.status === 'number') return err.message || '通话服务请求失败，请重试'
    return call.stage === 'media' ? `无法开启${devices}，请检查设备权限` : '浏览器未能完成通话连接，请刷新页面后重试'
  }

  function fail(call, err) {
    if (!current(call)) return
    toast(errorMessage(call, err), { type: 'error', duration: 6500 })
    end(call)
  }

  function endSoon(call, label, silent = true) {
    if (!current(call)) return
    call.ending = true
    call.ui.setStatus(label)
    clearTimeout(call.ringTimer)
    clearTimeout(call.setupTimer)
    call.endTimer = setTimeout(() => end(call, silent), 900)
  }

  function end(call = active, silent = false) {
    if (!call || call.ended) return
    call.ended = true
    if (active === call) active = null
    clearTimeout(call.ringTimer)
    clearTimeout(call.setupTimer)
    clearTimeout(call.endTimer)
    for (const cleanup of call.cleanups) cleanup()
    try { call.stream?.getTracks().forEach(track => track.stop()) } catch {}
    try { call.pc?.close() } catch {}
    if (!silent) {
      const kind = call.answered ? 'hangup' : call.role === 'caller' ? 'cancel' : 'decline'
      const duration = call.startedAt ? (Date.now() - call.startedAt) / 1000 : 0
      socketSend({ t: 'call', kind, room: call.room, callId: call.callId, media: call.media, duration, missed: !call.answered })
    }
    call.ui.destroy()
  }

  function newCall(info) {
    const call = { ...info, userId: state.me?.id, answered: false, ready: false, peers: new Set(), pendingTracks: [], negotiation: Promise.resolve(), cleanups: new Set() }
    call.ui = createCallUI({
      onHangup: () => end(call),
      onToggleMic: on => call.stream?.getAudioTracks().forEach(track => (track.enabled = on)),
      onToggleCam: on => call.stream?.getVideoTracks().forEach(track => (track.enabled = on))
    })
    if (info.role === 'caller') call.ui.showOutgoing(chatInfo(info.room), info.media)
    return call
  }

  return { start, onSignal, get busy() { return Boolean(active) } }
}

// ---------------------------------------------------------------- call UI
function createCallUI({ onHangup, onToggleMic, onToggleCam }) {
  const root = h('div', { class: 'call', role: 'dialog', 'aria-modal': 'true' })
  const stage = h('div', { class: 'call-stage' })
  const remoteVideo = h('video', { class: 'call-remote', autoplay: true, playsinline: true })
  const localVideo = h('video', { class: 'call-local', autoplay: true, playsinline: true, muted: true })
  const poster = h('div', { class: 'call-poster' })
  const name = h('div', { class: 'call-name' })
  const status = h('div', { class: 'call-status' })
  const remoteStream = new MediaStream()
  remoteVideo.srcObject = remoteStream

  const micBtn = toggle('mic', 'mic-slash', '静音', true, on => onToggleMic(on))
  const camBtn = toggle('video', 'video-slash', '摄像头', true, on => onToggleCam(on))
  const hangBtn = h('button', { class: 'call-btn hang', type: 'button', 'aria-label': '挂断' }, icon('phone-down'))
  hangBtn.addEventListener('click', onHangup)
  const controls = h('div', { class: 'call-controls' }, micBtn.el, camBtn.el, hangBtn)

  stage.append(remoteVideo, poster, h('div', { class: 'call-head' }, name, status), localVideo)
  root.append(stage, controls)

  const incomingActions = h('div', { class: 'call-incoming' })

  let hasVideo = false
  let ringing = null
  function mount() { document.getElementById('overlays').append(root); placeOnSide(root, 'thread'); requestAnimationFrame(() => root.classList.add('on')) }

  return {
    showOutgoing(room, media) {
      hasVideo = media === 'video'
      root.classList.toggle('video', hasVideo)
      name.textContent = room?.name || '通话'
      status.textContent = media === 'video' ? '视频通话 · 正在呼叫…' : '正在呼叫…'
      poster.append(avatar(room?.peer?.id, room?.name || '', { size: 112, room: room?.kind === 'group' }))
      camBtn.el.hidden = !hasVideo
      mount()
    },
    showIncoming(caller, media, { accept, decline }) {
      hasVideo = media === 'video'
      root.classList.toggle('video', hasVideo)
      name.textContent = caller?.display || '来电'
      status.textContent = media === 'video' ? '邀请你视频通话' : '邀请你语音通话'
      poster.append(avatar(caller?.id, caller?.display || '', { size: 112 }))
      const yes = h('button', { class: 'call-btn accept', type: 'button', 'aria-label': '接听' }, icon(media === 'video' ? 'video' : 'phone-fill'))
      const no = h('button', { class: 'call-btn hang', type: 'button', 'aria-label': '拒绝' }, icon('phone-down'))
      yes.addEventListener('click', () => { ringing?.stop(); incomingActions.remove(); controls.hidden = false; accept() })
      no.addEventListener('click', () => { ringing?.stop(); decline() })
      incomingActions.append(no, yes)
      controls.hidden = true
      root.append(incomingActions)
      camBtn.el.hidden = !hasVideo
      mount()
      // The answer button keeps bouncing while the call rings.
      ringing = symbolEffect(yes.querySelector('.icon'), 'bounce', { repeat: true })
    },
    setStatus(text) { status.textContent = text },
    attachLocal(stream, video) {
      hasVideo = video
      root.classList.toggle('video', video)
      if (video) localVideo.srcObject = stream
      localVideo.hidden = !video
    },
    addRemoteTrack(track, stream) {
      remoteStream.addTrack(track)
      if (track.kind === 'video') { root.classList.add('video', 'remote-video'); remoteVideo.hidden = false; poster.hidden = true }
      remoteVideo.play?.().catch(() => {})
    },
    destroy() {
      ringing?.stop()
      root.classList.remove('on')
      setTimeout(() => root.remove(), 260)
    }
  }
}

function toggle(iconOn, iconOff, label, initial, onChange) {
  let on = initial
  const el = h('button', { class: ['call-btn', 'toggle', on && 'active'], type: 'button', 'aria-pressed': String(on), 'aria-label': label }, icon(iconOn))
  el.addEventListener('click', () => {
    on = !on
    el.classList.toggle('active', on)
    el.setAttribute('aria-pressed', String(on))
    replaceSymbol(el.querySelector('.icon'), on ? iconOn : iconOff)
    onChange(on)
  })
  return { el }
}
