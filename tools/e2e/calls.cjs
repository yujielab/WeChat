// Local call regression with real Chromium WebRTC and fake camera/microphone.
// A browser peer simulates the SFU API and forwards real media between clients.
// Does not contact Cloudflare Realtime or create any server accounts/messages.
// npm run dev; node tools/e2e/calls.cjs
// CALL_SOURCE_REF=<git-ref> runs the same checks against an older call.js blob.
const { chromium } = require('playwright')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const path = require('node:path')
const { execFileSync } = require('node:child_process')

const BASE = process.env.BASE || 'http://127.0.0.1:8787'
if (!['127.0.0.1', 'localhost', '[::1]'].includes(new URL(BASE).hostname)) throw new Error('Use a local dev server')
const repo = path.resolve(__dirname, '../..')
const fixture = fs.readFileSync(path.join(repo, 'public/index.html'), 'utf8')
  .replace(/<script\b[^>]*>[\s\S]*?<\/script>/g, '')
  .replace(/<link[^>]+rel="modulepreload"[^>]*>/g, '')
const olderSource = process.env.CALL_SOURCE_REF && execFileSync('git', ['show', `${process.env.CALL_SOURCE_REF}:public/js/views/call.js`], { cwd: repo, encoding: 'utf8' })
const gate = () => { let release; const promise = new Promise(r => { release = r }); return { promise, release } }

async function setup(browser, { beforeSession, turnError, sessionError, relay = false } = {}) {
  const context = await browser.newContext({ viewport: { width: 466, height: 678 }, serviceWorkers: 'block', permissions: ['microphone', 'camera'], locale: 'zh-CN' })
  context.setDefaultTimeout(7000)
  const errors = [], requests = [], messages = [], clients = new Map()
  const sfu = await context.newPage()
  await sfu.route('**/*', r => r.request().isNavigationRequest() ? r.fulfill({ contentType: 'text/html', body: fixture }) : r.continue())
  await sfu.goto(BASE)
  await sfu.evaluate(() => {
    window.sessions = new Map()
    window.nextSession = 0
    window.gather = async pc => {
      if (pc.iceGatheringState === 'complete') return
      await new Promise((resolve, reject) => {
        const timer = setTimeout(() => reject(new Error('Local SFU ICE timeout')), 7000)
        const changed = () => { if (pc.iceGatheringState === 'complete') { clearTimeout(timer); pc.removeEventListener('icegatheringstatechange', changed); resolve() } }
        pc.addEventListener('icegatheringstatechange', changed)
        changed()
      })
    }
    window.sfuRequest = async ({ method, pathname, body }) => {
      if (pathname === '/rtc/sessions/new') {
        const sessionId = `local-${++nextSession}`
        const pc = new RTCPeerConnection({ iceServers: [] })
        sessions.set(sessionId, { pc, published: new Map() })
        return { sessionId }
      }
      const [, id, action] = pathname.match(/^\/rtc\/sessions\/([^/]+)\/(.+)$/) || []
      const session = sessions.get(id)
      if (!session) throw new Error('Unknown local SFU session: ' + pathname)
      const { pc, published } = session
      if (action === 'tracks/new' && body.sessionDescription) {
        await pc.setRemoteDescription(body.sessionDescription)
        for (const track of body.tracks) {
          const transceiver = pc.getTransceivers().find(t => t.mid === track.mid)
          if (!transceiver) throw new Error('Published track mid missing from SDP')
          published.set(track.trackName, transceiver.receiver.track)
        }
        await pc.setLocalDescription(await pc.createAnswer())
        await gather(pc)
        return { sessionDescription: { type: pc.localDescription.type, sdp: pc.localDescription.sdp }, tracks: body.tracks }
      }
      if (action === 'tracks/new') {
        const tracks = body.tracks.map(track => {
          const source = sessions.get(track.sessionId)?.published.get(track.trackName)
          if (!source) throw new Error('Unknown publication: ' + track.trackName)
          const transceiver = pc.addTransceiver(source, { direction: 'sendonly' })
          return { ...track, transceiver }
        })
        await pc.setLocalDescription(await pc.createOffer())
        await gather(pc)
        return { requiresImmediateRenegotiation: true, sessionDescription: { type: pc.localDescription.type, sdp: pc.localDescription.sdp }, tracks: tracks.map(({ transceiver, ...track }) => ({ ...track, mid: transceiver.mid })) }
      }
      if (action === 'renegotiate' && method === 'PUT') { await pc.setRemoteDescription(body.sessionDescription); return {} }
      if (action === 'tracks/close') return {}
      throw new Error('Unexpected local SFU route: ' + pathname)
    }
  })

  async function client(id, peerId) {
    const page = await context.newPage()
    page.on('pageerror', e => errors.push(e.message))
    await page.exposeFunction('signalBridge', async msg => {
      messages.push({ ...msg, from: id })
      const other = clients.get(peerId)
      if (relay && other && !other.isClosed()) await other.evaluate(msg => window.calls.onSignal(msg), { ...msg, from: id, caller: { id, display: id } })
    })
    await page.route('**/*', async route => {
      const req = route.request(), pathname = new URL(req.url()).pathname
      if (req.isNavigationRequest()) return route.fulfill({ contentType: 'text/html', body: fixture })
      if (olderSource && pathname === '/js/views/call.js') return route.fulfill({ contentType: 'text/javascript', body: olderSource })
      if (!pathname.startsWith('/rtc/')) return route.continue()
      const body = req.postDataJSON() || {}, request = { id, pathname, method: req.method(), body }
      requests.push(request)
      try {
        if (pathname === '/rtc/turn') return route.fulfill({ status: turnError ? 502 : 200, json: turnError || { ok: true, iceServers: [] } })
        if (pathname === '/rtc/sessions/new') {
          await beforeSession?.(request)
          const failure = typeof sessionError === 'function' ? sessionError(request) : sessionError
          if (failure) return route.fulfill({ status: 502, json: failure })
        }
        if (body.sessionDescription) assert.match(body.sessionDescription.sdp, /a=candidate:/, 'client sends gathered ICE candidates')
        const result = await sfu.evaluate(request => window.sfuRequest(request), request)
        await route.fulfill({ json: result })
      } catch (e) {
        errors.push(e.message)
        if (!page.isClosed()) await route.fulfill({ status: 502, json: { ok: false, error: '本地测试 SFU 失败：' + e.message, code: 'RTC_RESPONSE' } }).catch(() => {})
      }
    })
    await page.goto(BASE)
    await page.evaluate(async ({ id, peerId }) => {
      const { state } = await import('/js/store.js')
      const { createCalls } = await import('/js/views/call.js')
      state.me = { id, display: id }
      state.calls = { enabled: true }
      state.socket = true
      state.chats = new Map([['room', { id: 'room', kind: 'dm', name: peerId, peer: { id: peerId, display: peerId } }]])
      window.signals = []
      window.nativeMedia = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices)
      window.clientPCs = []
      const NativePC = RTCPeerConnection
      window.RTCPeerConnection = class extends NativePC { constructor(config) { super(config); clientPCs.push(this) } }
      window.calls = createCalls({ socketSend: msg => { signals.push(msg); window.signalBridge(msg).catch(() => {}) } })
    }, { id, peerId })
    clients.set(id, page)
    return page
  }
  return {
    client, errors, requests, messages,
    async negotiated() { await sfu.waitForFunction(() => sessions.size && [...sessions.values()].every(({ pc }) => pc.signalingState === 'stable'), null, { timeout: 10000 }) },
    async close() { await context.close() },
    assertClean() { assert.deepEqual(errors, [], 'no browser or local SFU errors') }
  }
}

