// Voice / video calling. Signalling (ring, accept, decline, hangup, "here are
// my published tracks" and "my microphone / camera is on or off") rides the
// app WebSocket; media goes through the Cloudflare Realtime SFU via our
// /rtc/* proxy, so each client uploads its tracks once and pulls everyone
// else's — no mesh.
//
// The call screen fills the screen folded; unfolded it takes one column —
// the one beside the conversation, so the two sit side by side and both stay
// in use. At any time it can shrink into a picture in picture that floats
// over the app (the button at its top, a swipe down, or Escape): the app is
// in use underneath, the little window can be thrown into any corner or
// tucked against a side, and a tap brings the call back where it was put.

import { h, icon, announce, storage } from '../ui/dom.js'
import { symbolEffect, replaceSymbol } from '../ui/symbols.js'
import { haptic } from '../ui/haptics.js'
import { state, chatInfo, nameOf, avatarOf } from '../store.js'
import { api } from '../api.js'
import { toast, lockApp, unlockApp, openMenu } from './overlay.js'
import { placeOnSide } from '../ui/fold.js'
import { getLayout, onLayout } from '../ui/viewport.js'
import { avatar } from './avatar.js'
import { backdropLayer } from '../ui/backdrops.js'
import { edgeThemeColor } from '../ui/appearance.js'
import { spring, velocityTracker, project, rubberband } from '../ui/spring.js'
import { floatTile } from '../ui/float.js'
import { CORNERS, nearestCorner, unstashCorner, cornerToward } from '../ui/corners.js'
import { primeTones, releaseTones, ringback, ringtone, endTone } from '../ui/tones.js'
import { callClock } from '../ui/format.js'

// An unanswered call gives up after this long (the server keeps it ringing as long).
const RING_MS = 45000
// Someone else's connection must stay down this long before it is shown or read out.
const SHAKY_MS = 2000
// How many times a pull of the other side's tracks is retried while its media starts.
const PULL_TRIES = 6
// How the caller hears each callee was reached, best first.
const REACH = ['ringing', 'notified', 'unreachable']
const REACH_TEXT = { ringing: 'Ringing…', notified: 'They were notified…', unreachable: "They can't answer right now" }

const isGroup = room => chatInfo(room)?.kind === 'group'

