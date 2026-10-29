// Voice / video calling. Signalling (ring, accept, decline, hangup and "here
// are my published tracks") rides the app WebSocket; media goes through the
// Cloudflare Realtime SFU via our /rtc/* proxy, so each client uploads its
// tracks once and pulls everyone else's — no mesh.

import { h, icon } from '../ui/dom.js'
import { symbolEffect, replaceSymbol } from '../ui/symbols.js'
import { haptic } from '../ui/haptics.js'
import { state, chatInfo, nameOf } from '../store.js'
import { api } from '../api.js'
import { toast } from './overlay.js'
import { placeOnSide } from '../ui/fold.js'
import { avatar } from './avatar.js'

// An unanswered call gives up after this long (the server keeps it ringing as long).
const RING_MS = 45000
// How the caller hears each callee was reached, best first.
const REACH = ['ringing', 'notified', 'unreachable']
const REACH_TEXT = { ringing: '对方响铃中…', notified: '已通过通知提醒对方…', unreachable: '对方没有打开应用，也没有开启通知' }

export function createCalls({ socketSend }) {
  let active = null // { room, callId, media, role, pc, sessionId, stream, peers, ui, startedAt, ringTimer, reach }

  function start(roomId, media = 'audio') {
    if (active) return toast('已有通话进行中', { type: 'error' })
    if (!state.calls?.enabled) return toast('通话服务未配置（需要在 Cloudflare 开通 Realtime 应用）', { type: 'error', duration: 5000 })
    const callId = `${Date.now()}${Math.floor(Math.random() * 1000)}`
    active = newCall({ room: roomId, callId, media, role: 'caller' })
    socketSend({ t: 'call', kind: 'invite', room: roomId, callId, media })
    active.ringTimer = setTimeout(() => { if (active?.callId === callId && !active.answered) endSoon('无人接听') }, RING_MS)
    begin().catch(fail)
  }

  function onSignal(msg) {
    const { kind, room, callId } = msg
    if (kind === 'invite') return incoming(msg)
    if (!active || active.callId !== callId) return
    if (kind === 'accept') { clearTimeout(active.ringTimer); active.ui.setStatus('已接通'); active.answered = true; announceTracks() }
    else if (kind === 'tracks') pullFrom(msg.from, msg.sessionId, msg.tracks)
    else if (REACH.includes(kind)) reached(kind)
    else if (kind === 'decline') endSoon(msg.missed ? '无人接听' : '对方已拒绝')
    else if (kind === 'cancel') end(true)
    else if (kind === 'hangup') { if (active.answered) endSoon('通话结束'); else end(true) }
  }

  // The caller's status says how the call is reaching the other side.
  function reached(kind) {
    if (active.role !== 'caller' || active.answered) return
    if (active.reach && REACH.indexOf(active.reach) <= REACH.indexOf(kind)) return
    active.reach = kind
    active.ui.setStatus(active.media === 'video' ? `视频通话 · ${REACH_TEXT[kind]}` : REACH_TEXT[kind])
  }

  function incoming(msg) {
    // The same call again: this device reconnected while it rang.
    if (active?.callId === msg.callId) return socketSend({ t: 'call', kind: 'ringing', room: msg.room, callId: msg.callId })
    if (active) { // busy
      socketSend({ t: 'call', kind: 'decline', room: msg.room, callId: msg.callId, to: msg.from })
      return
    }
    active = newCall({ room: msg.room, callId: msg.callId, media: msg.media, role: 'callee', caller: msg.caller })
    active.ui.showIncoming(msg.caller, msg.media, {
      accept: () => { socketSend({ t: 'call', kind: 'accept', room: msg.room, callId: msg.callId }); active.answered = true; begin().catch(fail) },
      decline: () => { socketSend({ t: 'call', kind: 'decline', room: msg.room, callId: msg.callId }); end(true) }
    })
    // Tell the caller it rings here, so it isn't also sent as a notification.
    socketSend({ t: 'call', kind: 'ringing', room: msg.room, callId: msg.callId })
    haptic()
    active.ringTimer = setTimeout(() => { if (active && !active.answered) { socketSend({ t: 'call', kind: 'decline', room: msg.room, callId: msg.callId, missed: true }); end(true) } }, RING_MS)
  }

  async function begin() {
    if (active.role === 'callee') clearTimeout(active.ringTimer)
    const wantVideo = active.media === 'video'
    // iOS: route the call like a call (microphone and receiver together).
    if (navigator.audioSession) navigator.audioSession.type = 'play-and-record'
    const call = active
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: wantVideo ? { facingMode: 'user', width: 1280, height: 720 } : false })
    // Hung up while the permission prompt was open: let the microphone go.
    if (active !== call) { stream.getTracks().forEach(t => t.stop()); return }
    active.stream = stream
    active.ui.attachLocal(active.stream, wantVideo)
    const ice = await api.post('/rtc/turn').then(r => r.iceServers).catch(() => [{ urls: 'stun:stun.cloudflare.com:3478' }])
    const pc = new RTCPeerConnection({ iceServers: ice, bundlePolicy: 'max-bundle' })
    active.pc = pc
    pc.ontrack = e => active.ui.addRemoteTrack(e.track, e.streams[0])
    pc.onconnectionstatechange = () => {
      if (['failed', 'closed'].includes(pc.connectionState)) endSoon('连接已断开')
      if (pc.connectionState === 'connected') active.ui.setStatus(active.media === 'video' ? '' : '通话中')
    }
    // Publish local tracks to the SFU.
    const transceivers = active.stream.getTracks().map(t => pc.addTransceiver(t, { direction: 'sendonly' }))
    const offer = await pc.createOffer()
    await pc.setLocalDescription(offer)
    const session = await api.post('/rtc/sessions/new')
    active.sessionId = session.sessionId
    const tracks = transceivers.map(tr => ({
      location: 'local',
      mid: tr.mid,
      trackName: `${state.me.id}-${tr.sender.track.kind}`
    }))
    const res = await api.post(`/rtc/sessions/${active.sessionId}/tracks/new`, {
      sessionDescription: { type: 'offer', sdp: offer.sdp },
      tracks
    })
    await pc.setRemoteDescription(res.sessionDescription)
    active.localTracks = tracks.map(t => t.trackName)
    if (active.answered) announceTracks()
    if (!active.startedAt) active.startedAt = Date.now()
  }

  function announceTracks() {
    if (!active?.sessionId || !active.localTracks) return
    socketSend({ t: 'call', kind: 'tracks', room: active.room, callId: active.callId, sessionId: active.sessionId, tracks: active.localTracks })
  }

  async function pullFrom(uid, sessionId, trackNames) {
    if (!active?.pc || !sessionId || uid === state.me.id) return
    active.peers ??= new Set()
    const key = trackNames.join(',')
    if (active.peers.has(key)) return
    active.peers.add(key)
    try {
      const res = await api.post(`/rtc/sessions/${active.sessionId}/tracks/new`, {
        tracks: trackNames.map(trackName => ({ location: 'remote', sessionId, trackName }))
      })
      if (res.requiresImmediateRenegotiation && res.sessionDescription) {
        await active.pc.setRemoteDescription(res.sessionDescription)
        const answer = await active.pc.createAnswer()
        await active.pc.setLocalDescription(answer)
        await api.put(`/rtc/sessions/${active.sessionId}/renegotiate`, { sessionDescription: { type: 'answer', sdp: answer.sdp } })
      }
    } catch (err) {
      console.warn('pull failed', err)
    }
  }

  function endSoon(label) {
    active?.ui.setStatus(label)
    setTimeout(() => end(), 900)
  }
  function fail(err) {
    if (!active) return
    const reason = err?.name === 'NotAllowedError' ? '需要麦克风/摄像头权限'
      : err?.name === 'NotFoundError' ? '找不到麦克风或摄像头'
      : err?.status !== undefined ? err.message
      : `无法建立通话${err?.name && err.name !== 'Error' ? `（${err.name}）` : ''}`
    toast(reason, { type: 'error', duration: 5000 })
    // The other side stops ringing too.
    end(false)
  }
  function end(silent) {
    if (!active) return
    const a = active
    active = null
    clearTimeout(a.ringTimer)
    try { a.stream?.getTracks().forEach(t => t.stop()) } catch {}
    try { a.pc?.close() } catch {}
    if (navigator.audioSession) navigator.audioSession.type = 'auto'
    if (!silent && a.answered) {
      const duration = a.startedAt ? (Date.now() - a.startedAt) / 1000 : 0
      socketSend({ t: 'call', kind: 'hangup', room: a.room, callId: a.callId, media: a.media, duration })
    } else if (!silent && a.role === 'caller') {
      socketSend({ t: 'call', kind: 'cancel', room: a.room, callId: a.callId, media: a.media, missed: true })
    }
    a.ui.destroy()
  }

  function newCall(info) {
    const ui = createCallUI({
      onHangup: () => end(),
      onToggleMic: on => active?.stream?.getAudioTracks().forEach(t => (t.enabled = on)),
      onToggleCam: on => active?.stream?.getVideoTracks().forEach(t => (t.enabled = on))
    })
    if (info.role === 'caller') {
      const room = chatInfo(info.room)
      ui.showOutgoing(room, info.media)
    }
    return { ...info, ui, answered: false }
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