async function waitPublished(page) {
  await page.waitForFunction(() => clientPCs.some(pc => pc.connectionState === 'connected' && pc.remoteDescription), null, { timeout: 15000 })
}
async function hangup(page) { await page.locator('.call.on [aria-label="挂断"]').click() }
async function busy(page) { return page.evaluate(() => calls.busy) }

;(async () => {
  const browser = await chromium.launch({ args: ['--use-fake-device-for-media-stream', '--use-fake-ui-for-media-stream', '--autoplay-policy=no-user-gesture-required'] })
  let passed = 0
  async function test(name, fn) {
    if (process.env.CALL_CASE && !name.includes(process.env.CALL_CASE)) return
    await fn()
    passed++
    console.log('PASS: ' + name)
  }
  try {
    await test('upstream credential failure is actionable and cancels ringing', async () => {
      const t = await setup(browser, { sessionError: { ok: false, error: 'Realtime 应用凭据无效，请检查 App ID 与 App Secret', code: 'RTC_AUTH' } })
      try {
        const a = await t.client('alice', 'bob')
        await a.evaluate(() => calls.start('room', 'audio'))
        await a.waitForFunction(() => !calls.busy)
        assert.match(await a.getByRole('status').innerText(), /App Secret/)
        assert.equal(await busy(a), false)
        await a.waitForFunction(() => signals.some(msg => msg.kind === 'cancel'))
        t.assertClean()
      } finally { await t.close() }
    })
    await test('configured TURN failure is actionable instead of silently falling back', async () => {
      const t = await setup(browser, { turnError: { ok: false, error: 'TURN 凭据无效，请检查 TURN Key ID 与 API Token', code: 'TURN_AUTH' } })
      try {
        const a = await t.client('alice', 'bob')
        await a.evaluate(() => calls.start('room', 'video'))
        await a.getByRole('status').filter({ hasText: 'TURN' }).waitFor()
        assert.equal(await busy(a), false)
        assert.equal(t.requests.some(r => r.pathname === '/rtc/sessions/new'), false)
        t.assertClean()
      } finally { await t.close() }
    })
    for (const [name, error, message] of [['permission', 'NotAllowedError', /权限|允许/], ['missing device', 'NotFoundError', /设备|麦克风|摄像头/]]) {
      await test(name + ' failure identifies the browser problem', async () => {
        const t = await setup(browser)
        try {
          const a = await t.client('alice', 'bob')
          await a.evaluate(error => { navigator.mediaDevices.getUserMedia = () => Promise.reject(new DOMException('test', error)); calls.start('room', 'video') }, error)
          await a.getByRole('status').filter({ hasText: message }).waitFor()
          assert.equal(await busy(a), false)
          assert.equal(t.requests.length, 0)
          t.assertClean()
        } finally { await t.close() }
      })
    }
    for (const media of ['audio', 'video']) {
      await test(media + ' publishes and receives real local WebRTC media with early remote tracks', async () => {
        const pending = gate()
        const t = await setup(browser, { relay: true, beforeSession: r => r.id === 'alice' ? pending.promise : undefined })
        try {
          const a = await t.client('alice', 'bob'), b = await t.client('bob', 'alice')
          await a.evaluate(media => calls.start('room', media), media)
          await b.getByRole('button', { name: '接听', exact: true }).click()
          await b.waitForFunction(() => signals.some(msg => msg.kind === 'tracks'), null, { timeout: 15000 })
          assert.equal(t.requests.some(r => r.id === 'alice' && /tracks\/new$/.test(r.pathname)), false, 'remote tracks arrive before caller publication')
          pending.release()
          for (const p of [a, b]) {
            await waitPublished(p)
            await p.waitForFunction(async kinds => {
              const pc = clientPCs.find(pc => pc.connectionState === 'connected')
              if (!pc) return false
              const received = [...await pc.getStats()].map(([, stat]) => stat).filter(stat => stat.type === 'inbound-rtp' && stat.bytesReceived > 0)
              return kinds.every(kind => received.some(stat => (stat.kind || stat.mediaType) === kind))
            }, media === 'video' ? ['audio', 'video'] : ['audio'], { timeout: 20000 })
          }
          await t.negotiated()
          assert.ok(t.requests.filter(r => /renegotiate$/.test(r.pathname)).length >= 2)
          await hangup(a)
          await b.waitForFunction(() => !calls.busy)
          assert.equal(await busy(a), false)
          t.assertClean()
        } finally { pending.release(); await t.close() }
      })
    }
    await test('late media permission result stops old tracks and preserves replacement call', async () => {
      const t = await setup(browser)
      try {
        const a = await t.client('alice', 'bob')
        await a.evaluate(async () => {
          window.lateStream = await nativeMedia({ audio: true })
          navigator.mediaDevices.getUserMedia = () => new Promise(resolve => { window.releaseMedia = () => resolve(lateStream) })
          calls.start('room', 'audio')
        })
        await hangup(a)
        await a.evaluate(() => { navigator.mediaDevices.getUserMedia = nativeMedia; calls.start('room', 'audio') })
        await waitPublished(a)
        await a.evaluate(() => releaseMedia())
        await a.waitForFunction(() => lateStream.getTracks().every(track => track.readyState === 'ended'))
        assert.equal(await busy(a), true)
        assert.equal(await a.evaluate(() => clientPCs.at(-1).connectionState), 'connected')
        await hangup(a)
        t.assertClean()
      } finally { await t.close() }
    })
    await test('late setup API failure cannot end a replacement call', async () => {
      const pending = gate()
      let count = 0, first
      const t = await setup(browser, { beforeSession: r => { count++; if (count === 1) { first = r; return pending.promise } }, sessionError: r => r === first ? { ok: false, error: '过期请求失败', code: 'RTC_AUTH' } : null })
      try {
        const a = await t.client('alice', 'bob')
        await a.evaluate(() => calls.start('room', 'audio'))
        for (let i = 0; i < 150 && !first; i++) await a.waitForTimeout(20)
        assert.ok(first, 'first setup request reached the delayed API')
        await hangup(a)
        await a.evaluate(() => calls.start('room', 'audio'))
        await waitPublished(a)
        pending.release()
        await a.waitForTimeout(300)
        assert.equal(await busy(a), true)
        assert.equal(await a.getByRole('status').count(), 0)
        assert.equal(await a.evaluate(() => clientPCs.at(-1).connectionState), 'connected')
        await hangup(a)
        t.assertClean()
      } finally { pending.release(); await t.close() }
    })
    await test('old delayed hangup cannot close a replacement call', async () => {
      const t = await setup(browser)
      try {
        const a = await t.client('alice', 'bob')
        await a.evaluate(() => calls.start('room', 'audio'))
        await waitPublished(a)
        await a.evaluate(() => { const callId = signals.find(msg => msg.kind === 'invite').callId; calls.onSignal({ kind: 'decline', room: 'room', callId, from: 'bob' }) })
        await hangup(a)
        await a.evaluate(() => calls.start('room', 'audio'))
        await waitPublished(a)
        await a.waitForTimeout(1000)
        assert.equal(await busy(a), true)
        assert.equal(await a.evaluate(() => clientPCs.at(-1).connectionState), 'connected')
        await hangup(a)
        t.assertClean()
      } finally { await t.close() }
    })
    assert.ok(passed, 'at least one selected case ran')
    console.log(`PASS: ${passed} call regressions; real local WebRTC/media, intercepted SFU API; no live Cloudflare call tested`)
  } finally { await browser.close() }
})().catch(e => { console.error(e); process.exitCode = 1 })