export function createCalls({ socketSend, connected = () => true, onCover = () => {}, focusBack = () => {} }) {
  let active = null // { room, callId, media, role, pc, sessionId, stream, ui, answered, liveAt, peers, remote, muted, camOff, … }

  // Back from the background, a video call keeps the screen awake again.
  document.addEventListener('visibilitychange', () => {
    if (!document.hidden && active?.media === 'video' && active.stream) keepAwake(active)
  })

  function start(roomId, media = 'audio') {
    if (active) {
      // The call under way: its own conversation's call button brings it back.
      if (active.room === roomId) return active.ui.expand()
      return toast('You’re already on a call', { type: 'error' })
    }
    if (!state.calls?.enabled) return toast("Calls aren't available right now", { type: 'error' })
    // The invitation travels on the socket: without it the other side would never ring.
    if (!connected()) return toast('Still connecting…', { type: 'error' })
    // Inside the tap: the ringback can sound once the other side rings.
    primeTones()
    const callId = `${Date.now()}${Math.floor(Math.random() * 1000)}`
    active = newCall({ room: roomId, callId, media, role: 'caller' })
    socketSend({ t: 'call', kind: 'invite', room: roomId, callId, media })
    active.ringTimer = setTimeout(() => { if (active?.callId === callId && !active.answered) endSoon('No answer', 'missed') }, RING_MS)
    begin().catch(fail)
  }

  function onSignal(msg) {
    const { kind, callId } = msg
    if (kind === 'invite') return incoming(msg)
    if (!active || active.callId !== callId) return
    const call = active
    if (kind === 'accept') accepted(call, msg)
    else if (kind === 'tracks') pullFrom(msg)
    else if (kind === 'state') remoteState(call, msg)
    else if (REACH.includes(kind)) reached(call, kind)
    else if (kind === 'decline') declined(call, msg)
    else if (kind === 'cancel') end(true)
    else if (kind === 'hangup') left(call, msg)
    else if (kind === 'unstable') unstable(call, msg, true)
    else if (kind === 'back') unstable(call, msg, false)
    else if (kind === 'alive') alive(call)
    else if (kind === 'gone') gone(call)
  }

  /** After the socket comes back: the server says whether the call survived. */
  function resync() {
    if (!active || active.ending) return
    socketSend({ t: 'call', kind: 'check', room: active.room, callId: active.callId })
  }
  function alive(call) {
    if (!call.answered) return
    // Our tracks again, for anyone who missed them; the clock or the picture clears Connecting….
    announceTracks()
    checkLive(call)
  }
  function gone(call) {
    if (call.ending) return
    const text = 'Call ended (connection lost)'
    toast(text, { duration: 4000 })
    announce(text)
    end(true)
  }
  // Someone's connection dropped (or came back). A blip shorter than SHAKY_MS
  // is never shown or read out, so a flapping network doesn't chatter; once it
  // has been said, coming back is said too (their connection is back).
  function unstable(call, msg, on) {
    const uid = msg.from
    if (!uid || uid === state.me?.id) return
    call.shaky ??= new Set()
    call.shakyShown ??= new Set()
    call.shakyTimers ??= new Map()
    const had = call.shaky.has(uid)
    if (on) call.shaky.add(uid)
    else call.shaky.delete(uid)
    if (had === on) return
    const who = isGroup(call.room) ? nameOf(uid, call.room) : ''
    if (on) {
      clearTimeout(call.shakyTimers.get(uid))
      call.shakyTimers.set(uid, setTimeout(() => {
        call.shakyTimers.delete(uid)
        if (active !== call || call.ending || !call.answered || !call.shaky.has(uid)) return
        const text = who ? `${who}'s connection is unstable` : 'Their connection is unstable'
        call.shakyShown.add(uid)
        call.shakyText = text
        showNotice(call)
        announce(text)
      }, SHAKY_MS))
      return
    }
    clearTimeout(call.shakyTimers.get(uid))
    call.shakyTimers.delete(uid)
    if (!call.shakyShown.delete(uid)) return
    // Someone else in a group may still be down: the line names them instead.
    const still = [...call.shakyShown][0]
    if (still) call.shakyText = isGroup(call.room) ? `${nameOf(still, call.room)}'s connection is unstable` : 'Their connection is unstable'
    showNotice(call)
    if (call.answered && !call.ending) announce(who ? `${who}'s connection is back` : 'Their connection is back')
  }
  // One notice line: our own reconnecting outranks someone else's shaky line,
  // which outranks nothing; clearing one never clears the other.
  function showNotice(call) {
    call.ui.setNotice(call.selfShaky ? 'Connection unstable, reconnecting…' : call.shakyShown?.size ? call.shakyText : null)
  }

  function accepted(call, msg) {
    if (msg.from) call.peers.add(msg.from)
    // Someone else joining a group call that is already under way.
    if (call.answered) return
    // Still ringing here: someone else answering doesn't answer it for us.
    if (call.role !== 'caller') return
    clearTimeout(call.ringTimer)
    call.answered = true
    stopRinging(call)
    call.ui.setStatus('Connecting…')
    announceTracks()
    checkLive(call)
  }

  // The caller's status says how the call is reaching the other side.
  function reached(call, kind) {
    if (call.role !== 'caller' || call.answered) return
    if (call.reach && REACH.indexOf(call.reach) <= REACH.indexOf(kind)) return
    call.reach = kind
    call.ui.setStatus(call.media === 'video' ? `Video call · ${REACH_TEXT[kind]}` : REACH_TEXT[kind])
    // It rings over there (in the app, or as a notification): it rings back here.
    if (kind !== 'unreachable' && !call.ringback) call.ringback = ringback()
  }

  function declined(call, msg) {
    // In a group, one person saying no (or being busy) doesn't end it for the rest.
    if (isGroup(call.room)) {
      const who = nameOf(msg.from, call.room)
      if (who && !call.answered) toast(msg.busy ? `${who} is on another call` : msg.missed ? `${who} didn't answer` : `${who} declined`)
      return
    }
    if (msg.busy) endSoon('They are on another call', 'busy')
    else endSoon(msg.missed ? 'No answer' : 'They declined', msg.missed ? 'missed' : 'declined')
  }

  function left(call, msg) {
    if (msg.from) call.peers.delete(msg.from)
    // Gone from the call: their shaky line goes with them, unsaid.
    if (msg.from && call.shaky?.delete(msg.from)) {
      clearTimeout(call.shakyTimers?.get(msg.from))
      call.shakyTimers?.delete(msg.from)
      if (call.shakyShown?.delete(msg.from)) {
        const still = [...call.shakyShown][0]
        if (still) call.shakyText = `${nameOf(still, call.room)}'s connection is unstable`
        showNotice(call)
      }
    }
    const group = isGroup(call.room)
    // Still ringing here: in a group only the caller hanging up, or the call
    // really being over, puts the ring away; anyone else leaving doesn't.
    if (!call.answered) {
      if (group && msg.ongoing && (msg.from !== call.callerId || msg.reason === 'lost')) return
      return end(true)
    }
    // A group call goes on while anyone else is in it or still being rung
    // (the server says so); the rest only hear who left, said as shown.
    if (group && (call.peers.size || msg.ongoing)) {
      const who = nameOf(msg.from, call.room)
      if (who) toast(msg.reason === 'lost' ? `${who} lost connection and left the call` : `${who} left the call`)
      return
    }
    // reason 'lost': the server ended it when their grace period ran out.
    const who = group ? nameOf(msg.from, call.room) : ''
    endSoon(msg.reason === 'lost' ? `${who || 'They'} lost connection, call ended` : 'Call ended')
  }

  function remoteState(call, msg) {
    if (!msg.from || msg.from === state.me?.id) return
    const s = { mic: msg.mic !== false, cam: msg.cam !== false }
    call.remote.set(msg.from, s)
    // One other person's microphone and camera show on the screen; a group's would be a crowd of badges.
    if (!isGroup(call.room)) call.ui.setRemote(s)
  }

  function incoming(msg) {
    // The same call again: this device reconnected while it rang.
    if (active?.callId === msg.callId) return socketSend({ t: 'call', kind: 'ringing', room: msg.room, callId: msg.callId })
    if (active) {
      // Busy: the caller hears so, and this side learns who tried.
      socketSend({ t: 'call', kind: 'decline', room: msg.room, callId: msg.callId, to: msg.from, busy: true })
      const who = msg.caller?.display || nameOf(msg.from, msg.room) || 'Someone'
      toast(`${who} is inviting you to a ${msg.media === 'video' ? 'video' : 'voice'} call, but you're on another call`, { duration: 4000 })
      return
    }
    const call = active = newCall({ room: msg.room, callId: msg.callId, media: msg.media, role: 'callee', caller: msg.caller })
    if (msg.from) call.peers.add(msg.from)
    call.callerId = msg.from
    // Their photo: as the invitation brought it, else as this device knows them.
    const caller = { ...msg.caller, avatar: msg.caller?.avatar || avatarOf(msg.caller?.id, msg.room) }
    call.ui.showIncoming(caller, msg.media, {
      accept: () => {
        if (active !== call) return
        stopRinging(call)
        socketSend({ t: 'call', kind: 'accept', room: msg.room, callId: msg.callId })
        call.answered = true
        // In a group the call is the group's, not the caller's: it stays right when they leave.
        if (isGroup(call.room)) call.ui.retitle(chatInfo(call.room))
        call.ui.setStatus('Connecting…')
        begin().catch(fail)
      },
      decline: () => {
        if (active !== call) return
        stopRinging(call)
        socketSend({ t: 'call', kind: 'decline', room: msg.room, callId: msg.callId })
        end(true)
      }
    })
    // Tell the caller it rings here, so it isn't also sent as a notification.
    socketSend({ t: 'call', kind: 'ringing', room: msg.room, callId: msg.callId })
    haptic()
    call.ringtone = ringtone()
    call.ringTimer = setTimeout(() => {
      if (active !== call || call.answered) return
      socketSend({ t: 'call', kind: 'decline', room: msg.room, callId: msg.callId, missed: true })
      end(true)
    }, RING_MS)
  }

  async function begin() {
    const call = active
    if (call.role === 'callee') clearTimeout(call.ringTimer)
    const wantVideo = call.media === 'video'
    // iOS: route the call like a call (microphone and receiver together).
    if (navigator.audioSession) navigator.audioSession.type = 'play-and-record'
    const stream = await navigator.mediaDevices.getUserMedia({ audio: true, video: wantVideo ? { facingMode: 'user', width: 1280, height: 720 } : false })
    // Hung up while the permission prompt was open: let the microphone go.
    if (active !== call) { stream.getTracks().forEach(t => t.stop()); return }
    call.stream = stream
    // Whatever was switched off before the microphone and camera came on stays off.
    stream.getAudioTracks().forEach(t => (t.enabled = !call.muted))
    stream.getVideoTracks().forEach(t => (t.enabled = !call.camOff))
    const facing = stream.getVideoTracks()[0]?.getSettings?.().facingMode
    call.ui.attachLocal(stream, wantVideo, { mirror: facing !== 'environment' })
    if (wantVideo) {
      keepAwake(call)
      cameraCount().then(n => { if (active === call) call.ui.canFlip(n > 1) })
    }
    mediaSession(call, true)
    const ice = await api.post('/rtc/turn').then(r => r.iceServers).catch(() => [{ urls: 'stun:stun.cloudflare.com:3478' }])
    if (active !== call) { stream.getTracks().forEach(t => t.stop()); return }
    const pc = new RTCPeerConnection({ iceServers: ice, bundlePolicy: 'max-bundle' })
    call.pc = pc
    pc.ontrack = e => {
      call.ui.addRemoteTrack(e.track)
      // Their media flowing is as good as connected, whatever the state says.
      e.track.addEventListener('unmute', () => checkLive(call, true))
    }
    pc.onconnectionstatechange = () => {
      if (active !== call) return
      if (['failed', 'closed'].includes(pc.connectionState)) endSoon('Connection lost')
      else if (pc.connectionState === 'connected') checkLive(call)
    }
    // A dip in the network says so while it recovers, rather than ending the call.
    pc.oniceconnectionstatechange = () => {
      if (active !== call) return
      if (pc.iceConnectionState === 'disconnected') { call.selfShaky = true; showNotice(call) }
      else if (['connected', 'completed'].includes(pc.iceConnectionState)) { call.selfShaky = false; showNotice(call) }
    }
    // Publish local tracks to the SFU: the session's first change, so
    // anything the other side published waits for it in the queue.
    await queued(call, async () => {
      const transceivers = stream.getTracks().map(t => pc.addTransceiver(t, { direction: 'sendonly' }))
      call.videoSender = transceivers.find(tr => tr.sender.track?.kind === 'video')?.sender || null
      await pc.setLocalDescription(await pc.createOffer())
      const session = await api.post('/rtc/sessions/new')
      call.sessionId = session.sessionId
      const tracks = transceivers.map(tr => ({ location: 'local', mid: tr.mid, trackName: `${state.me.id}-${tr.sender.track.kind}` }))
      const res = await api.post(`/rtc/sessions/${call.sessionId}/tracks/new`, {
        sessionDescription: { type: 'offer', sdp: pc.localDescription.sdp },
        tracks
      })
      // A 200 can still carry a failed track.
      const failed = res.tracks?.find(t => t.errorCode)
      if (failed || !res.sessionDescription) throw Object.assign(new Error('Call service is temporarily unavailable'), { status: 502, code: failed?.errorCode })
      await pc.setRemoteDescription(res.sessionDescription)
      call.localTracks = tracks.map(t => t.trackName)
    })
    if (active !== call) return
    if (call.answered) announceTracks()
    pullWanted(call)
  }

  // Every change to a call's SFU session runs after the one before it has
  // finished, answer included: the SFU refuses a change while another is
  // still being negotiated. A call that has ended runs nothing more.
  function queued(call, op) {
    const run = call.queue.then(() => (active === call ? op() : undefined))
    call.queue = run.catch(() => {})
    return run
  }

  function announceTracks() {
    if (!active?.sessionId || !active.localTracks) return
    socketSend({ t: 'call', kind: 'tracks', room: active.room, callId: active.callId, sessionId: active.sessionId, tracks: active.localTracks })
    // With the tracks, whether they carry anything: a microphone or camera switched off before.
    sendState(active)
  }

  function sendState(call) {
    if (active !== call) return
    socketSend({ t: 'call', kind: 'state', room: call.room, callId: call.callId, mic: !call.muted, cam: call.media === 'video' && !call.camOff })
  }

  /** The call is under way once it's answered and connected: from then on it's timed. */
  function checkLive(call, flowing = false) {
    if (active !== call || call.liveAt || !call.answered) return
    if (!flowing && call.pc?.connectionState !== 'connected') return
    call.liveAt = Date.now()
    call.ui.live(call.liveAt)
  }

  /** The other side published tracks: pull them once this side can. */
  function pullFrom(msg) {
    const call = active
    if (!call || msg.from === state.me.id || typeof msg.sessionId !== 'string' || !Array.isArray(msg.tracks)) return
    // Whoever has published is in the call (someone who joined before this side did, too).
    if (msg.from) call.peers.add(msg.from)
    call.wanted.set(msg.from, { sessionId: msg.sessionId, tracks: msg.tracks })
    pullWanted(call)
  }

  function pullWanted(call) {
    // Until this side has published, its session isn't ready to receive.
    if (active !== call || !call.localTracks) return
    queued(call, async () => {
      const want = []
      for (const { sessionId, tracks } of call.wanted.values()) {
        for (const trackName of tracks) if (!call.pulled.has(`${sessionId}/${trackName}`)) want.push({ location: 'remote', sessionId, trackName })
      }
      if (!want.length) return
      const res = await api.post(`/rtc/sessions/${call.sessionId}/tracks/new`, { tracks: want })
      const results = res.tracks || []
      let missing = 0
      for (const t of want) {
        const r = results.find(x => x.trackName === t.trackName && (!x.sessionId || x.sessionId === t.sessionId))
        if (r && !r.errorCode) call.pulled.add(`${t.sessionId}/${t.trackName}`)
        else missing++
      }
      if (res.requiresImmediateRenegotiation && res.sessionDescription) {
        await call.pc.setRemoteDescription(res.sessionDescription)
        await call.pc.setLocalDescription(await call.pc.createAnswer())
        await api.put(`/rtc/sessions/${call.sessionId}/renegotiate`, { sessionDescription: { type: 'answer', sdp: call.pc.localDescription.sdp } })
      }
      if (missing) retryPulls(call)
      else call.pullTries = 0
    }).catch(err => {
      console.warn('pull failed', err)
      retryPulls(call)
    })
  }

  // The other side's media may not be flowing yet when its tracks are
  // announced: ask again shortly, a few times, backing off.
  function retryPulls(call) {
    if (active !== call || call.pullTries >= PULL_TRIES) return
    call.pullTries++
    clearTimeout(call.pullTimer)
    call.pullTimer = setTimeout(() => pullWanted(call), 500 * call.pullTries)
  }

  // ------------------------------------------------------------ this side's microphone and camera
  function setMuted(call, on) {
    if (active !== call) return
    call.muted = on
    call.stream?.getAudioTracks().forEach(t => (t.enabled = !on))
    call.ui.setMuted(on)
    sendState(call)
    quietly(() => navigator.mediaSession?.setMicrophoneActive?.(!on))
  }

  function setCamOff(call, off) {
    if (active !== call || call.media !== 'video') return
    call.camOff = off
    call.stream?.getVideoTracks().forEach(t => (t.enabled = !off))
    call.ui.setCamOff(off)
    sendState(call)
    quietly(() => navigator.mediaSession?.setCameraActive?.(!off))
  }

  /** The other camera (front ↔ back), swapped into what is already being sent. */
  async function flipCamera(call) {
    const old = call.stream?.getVideoTracks()[0]
    if (active !== call || !old || call.flipping) return
    call.flipping = true
    try {
      const settings = old.getSettings?.() || {}
      const next = settings.facingMode === 'environment' ? 'user' : 'environment'
      let fresh
      try {
        fresh = await navigator.mediaDevices.getUserMedia({ video: { facingMode: { exact: next }, width: 1280, height: 720 } })
      } catch {
        // Cameras that don't say which way they face (a computer's): the next one along.
        const cams = (await navigator.mediaDevices.enumerateDevices()).filter(d => d.kind === 'videoinput')
        const at = cams.findIndex(d => d.deviceId === settings.deviceId)
        const pick = cams[(at + 1) % cams.length]
        if (!pick || pick.deviceId === settings.deviceId) throw new Error('no other camera')
        fresh = await navigator.mediaDevices.getUserMedia({ video: { deviceId: { exact: pick.deviceId } } })
      }
      const track = fresh.getVideoTracks()[0]
      if (active !== call) { track.stop(); return }
      track.enabled = !call.camOff
      await call.videoSender?.replaceTrack(track)
      call.stream.removeTrack(old)
      call.stream.addTrack(track)
      old.stop()
      call.ui.attachLocal(call.stream, true, { mirror: (track.getSettings?.().facingMode || next) !== 'environment' })
    } catch (err) {
      console.warn('flip failed', err?.name || err)
      if (active === call) toast("Couldn't switch camera", { type: 'error' })
    } finally {
      call.flipping = false
    }
  }

  async function cameraCount() {
    try {
      return (await navigator.mediaDevices.enumerateDevices()).filter(d => d.kind === 'videoinput').length
    } catch {
      return 0
    }
  }

  /** How loud the other side is right now (0…1), from what the SFU forwards. */
  function level(call) {
    let max = 0
    for (const r of call.pc?.getReceivers?.() || []) {
      if (r.track?.kind !== 'audio' || !r.getSynchronizationSources) continue
      for (const s of r.getSynchronizationSources()) max = Math.max(max, s.audioLevel || 0)
    }
    return max
  }

  // A video call keeps the screen on, as watching a video does.
  async function keepAwake(call) {
    if (!navigator.wakeLock || (call.wake && !call.wake.released)) return
    try {
      const lock = await navigator.wakeLock.request('screen')
      if (active === call) call.wake = lock
      else lock.release().catch(() => {})
    } catch {}
  }

  // The system's own call controls (a picture-in-picture window's buttons,
  // headset keys) reach the call where the browser offers them.
  function mediaSession(call, on) {
    const ms = navigator.mediaSession
    if (!ms) return
    const set = (action, fn) => quietly(() => ms.setActionHandler(action, on ? fn : null))
    set('hangup', () => { if (active === call) end() })
    set('togglemicrophone', () => setMuted(call, !call.muted))
    if (call.media === 'video') {
      set('togglecamera', () => setCamOff(call, !call.camOff))
      set('enterpictureinpicture', () => { if (active === call) call.ui.systemPip() })
    }
    if (on) {
      quietly(() => ms.setMicrophoneActive?.(!call.muted))
      if (call.media === 'video') quietly(() => ms.setCameraActive?.(!call.camOff))
    }
  }

  function stopRinging(call) {
    call.ringback?.stop()
    call.ringtone?.stop()
    call.ringback = call.ringtone = null
  }

  // How an unanswered call ended is kept with it, so each side's record can
  // say what happened (see ui/format.js callSummary).
  function endSoon(label, reason) {
    const call = active
    if (!call || call.ending) return
    call.ending = true
    if (reason) call.endReason = reason
    stopRinging(call)
    call.ui.ending(label)
    call.endTimer = setTimeout(() => { if (active === call) end() }, 900)
  }
  function fail(err) {
    if (!active) return
    // The server's reason and the SFU's public code (if any) say which side to look at.
    console.warn('call failed', err?.status ?? err?.name, err?.data?.reason ?? '', err?.data?.code ?? err?.code ?? '')
    toast(failureText(active.media, err), { type: 'error', duration: 5000 })
    if (!active.answered) active.endReason = 'failed'
    // The other side stops ringing too.
    end(false)
  }
  function end(silent) {
    if (!active) return
    const a = active
    active = null
    clearTimeout(a.ringTimer)
    clearTimeout(a.pullTimer)
    clearTimeout(a.endTimer)
    stopRinging(a)
    try { a.stream?.getTracks().forEach(t => t.stop()) } catch {}
    try { a.pc?.close() } catch {}
    if (navigator.audioSession) navigator.audioSession.type = 'auto'
    a.wake?.release?.().catch(() => {})
    mediaSession(a, false)
    if (!silent && a.answered) {
      // Timed from when it was under way, not from when it started ringing.
      const duration = a.liveAt ? (Date.now() - a.liveAt) / 1000 : 0
      socketSend({ t: 'call', kind: 'hangup', room: a.room, callId: a.callId, media: a.media, duration })
    } else if (!silent && a.role === 'caller') {
      socketSend({ t: 'call', kind: 'cancel', room: a.room, callId: a.callId, media: a.media, missed: true, result: a.endReason || 'cancelled' })
    }
    // The fall of a call ending, for whoever was in it or waiting on its answer.
    if (a.answered || (a.role === 'caller' && a.endReason && a.endReason !== 'failed')) endTone()
    else releaseTones()
    a.ui.destroy()
  }

  function newCall(info) {
    const call = { ...info, answered: false, queue: Promise.resolve(), wanted: new Map(), pulled: new Set(), pullTries: 0, peers: new Set(), remote: new Map(), muted: false, camOff: false }
    call.ui = createCallUI({
      media: info.media,
      onHangup: () => { if (active === call) end() },
      onMute: on => setMuted(call, on),
      onCamera: off => setCamOff(call, off),
      onFlip: () => flipCamera(call),
      level: () => level(call),
      onCover: on => onCover(call.callId, on),
      focusBack
    })
    if (info.role === 'caller') call.ui.showOutgoing(chatInfo(info.room), info.media)
    return call
  }

  /** The browser's Back over a full-screen call: 'minimized', 'ringing', 'ending' or 'none'. */
  function back() {
    return active ? active.ui.back() : 'none'
  }

  return { start, onSignal, resync, back, get ringing() { return Boolean(active?.ui.ringing) }, get busy() { return Boolean(active) } }
}

