// Voice / video calling. Signalling (ring, accept, decline, hangup and "here
// are my published tracks") rides the app WebSocket; media goes through the
// Cloudflare Realtime SFU via our /rtc/* proxy, so each client uploads its
// tracks once and pulls everyone else's — no mesh.

import { h, icon } from '../ui/dom.js'
import { haptic } from '../ui/haptics.js'
import { state, chatInfo, nameOf } from '../store.js'
import { api } from '../api.js'
import { toast } from './overlay.js'
import { avatar } from './avatar.js'

export function createCalls({ socketSend }) {
  let active = null // { room, callId, media, role, pc, sessionId, stream, peers, ui, startedAt, ringTimer }

  function start(roomId, media = 'audio') {
    if (active) return toast('已有通话进行中', { type: 'error' })
    if (!state.calls?.enabled) return toast('通话服务未配置（需要在 Cloudflare 开通 Realtime 应用）', { type: 'error', duration: 5000 })
    const callId = `${Date.now()}${Math.floor(Math.random() * 1000)}`
    active = newCall({ room: roomId, callId, media, role: 'caller' })
    socketSend({ t: 'call', kind: 'invite', room: roomId, callId, media })
    begin().catch(fail)
  }

  function onSignal(msg) {
    const { kind, room, callId } = msg
    if (kind === 'invite') return incoming(msg)
    if (!active || active.callId !== callId) return
    if (kind === 'accept') { active.ui.setStatus('已接通'); active.answered = true; announceTracks() }
    else if (kind === 'tracks') pullFrom(msg.from, msg.sessionId, msg.tracks)
    else if (kind === 'decline') { active.ui.setStatus('对方已拒绝'); endSoon('对方已拒绝') }
    else if (kind === 'cancel') end(true)
    else if (kind === 'hangup') { if (active.answered) endSoon('通话结束'); else end(true) }
  }

  function incoming(msg) {
    if (active) { // busy
      socketSend({ t: 'call', kind: 'decline', room: msg.room, callId: msg.callId, to: msg.from })
      return
    }
    active = newCall({ room: msg.room, callId: msg.callId, media: msg.media, role: 'callee', caller: msg.caller })
    active.ui.showIncoming(msg.caller, msg.media, {
      accept: () => { socketSend({ t: 'call', kind: 'accept', room: msg.room, callId: msg.callId }); active.answered = true; begin().catch(fail) },
      decline: () => { socketSend({ t: 'call', kind: 'decline', room: msg.room, callId: msg.callId }); end(true) }
    })
    haptic()
    active.ringTimer = setTimeout(() => { if (active && !active.answered) { socketSend({ t: 'call', kind: 'decline', room: msg.room, callId: msg.callId, missed: true }); end(true) } }, 35000)
  }

  async function begin() {
    clearTimeout(active.ringTimer)
    const wantVideo = active.media === 'video'
    active.stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: wantVideo ? { facingMode: 'user', width: 1280, height: 720 } : false })
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
    toast(err?.name === 'NotAllowedError' ? '需要麦克风/摄像头权限' : '无法建立通话', { type: 'error' })
    end(true)
  }
  function end(silent) {
    if (!active) return
    const a = active
    active = null
    clearTimeout(a.ringTimer)
    try { a.stream?.getTracks().forEach(t => t.stop()) } catch {}
    try { a.pc?.close() } catch {}
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
  function mount() { document.getElementById('overlays').append(root); requestAnimationFrame(() => root.classList.add('on')) }

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
      const yes = h('button', { class: 'call-btn accept', type: 'button', 'aria-label': '接听' }, icon(media === 'video' ? 'video' : 'phone'))
      const no = h('button', { class: 'call-btn hang', type: 'button', 'aria-label': '拒绝' }, icon('phone-down'))
      yes.addEventListener('click', () => { incomingActions.remove(); controls.hidden = false; accept() })
      no.addEventListener('click', decline)
      incomingActions.append(no, yes)
      controls.hidden = true
      root.append(incomingActions)
      camBtn.el.hidden = !hasVideo
      mount()
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
    el.replaceChildren(icon(on ? iconOn : iconOff))
    onChange(on)
  })
  return { el }
}