// Optional browser APIs answer with a promise, a value or an exception.
function quietly(fn) {
  try {
    const r = fn()
    if (r && typeof r.catch === 'function') r.catch(() => {})
  } catch {}
}

// ---------------------------------------------------------------- call UI

const RADIUS = 18 // the picture in picture's corners, on screen
const STRIP = 44 // what shows of it tucked against a side: a full 44pt hit target
const FACE = 52 // the face in the picture in picture, on screen
const PLACE_KEY = 'ui:call-pip'

const px = n => `${Math.round(n * 100) / 100}px`

function savedPlace() {
  const corner = storage(PLACE_KEY)
  return { corner: CORNERS.includes(corner) ? corner : 'tr' }
}

/** Unfolded, the column a call takes: the one beside the conversation, so both stay in use. */
function sideBesideThread() {
  const role = document.querySelector('.pane[data-col="thread"]')?.dataset.role
  const other = { leading: 'trailing', trailing: 'leading' }[role]
  return (other && document.querySelector(`.pane[data-role="${other}"]`)?.dataset.col) || 'thread'
}

/** Unfolded, the column under a point x across the screen (the columns need not be equal: js/ui/columns.js). */
function columnAt(x, width) {
  const lead = document.querySelector('.pane[data-role="leading"]')?.getBoundingClientRect()
  const role = x < (lead ? lead.right : width / 2) ? 'leading' : 'trailing'
  return document.querySelector(`.pane[data-role="${role}"]`)?.dataset.col || sideBesideThread()
}

function createCallUI({ media, onHangup, onMute, onCamera, onFlip, level, onCover = () => {}, focusBack = () => {} }) {
  const layer = document.getElementById('overlays')
  let hasVideo = media === 'video'
  let mode = 'full' // full | pip
  let mounted = false
  let destroyed = false
  let incomingUp = false
  let ending = false
  let ringingIcon = null
  let title = ''
  let statusText = ''
  let notice = null
  let liveAt = 0
  let tick = 0
  let remote = { mic: true, cam: true }
  let muted = false
  let camOff = false
  let remoteTrack = null
  let localStream = null
  let mirrorLocal = true
  let swapped = false
  let calm = false
  let calmTimer = 0
  let locked = false
  const lockToken = { closed: false }
  let previousFocus = document.activeElement
  // Whether the call covers the app (and so holds a history entry, see shell.js).
  let covered = false

  // ------------------------------------------------------------ the call itself
  // Their picture, or yours when swapped, fills the screen; the other one is
  // the tile. Their sound plays from its own element, so the pictures can
  // change places without it stopping.
  const remoteStream = new MediaStream()
  const mainVideo = h('video', { class: 'call-remote', autoplay: true, playsinline: true, muted: true })
  const tileVideo = h('video', { class: 'call-local', autoplay: true, playsinline: true, muted: true })
  const remoteAudio = h('audio', { class: 'call-audio', autoplay: true })
  mainVideo.srcObject = remoteStream
  remoteAudio.srcObject = remoteStream

  const tileOff = h('span', { class: 'call-tile-off', 'aria-hidden': 'true' }, icon('video-slash'))
  const tile = h('button', { class: 'call-tile', type: 'button', 'aria-label': 'Swap view', 'aria-pressed': 'false', title: 'Swap view' }, tileVideo, tileOff)
  const tileFrame = h('div', { class: 'call-tile-frame', 'aria-hidden': 'true' })
  const ring = h('span', { class: 'call-ring', 'aria-hidden': 'true' })
  const face = h('div', { class: 'call-face' }, ring)
  const poster = h('div', { class: 'call-poster' }, face)
  const stage = h('div', { class: 'call-stage' }, mainVideo, poster, tileFrame, tile)

  const name = h('div', { class: 'call-name' })
  const status = h('div', { class: 'call-status' })
  const badges = h('div', { class: 'call-badges' })
  // The heading as a capsule: their photo, how long, who (after the reference).
  const headFace = h('span', { class: 'call-head-face', 'aria-hidden': 'true' })
  const head = h('div', { class: 'call-head' }, headFace, h('span', { class: 'call-head-text' }, status, name), h('span', { class: 'call-head-chev', 'aria-hidden': 'true' }, icon('chevron-right')), badges)
  const minBtn = h('button', { class: 'call-icon-btn call-min', type: 'button', 'aria-label': 'Minimize call', title: 'Minimize call' }, icon('pip-enter'))
  const top = h('div', { class: 'call-top' }, minBtn, head)

  const mic = control({ icon: 'mic', pressedIcon: 'mic-slash', label: 'Mute', toggle: true, onChange: on => onMute(on) })
  const cam = control({ icon: 'video', pressedIcon: 'video-slash', label: 'Turn off camera', toggle: true, onChange: off => onCamera(off) })
  const flip = control({ icon: 'camera-rotate', label: 'Flip camera', caption: 'Flip', onPress: () => onFlip() })
  const hang = control({ icon: 'phone-down', label: 'Hang up', cls: 'hang', onPress: () => onHangup() })
  cam.el.hidden = !hasVideo
  flip.el.hidden = true
  // In the bar at the foot, in the reference's order: camera, flip, mute, then hang up.
  cam.el.dataset.c = 'camera'; flip.el.dataset.c = 'flip'; mic.el.dataset.c = 'mic'; hang.el.dataset.c = 'hang'
  const controls = h('div', { class: 'call-controls' }, mic.el, cam.el, flip.el, hang.el)
  const incoming = h('div', { class: 'call-incoming' })

  // Behind it all (until a picture covers it): the backdrop chosen for
  // calls, always in its dark drawing.
  const root = h('div', { class: ['call', hasVideo && 'video'], role: 'dialog', 'aria-label': 'Call', tabindex: '-1', dataset: { mode } },
    backdropLayer(state.prefs?.call, 'call-backdrop'), stage, top, controls, remoteAudio)

  // ------------------------------------------------------------ the picture in picture
  // The call itself shrinks (transforms on the root); this button lies over
  // it to be pressed, dragged, thrown and read out.
  const hintId = `call-pip-hint-${Date.now().toString(36)}`
  const pipMute = h('span', { class: 'call-pip-mute', hidden: true }, icon('mic-slash'))
  const pipTime = h('span', { class: 'call-pip-time' })
  const pipTab = h('span', { class: 'call-pip-tab' }, icon('chevron-left'))
  const pip = h('button', { class: 'call-pip', type: 'button', hidden: true, 'aria-describedby': hintId },
    pipMute, pipTime, pipTab, h('span', { class: 'sr-only', id: hintId }, 'Drag to any corner, or move with arrow keys; long-press or press the menu key for more'))
  // Where it may rest: inside the safe areas, clear of the headings at the
  // top and the bars at the foot, above the keyboard (call.css).
  const pipFrame = h('div', { class: 'call-pip-frame', 'aria-hidden': 'true' })

  // ------------------------------------------------------------ geometry
  // Full, CSS lays the call out (fold.js gives it a column unfolded). On the
  // way to the picture in picture and in it, its box is pinned where CSS had
  // it and `geo` drives it: its top-left in the overlay layer, its scale and
  // its corner radius on screen. --mini (0 → 1) fades the controls on the way.
  let box = null
  let geo = null
  let pipW = 0
  let pipH = 0
  let morphRun = null
  let resting = false
  let faceBase = 112

  const cssBox = () => ({ left: root.offsetLeft, top: root.offsetTop, width: root.offsetWidth, height: root.offsetHeight })
  const GEOMETRY = ['left', 'top', 'width', 'height', 'right', 'bottom']
  /** The box CSS gives the call where it would be full, whatever it's pinned to now. */
  function cssBoxFree() {
    const saved = GEOMETRY.map(p => [p, root.style[p]])
    for (const [p] of saved) root.style[p] = ''
    const b = cssBox()
    for (const [p, v] of saved) root.style[p] = v
    return b
  }
  function freeze(b = cssBox()) {
    box = b
    Object.assign(root.style, { left: px(b.left), top: px(b.top), width: px(b.width), height: px(b.height), right: 'auto', bottom: 'auto' })
    root.classList.add('moving')
    faceBase = face.querySelector('.avatar')?.offsetWidth || faceBase
    geo ||= { x: b.left, y: b.top, s: 1, r: 0 }
  }
  function release() {
    for (const p of [...GEOMETRY, 'transform', 'borderRadius']) root.style[p] = ''
    root.style.removeProperty('--mini')
    root.style.removeProperty('--face-k')
    root.classList.remove('moving')
    box = null
    geo = null
  }
  function draw() {
    if (!geo || !box) return
    const k = geo.s
    root.style.transform = `translate3d(${px(geo.x - box.left)}, ${px(geo.y - box.top)}, 0) scale(${k.toFixed(5)})`
    root.style.borderRadius = px(geo.r / k)
    const small = pipW / box.width || 0.25
    const p = Math.max(0, Math.min(1, (1 - k) / Math.max(0.0001, 1 - small)))
    root.style.setProperty('--mini', p.toFixed(4))
    // The face shrinks only to a size that still reads in the small window.
    const onScreen = faceBase + (FACE - faceBase) * p
    root.style.setProperty('--face-k', (onScreen / (faceBase * k)).toFixed(4))
  }
  function morph(to, { velocity = 0, damping = 0.9, response = 0.36 } = {}) {
    morphRun?.stop()
    const from = { ...geo }
    const run = morphRun = spring({
      from: 0,
      to: 1,
      velocity,
      damping,
      response,
      restDelta: 0.0008,
      onUpdate: q => {
        geo.x = from.x + (to.x - from.x) * q
        geo.y = from.y + (to.y - from.y) * q
        geo.s = Math.max(0.05, from.s + (to.s - from.s) * q)
        geo.r = Math.max(0, from.r + (to.r - from.r) * q)
        draw()
      }
    })
    return run.done.then(done => {
      if (morphRun === run) morphRun = null
      return done
    })
  }
  const frameRect = () => ({ left: pipFrame.offsetLeft, top: pipFrame.offsetTop, right: pipFrame.offsetLeft + pipFrame.offsetWidth, bottom: pipFrame.offsetTop + pipFrame.offsetHeight })
  function edgeRect() {
    const f = frameRect()
    const gap = parseFloat(getComputedStyle(pipFrame).getPropertyValue('--pip-gap')) || 12
    return { left: f.left - gap, right: f.right + gap }
  }
  /** The picture in picture keeps the call's proportions, about a quarter of the screen's short side wide. */
  function pipSize(b = box) {
    const f = frameRect()
    const short = Math.min(layer.clientWidth, layer.clientHeight)
    const w = Math.max(88, Math.min(136, Math.round(short * 0.26)))
    const hh = (w * b.height) / b.width
    const k = Math.min(1, ((f.bottom - f.top) * 0.5) / hh, ((f.right - f.left) * 0.45) / w)
    return { w: w * k, h: hh * k }
  }

  // ------------------------------------------------------------ into and out of the picture in picture
  const canMinimize = () => mounted && !destroyed && !incomingUp && !ending

  function minimize({ velocity = null, toward = null } = {}) {
    if (mode !== 'full' || !canMinimize()) return
    mode = 'pip'
    root.dataset.mode = 'pip'
    clearTimeout(calmTimer)
    if (!box) freeze()
    const size = pipSize()
    pipW = size.w
    pipH = size.h
    pip.style.width = px(pipW)
    pip.style.height = px(pipH)
    root.classList.add('pip')
    root.setAttribute('aria-hidden', 'true')
    syncLock()
    edgeThemeColor(null)
    // Where it goes: where a throw was heading, else where it was last put.
    resting = false
    pipTile.moveTo(toward ? { corner: nearestCorner(frameRect(), size, toward) } : savedPlace(), { animate: false })
    wasStashed = Boolean(pipTile.place.stashed)
    const t = pipTile.target()
    const to = { x: t.x, y: t.y, s: pipW / box.width, r: RADIUS }
    // A throw carries its speed into the shrink.
    const dx = to.x - geo.x
    const dy = to.y - geo.y
    const dist2 = dx * dx + dy * dy || 1
    const vq = velocity ? Math.max(0, Math.min(6, (dx * velocity.x + dy * velocity.y) / dist2)) : 0
    morph(to, { velocity: vq, damping: 0.86, response: 0.4 }).then(done => { if (done && mode === 'pip') rest() })
    giveFocusBack()
    announce('Call minimized to a small window, tap it to return')
  }

  function rest() {
    resting = true
    root.classList.add('resting')
    root.inert = true
    pip.hidden = false
    syncPip()
    requestAnimationFrame(() => { if (mode === 'pip' && resting) pip.classList.add('on') })
  }

  function expand({ velocity = 0 } = {}) {
    if (mode !== 'pip' || destroyed) return
    // Shrinking again gives focus back here; never to the hidden mini window or the call.
    const from = document.activeElement
    if (from && !root.contains(from) && !pip.contains(from)) previousFocus = from
    mode = 'full'
    root.dataset.mode = 'full'
    resting = false
    pipMenu?.close()
    pipTile.stop()
    pip.classList.remove('on', 'dragging')
    pip.hidden = true
    root.classList.remove('resting')
    root.inert = false
    root.removeAttribute('aria-hidden')
    // Unfolded, it comes back into the half of the screen it was put in.
    if (getLayout() === 'split') placeOnSide(root, columnAt(geo.x + (box.width * geo.s) / 2, layer.clientWidth))
    const target = cssBoxFree()
    const shownWidth = box.width * geo.s
    freeze(target)
    geo.s = shownWidth / target.width
    draw()
    edgeThemeColor('#000000')
    morph({ x: target.left, y: target.top, s: 1, r: 0 }, { velocity, damping: 0.9, response: 0.38 }).then(done => {
      if (!done || mode !== 'full') return
      root.classList.remove('pip')
      release()
      syncLock()
      shape()
      root.focus({ preventScroll: true })
      scheduleCalm()
    })
  }

  /** Back to full after a swipe that didn't go far enough. */
  function settleFull() {
    morph({ x: box.left, y: box.top, s: 1, r: 0 }, { damping: 0.92, response: 0.32 }).then(done => {
      if (!done || mode !== 'full') return
      release()
      scheduleCalm()
    })
  }

  // Focus that was in the call, or already lost to the page (it was on Answer,
  // which went away), goes back to where it was before the call, else to the
  // conversation's composer or the column in front (shell.js).
  function giveFocusBack() {
    const now = document.activeElement
    if (now && now !== document.body && !root.contains(now) && !pip.contains(now)) return
    if (previousFocus?.isConnected && !previousFocus.closest?.('[inert]') && previousFocus !== document.body) previousFocus.focus({ preventScroll: true })
    else focusBack()
  }

  // ------------------------------------------------------------ the picture in picture's gestures
  let pipMenu = null
  let pipPointerAt = 0
  let wasStashed = false
  function applyPip(x, y) {
    pip.style.transform = `translate3d(${px(x)}, ${px(y)}, 0)`
    if (resting && geo) {
      geo.x = x
      geo.y = y
      draw()
    }
  }
  const pipTile = floatTile(pip, {
    frame: frameRect,
    size: () => ({ w: pipW, h: pipH }),
    edge: edgeRect,
    apply: applyPip,
    place: savedPlace(),
    stash: true,
    strip: STRIP,
    // A press while its menu is open closes the menu, and only that.
    onGrab: () => {
      if (pipMenu && !pipMenu.closed) {
        pipMenu.close()
        return false
      }
    },
    onTap: () => tapPip(),
    onHold: e => openPipMenu(e),
    onRest: place => {
      if (place.corner) storage(PLACE_KEY, place.corner)
      pip.classList.remove('dragging')
      syncPip(place)
      // Said once each way, only when it really tucked away or came out.
      const now = Boolean(place.stashed)
      if (now !== wasStashed) {
        wasStashed = now
        announce(now ? 'Call window tucked to the screen edge' : 'Call window moved back to the corner')
      }
    },
    onDrag: () => pip.classList.add('dragging')
  })
  function tapPip(keyed = false) {
    if (mode !== 'pip' || !resting) return
    const at = pipTile.place
    // Tucked away: a tap brings it out first. Keys and screen readers can't
    // see it peek out, so they go straight back to the call.
    if (at.stashed && !keyed) return pipTile.moveTo({ corner: unstashCorner(frameRect(), { w: pipW, h: pipH }, at.stashed, pipTile.position.y) })
    expand()
  }
  pip.addEventListener('pointerdown', () => { pipPointerAt = performance.now() }, true)
  // Pointers are answered as they happen (a tap, a hold, a throw); keys and
  // assistive technology arrive here on their own.
  pip.addEventListener('click', e => {
    if (e.detail !== 0 && performance.now() - pipPointerAt < 1000) return
    tapPip(e.detail === 0)
  })
  pip.addEventListener('keydown', e => {
    if (!e.key.startsWith('Arrow') || mode !== 'pip' || !resting) return
    e.preventDefault()
    const at = pipTile.place
    const from = at.stashed ? unstashCorner(frameRect(), { w: pipW, h: pipH }, at.stashed, pipTile.position.y) : at.corner
    pipTile.moveTo({ corner: cornerToward(from, e.key) })
  })
  function openPipMenu(e) {
    if (mode !== 'pip' || !resting) return
    if (e?.type === 'pointerdown') haptic()
    pipMenu = openMenu(pip, [[
      { label: 'Back to call', icon: hasVideo ? 'video' : 'phone', onSelect: () => expand() },
      { label: 'Mute', icon: 'mic-slash', checked: muted, toggle: true, onSelect: () => onMute(!muted) },
      ...(cam.el.hidden ? [] : [{ label: 'Turn off camera', icon: 'video-slash', checked: camOff, toggle: true, onSelect: () => onCamera(!camOff) }]),
      ...(canSystemPip() ? [{ label: 'Show over other apps', icon: 'pip-enter', onSelect: () => systemPip() }] : [])
    ], [
      { label: 'Hang up', icon: 'phone-down', destructive: true, onSelect: () => onHangup() }
    ]], { title, variant: 'call-pip-menu', focusFirst: !e?.pointerType })
  }
  function syncPip(place = pipTile.place) {
    if (place.stashed) pip.dataset.stashed = place.stashed
    else delete pip.dataset.stashed
    syncStatus()
    if (place.corner) pip.dataset.corner = place.corner
    else delete pip.dataset.corner
    // Menus from it open on its side of the fold.
    const t = pipTile.target()
    pip.dataset.side = getLayout() === 'split' ? columnAt(t.x + pipW / 2, layer.clientWidth) : 'thread'
    pipMute.hidden = !muted
  }

  // ------------------------------------------------------------ swipe down to shrink; tap to show or hide the controls
  let sw = null
  root.addEventListener('pointerdown', e => {
    if (destroyed || e.button > 0) return
    // Caught on its way into the picture in picture: back it comes.
    if (mode === 'pip') {
      if (!resting) expand()
      return
    }
    if (e.target.closest('button, .call-incoming')) return wake()
    sw = { id: e.pointerId, x0: e.clientX, y0: e.clientY, t0: performance.now(), active: false, moved: false, vt: velocityTracker() }
    sw.vt.add(e.clientX, e.clientY)
  })
  root.addEventListener('pointermove', e => {
    if (!sw || e.pointerId !== sw.id) return
    sw.vt.add(e.clientX, e.clientY)
    const dx = e.clientX - sw.x0
    const dy = e.clientY - sw.y0
    if (!sw.active) {
      if (sw.moved || Math.hypot(dx, dy) < 10) return
      sw.moved = true
      if (!canMinimize() || dy < Math.abs(dx) * 1.2) return
      sw.active = true
      try { root.setPointerCapture(e.pointerId) } catch {}
      morphRun?.stop()
      if (!box) freeze()
      const size = pipSize()
      pipW = size.w
      pipH = size.h
      sw.small = pipW / box.width
      const lr = layer.getBoundingClientRect()
      // The point under the finger stays under it as the call shrinks.
      sw.anchor = { x: (e.clientX - lr.left - geo.x) / geo.s, y: (e.clientY - lr.top - geo.y) / geo.s }
      sw.y1 = e.clientY
    }
    const lr = layer.getBoundingClientRect()
    const pull = e.clientY - sw.y1
    const s = Math.max(sw.small, 1 - (Math.max(0, pull) / box.height) * 1.15)
    geo.s = s
    geo.x = e.clientX - lr.left - sw.anchor.x * s
    geo.y = pull < 0 ? box.top + rubberband(pull, box.height) : e.clientY - lr.top - sw.anchor.y * s
    geo.r = RADIUS * Math.min(1, (1 - s) / (1 - sw.small))
    draw()
  })
  const swipeEnd = (e, cancelled = false) => {
    if (!sw || e.pointerId !== sw.id) return
    const was = sw
    sw = null
    if (!was.active) {
      // A tap on the picture: the controls come or go.
      if (!cancelled && !was.moved && performance.now() - was.t0 < 500) {
        if (calm) setCalm(false)
        else if (canCalm()) setCalm(true)
      }
      return
    }
    try { root.releasePointerCapture(was.id) } catch {}
    const v = cancelled ? { x: 0, y: 0 } : was.vt.velocity()
    const shrunk = (1 - geo.s) / (1 - was.small)
    if (!cancelled && v.y > -300 && (shrunk + project(v.y) / box.height > 0.3 || v.y > 700)) {
      // Into the corner the throw was heading for.
      const w = box.width * geo.s
      const hh = box.height * geo.s
      minimize({ velocity: v, toward: { x: geo.x + project(v.x) + (w - pipW) / 2, y: geo.y + project(v.y) + (hh - pipH) / 2 } })
    } else settleFull()
  }
  root.addEventListener('pointerup', e => swipeEnd(e))
  root.addEventListener('pointercancel', e => swipeEnd(e, true))
  root.addEventListener('lostpointercapture', e => { if (sw?.active && e.pointerId === sw.id) swipeEnd(e, true) })
  root.addEventListener('keydown', e => {
    wake()
    if (e.key === 'Escape' && !e.defaultPrevented && incomingUp) {
      e.preventDefault()
      e.stopPropagation()
      announce('Incoming call, answer or decline')
    } else if (e.key === 'Escape' && !e.defaultPrevented && mode === 'full' && canMinimize()) {
      e.preventDefault()
      e.stopPropagation()
      minimize()
    }
  })
  root.addEventListener('focusin', () => wake())
  minBtn.addEventListener('click', () => minimize())

  // ------------------------------------------------------------ the self view
  // A tile you can throw into any corner; a tap swaps the two pictures.
  let tilePointerAt = 0
  const tileFrameRect = () => ({ left: tileFrame.offsetLeft, top: tileFrame.offsetTop, right: tileFrame.offsetLeft + tileFrame.offsetWidth, bottom: tileFrame.offsetTop + tileFrame.offsetHeight })
  const tileCtl = floatTile(tile, {
    frame: tileFrameRect,
    size: () => ({ w: tile.offsetWidth, h: tile.offsetHeight }),
    apply: (x, y) => { tile.style.transform = `translate3d(${px(x)}, ${px(y)}, 0)` },
    place: { corner: 'tr' },
    onTap: () => swap(),
    onDrag: () => wake()
  })
  tile.addEventListener('pointerdown', () => { tilePointerAt = performance.now() }, true)
  tile.addEventListener('click', e => {
    if (e.detail !== 0 && performance.now() - tilePointerAt < 1000) return
    swap()
  })
  tile.addEventListener('keydown', e => {
    if (!e.key.startsWith('Arrow')) return
    e.preventDefault()
    tileCtl.moveTo({ corner: cornerToward(tileCtl.place.corner, e.key) })
  })
  function swap() {
    wake()
    if (!root.classList.contains('remote-video') || !localStream || camOff) return
    setSwapped(!swapped)
  }
  function setSwapped(on) {
    swapped = on
    root.classList.toggle('swapped', on)
    tile.setAttribute('aria-pressed', String(on))
    mainVideo.srcObject = on ? localStream : remoteStream
    tileVideo.srcObject = on ? remoteStream : localStream
    syncMirror()
    mainVideo.play?.().catch(() => {})
    tileVideo.play?.().catch(() => {})
  }
  // Your own picture is mirrored, as in a mirror; the back camera's isn't.
  function syncMirror() {
    mainVideo.classList.toggle('mirror', swapped && mirrorLocal)
    tileVideo.classList.toggle('mirror', !swapped && mirrorLocal)
  }
  function shape() {
    root.classList.toggle('wide', root.offsetWidth > root.offsetHeight)
    if (root.classList.contains('has-local')) tileCtl.settle({ animate: false })
  }

  // ------------------------------------------------------------ what shows
  function syncPicture() {
    const theirs = Boolean(remoteTrack && remoteTrack.readyState === 'live' && !remoteTrack.muted && remote.cam !== false)
    const mine = Boolean(localStream?.getVideoTracks().length) && !camOff
    // Swapped only while there are two pictures to swap.
    if (swapped && !(theirs && mine)) setSwapped(false)
    // Their photo stays until their picture actually comes through, and
    // comes back whenever it stops (connecting, a stalled network, their camera off).
    root.classList.toggle('remote-video', theirs)
    if (calm && !theirs) setCalm(false)
    else scheduleCalm()
  }
  function syncStatus() {
    const text = ending ? statusText : notice || (liveAt ? callClock(Date.now() - liveAt) : statusText)
    if (status.textContent !== text) status.textContent = text
    if (pipTime.textContent !== text) pipTime.textContent = text
    pip.setAttribute('aria-label', `Back to call: ${title}${text ? `, ${text}` : ''}${pip.dataset.stashed ? ', tucked at the screen edge' : ''}`)
  }
  function syncBadges() {
    const items = []
    if (remote.mic === false) items.push(['mic-slash', 'They muted'])
    if (hasVideo && remote.cam === false) items.push(['video-slash', 'They turned off camera'])
    badges.replaceChildren(...items.map(([glyph, text]) => h('span', { class: 'call-badge' }, icon(glyph), text)))
  }
  function setFace(src, label, room = false) {
    face.querySelector('.avatar')?.remove()
    face.append(avatar(src, label, { room }))
    headFace.replaceChildren(avatar(src, label, { room, size: 40 }))
    root.classList.toggle('room-face', room)
  }
  function syncLock() {
    // Folded, a full call is all there is; unfolded it's one column and the other stays in use.
    const want = mounted && !destroyed && mode === 'full' && getLayout() !== 'split'
    if (want && !locked) lockApp(lockToken)
    else if (!want && locked) unlockApp(lockToken)
    locked = want
    root.setAttribute('aria-modal', String(want))
    if (want !== covered) {
      covered = want
      onCover(want)
    }
  }

  // ------------------------------------------------------------ controls that step aside
  // Watching a video call, the controls go after a few seconds; a tap, a
  // key or focus brings them back.
  function canCalm() {
    let keyed = false
    try { keyed = Boolean(root.querySelector(':focus-visible')) } catch {}
    return hasVideo && mode === 'full' && Boolean(liveAt) && !ending && !notice && !incomingUp && !keyed &&
      (root.classList.contains('remote-video') || swapped) && document.visibilityState === 'visible'
  }
  function scheduleCalm() {
    clearTimeout(calmTimer)
    if (!calm && canCalm()) calmTimer = setTimeout(() => { if (canCalm()) setCalm(true) }, 4000)
  }
  function setCalm(on) {
    clearTimeout(calmTimer)
    if (calm !== on) {
      calm = on
      root.classList.toggle('calm', on)
      // The self view moves into the room the controls leave, and out of their way again.
      if (mode === 'full' && root.classList.contains('has-local')) requestAnimationFrame(() => tileCtl.settle())
    }
    if (!on) scheduleCalm()
  }
  const wake = () => setCalm(false)

  // ------------------------------------------------------------ their voice, seen
  // While their face shows, a ring around it follows how loud they are.
  let meterTimer = 0
  let shown = 0
  function meter() {
    if (destroyed) return
    const faceShows = !root.classList.contains('remote-video') && liveAt && document.visibilityState === 'visible'
    if (faceShows) {
      const now = Math.min(1, (level() || 0) * 3)
      shown = Math.max(now, shown * 0.82)
      ring.style.setProperty('--level', shown < 0.02 ? '0' : shown.toFixed(3))
    } else if (shown) {
      shown = 0
      ring.style.setProperty('--level', '0')
    }
    meterTimer = setTimeout(meter, 100)
  }

  // ------------------------------------------------------------ the screen changing shape
  let relayoutFrame = 0
  function relayout() {
    if (destroyed || !mounted) return
    cancelAnimationFrame(relayoutFrame)
    // After fold.js has measured the columns again.
    relayoutFrame = requestAnimationFrame(() => requestAnimationFrame(() => {
      if (destroyed || sw?.active) return
      // A shrink or grow under way lands at once in the new layout.
      if (morphRun) {
        morphRun.stop()
        morphRun = null
      }
      if (mode === 'full') {
        if (box) {
          root.classList.remove('pip')
          release()
        }
        syncLock()
        shape()
        return
      }
      // The same corner, at the size for the screen as it is now.
      freeze(cssBoxFree())
      const size = pipSize()
      pipW = size.w
      pipH = size.h
      pip.style.width = px(pipW)
      pip.style.height = px(pipH)
      geo.s = pipW / box.width
      geo.r = RADIUS
      if (!resting) rest()
      pipTile.settle({ animate: false })
      syncPip()
    }))
  }
  const frameObserver = new ResizeObserver(relayout)
  const offLayout = onLayout(relayout)
  window.addEventListener('resize', relayout)

  function mount() {
    if (mounted) return
    mounted = true
    layer.append(root, pip, pipFrame)
    placeOnSide(root, sideBesideThread())
    // The status column beside the page turns as dark as the call.
    edgeThemeColor('#000000')
    syncLock()
    syncStatus()
    shape()
    frameObserver.observe(pipFrame)
    requestAnimationFrame(() => root.classList.add('on'))
    root.focus({ preventScroll: true })
    meter()
  }

  const canSystemPip = () => Boolean(document.pictureInPictureEnabled && mainVideo.requestPictureInPicture && root.classList.contains('remote-video') && !swapped)
  /** Their picture in the system's own picture in picture, over other apps (where the browser offers it). */
  function systemPip() {
    if (canSystemPip()) mainVideo.requestPictureInPicture().catch(() => {})
  }

  function destroy() {
    if (destroyed) return
    destroyed = true
    ringingIcon?.stop()
    clearInterval(tick)
    clearTimeout(calmTimer)
    clearTimeout(meterTimer)
    cancelAnimationFrame(relayoutFrame)
    morphRun?.stop()
    pipTile.destroy()
    tileCtl.destroy()
    pipMenu?.close()
    frameObserver.disconnect()
    offLayout()
    window.removeEventListener('resize', relayout)
    lockToken.closed = true
    syncLock()
    edgeThemeColor(null)
    if (document.pictureInPictureElement === mainVideo) document.exitPictureInPicture?.().catch(() => {})
    const hadFocus = root.contains(document.activeElement) || pip.contains(document.activeElement)
    if (mode === 'pip') {
      pip.classList.remove('on')
      root.style.transition = 'opacity 200ms ease-out'
      root.style.opacity = '0'
    } else root.classList.remove('on')
    if (hadFocus || !document.activeElement || document.activeElement === document.body) giveFocusBack()
    setTimeout(() => {
      root.remove()
      pip.remove()
      pipFrame.remove()
      mainVideo.srcObject = tileVideo.srcObject = remoteAudio.srcObject = null
    }, 260)
  }

  return {
    showOutgoing(room, m) {
      title = room?.name || 'Call'
      name.textContent = title
      root.setAttribute('aria-label', `Call with ${title}`)
      statusText = m === 'video' ? 'Video call · Calling…' : 'Calling…'
      // The conversation's own picture: the other person's photo, or the group's.
      setFace(room?.avatar || room?.peer?.avatar, room?.name || '', room?.kind === 'group')
      mount()
    },
    // Answered in a group: named and pictured as the group from here on.
    retitle(room) {
      if (!room?.name) return
      title = room.name
      name.textContent = title
      root.setAttribute('aria-label', `Call with ${title}`)
      setFace(room.avatar, room.name, true)
    },
    showIncoming(caller, m, { accept, decline }) {
      incomingUp = true
      root.classList.add('incoming')
      title = caller?.display || 'Incoming call'
      name.textContent = title
      root.setAttribute('aria-label', `Incoming call from ${title}`)
      statusText = m === 'video' ? 'Video call invitation' : 'Voice call invitation'
      setFace(caller?.avatar, caller?.display || '')
      const no = control({ icon: 'phone-down', label: 'Decline', cls: 'hang', onPress: () => { ringingIcon?.stop(); decline() } })
      const yes = control({ icon: m === 'video' ? 'video' : 'phone-fill', label: 'Answer', cls: 'accept', onPress: () => {
        ringingIcon?.stop()
        incomingUp = false
        root.classList.remove('incoming')
        root.setAttribute('aria-label', `Call with ${title}`)
        incoming.remove()
        controls.hidden = false
        minBtn.hidden = false
        accept()
        // Answer itself is gone: focus moves to Hang up, not to the page.
        hang.button.focus({ preventScroll: true })
      } })
      incoming.append(no.el, yes.el)
      controls.hidden = true
      minBtn.hidden = true
      root.append(incoming)
      mount()
      // The answer button keeps bouncing while the call rings.
      ringingIcon = symbolEffect(yes.button.querySelector('.icon'), 'bounce', { repeat: true })
    },
    setStatus(text) {
      statusText = text
      syncStatus()
    },
    /** Something to say over the clock until it clears (a dip in the network). */
    setNotice(text) {
      notice = text || null
      syncStatus()
      if (notice) setCalm(false)
      else scheduleCalm()
    },
    /** Answered and connected: the clock starts. */
    live(at) {
      liveAt = at
      clearInterval(tick)
      tick = setInterval(syncStatus, 1000)
      syncStatus()
      announce('Connected')
      scheduleCalm()
    },
    ending(label) {
      ending = true
      statusText = label
      root.classList.add('ending')
      pip.classList.add('ending')
      clearInterval(tick)
      setCalm(false)
      syncStatus()
      announce(label)
    },
    attachLocal(stream, video, { mirror = true } = {}) {
      localStream = stream
      mirrorLocal = mirror
      if (!video) return
      if (swapped) mainVideo.srcObject = stream
      else tileVideo.srcObject = stream
      syncMirror()
      tileVideo.play?.().catch(() => {})
      const first = !root.classList.contains('has-local')
      root.classList.add('has-local')
      if (first) requestAnimationFrame(() => tileCtl.settle({ animate: false }))
      syncPicture()
    },
    addRemoteTrack(track) {
      remoteStream.addTrack(track)
      if (track.kind === 'video') {
        remoteTrack = track
        if (!hasVideo) {
          hasVideo = true
          root.classList.add('video')
        }
        for (const type of ['mute', 'unmute', 'ended']) track.addEventListener(type, syncPicture)
        syncPicture()
        mainVideo.play?.().catch(() => {})
      }
      remoteAudio.play?.().catch(() => {})
    },
    setRemote(s) {
      const was = remote
      remote = s
      if (was.mic && !s.mic) announce('They muted')
      if (hasVideo && was.cam && !s.cam) announce('They turned off camera')
      syncBadges()
      syncPicture()
    },
    setMuted(on) {
      muted = on
      mic.set(on)
      pipMute.hidden = !on
    },
    setCamOff(off) {
      camOff = off
      cam.set(off)
      root.classList.toggle('cam-off', off)
      syncPicture()
    },
    canFlip(yes) {
      flip.el.hidden = !yes
    },
    expand: () => expand(),
    get ringing() { return incomingUp && !destroyed },
    minimize: () => minimize(),
    /** Back took the call's history entry: shrink if it can; a ringing call stays. */
    back() {
      if (destroyed) return 'none'
      if (incomingUp) {
        announce('Incoming call, answer or decline')
        return 'ringing'
      }
      if (ending) return 'ending'
      if (mode === 'full' && canMinimize()) {
        minimize()
        return 'minimized'
      }
      return 'none'
    },
    systemPip,
    destroy
  }
}

/**
 * A round call button with its caption under it. A toggle's state belongs
 * to whoever owns it (the menu and headset keys change it too): set() shows it.
 */
function control({ icon: glyph, pressedIcon, label, caption = label, cls = '', toggle = false, onPress, onChange }) {
  let pressed = false
  const button = h('button', { class: ['call-btn', cls, toggle && 'toggle'], type: 'button', 'aria-label': label, 'aria-pressed': toggle ? 'false' : undefined }, icon(glyph))
  const el = h('div', { class: 'call-control' }, button, h('span', { class: 'call-caption', 'aria-hidden': 'true' }, caption))
  button.addEventListener('click', () => {
    if (toggle) onChange?.(!pressed)
    else onPress?.()
  })
  return {
    el,
    button,
    set(on) {
      if (!toggle || pressed === on) return
      pressed = on
      button.classList.toggle('active', on)
      button.setAttribute('aria-pressed', String(on))
      if (pressedIcon) replaceSymbol(button.querySelector('.icon'), on ? pressedIcon : glyph)
    }
  }
}

// Why a call couldn't start, in words that say what to do: the device and
// its permission (named for what this call uses), or the server's own
// plain answer for a refusal from the call service.
function failureText(media, err) {
  const devices = media === 'video' ? 'microphone and camera' : 'microphone'
  switch (err?.name) {
    case 'NotAllowedError':
    case 'SecurityError':
      return `Allow access to the ${devices}`
    case 'NotFoundError':
      return `No ${devices} available`
    case 'NotReadableError':
    case 'AbortError':
      return `The ${devices} is in use by another app`
    case 'OverconstrainedError':
      return "The camera doesn't support this call's settings"
  }
  if (err?.status !== undefined) return err.message || 'Call service is temporarily unavailable, try again later'
  return "Couldn't establish the call, please redial"
}
