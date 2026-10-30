// Call setup against a stand-in for the Realtime SFU: each page's /rtc/*
// requests are answered by a second RTCPeerConnection inside that page, so
// the real client code negotiates real SDP. Checks the order the SFU
// requires (one change per session at a time, answer included), that the
// callee pulls the caller's tracks
// even when they were announced before its own connection existed, and that
// a pull whose media isn't flowing yet is retried.
// Start npm run dev:e2e (calls switched on), then: node tools/e2e/call-negotiation.cjs
const { chromium } = require('playwright')
const assert = require('node:assert/strict')
const BASE = process.env.BASE || 'http://127.0.0.1:8787'
if (!['127.0.0.1', 'localhost', '[::1]'].includes(new URL(BASE).hostname)) throw new Error('Run against a local wrangler dev instance')
const sleep = ms => new Promise(r => setTimeout(r, ms))
const uniq = Date.now().toString(36)

;(async () => {
  const browser = await chromium.launch({ args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'] })
  try {
    const problems = []
    const log = []
    async function page(name) {
      const ctx = await browser.newContext({ viewport: { width: 466, height: 678 }, locale: 'zh-CN', serviceWorkers: 'block', permissions: ['microphone', 'camera'] })
      const p = await ctx.newPage()
      p.on('pageerror', e => problems.push(`[${name}] ${e.message}`))
      let sessions = 0
      let inflight = 0
      let failFirstPull = name === 'A'
      await p.route('**/rtc/**', async route => {
        const req = route.request()
        const path = new URL(req.url()).pathname
        const body = req.postData() ? JSON.parse(req.postData()) : undefined
        const entry = { page: name, method: req.method(), path, body, start: Date.now() }
        log.push(entry)
        if (path === '/rtc/turn') return route.fulfill({ json: { ok: true, iceServers: [] } })
        if (path === '/rtc/sessions/new') return route.fulfill({ status: 201, json: { sessionId: `${name}-s${++sessions}` } })
        entry.inflight = ++inflight
        try {
          if (path.endsWith('/tracks/new') && body.tracks[0].location === 'local') {
            const sdp = await p.evaluate(async offer => {
              window.__sfu = new RTCPeerConnection()
              await __sfu.setRemoteDescription({ type: 'offer', sdp: offer })
              await __sfu.setLocalDescription(await __sfu.createAnswer())
              return __sfu.localDescription.sdp
            }, body.sessionDescription.sdp)
            await sleep(400) // a slow publish widens any race with pulls
            return route.fulfill({ json: { sessionDescription: { type: 'answer', sdp }, tracks: body.tracks } })
          }
          if (path.endsWith('/tracks/new')) {
            // The first pull finds the other side's media not flowing yet.
            if (failFirstPull) {
              failFirstPull = false
              return route.fulfill({ json: { tracks: body.tracks.map(t => ({ ...t, errorCode: 'empty_track_error', errorDescription: 'not yet' })) } })
            }
            const sdp = await p.evaluate(async n => {
              for (let i = 0; i < n; i++) __sfu.addTransceiver('audio', { direction: 'sendonly' })
              await __sfu.setLocalDescription(await __sfu.createOffer())
              return __sfu.localDescription.sdp
            }, body.tracks.length)
            await sleep(150)
            return route.fulfill({ json: { requiresImmediateRenegotiation: true, sessionDescription: { type: 'offer', sdp }, tracks: body.tracks.map((t, i) => ({ ...t, mid: String(i + 1) })) } })
          }
          if (path.endsWith('/renegotiate')) {
            await p.evaluate(async sdp => __sfu.setRemoteDescription({ type: 'answer', sdp }), body.sessionDescription.sdp)
            await sleep(150)
            return route.fulfill({ json: {} })
          }
          return route.fulfill({ status: 404, json: { ok: false } })
        } finally {
          entry.end = Date.now()
          inflight--
        }
      })
      return p
    }
    const reg = async (p, u, d) => {
      await p.goto(BASE); await p.click('.auth-tab:has-text("创建账号")')
      await p.fill('#auth-u', u); await p.fill('#auth-d', d); await p.fill('#auth-p', 'hunter2')
      await p.click('.auth-submit'); await p.waitForSelector('.shell')
    }
    const A = await page('A'), B = await page('B')
    await reg(A, `ca_${uniq}`, '甲'); await reg(B, `cb_${uniq}`, '乙')
    await A.click('.pane-list [data-item="compose"]'); await A.fill('.sheet-search input', `cb_${uniq}`)
    await A.locator(`.sheet .cell:has-text("@cb_${uniq}")`).click(); await A.waitForSelector('.thread:not([hidden])')
    await A.fill('.composer textarea', '在吗'); await A.keyboard.press('Enter')
    await B.locator('.row').first().click(); await B.waitForSelector('.thread:not([hidden])')
    await sleep(500)

    await A.click('.thread [data-item="audio"]')
    await B.locator('.call-btn.accept').click({ timeout: 10000 })
    // Both sides publish, announce and pull (A's first pull is retried).
    const pulled = () => ['A', 'B'].every(n => log.some(e => e.page === n && e.path.endsWith('/renegotiate')))
    for (let i = 0; i < 60 && !pulled(); i++) await sleep(250)
    await sleep(300)

    const ids = { A: 'A-s1', B: 'B-s1' }
    for (const n of ['A', 'B']) {
      const mine = log.filter(e => e.page === n && e.path !== '/rtc/turn')
      const create = mine.find(e => e.path === '/rtc/sessions/new')
      // What reaches the SFU carries no body: the server drops this one (test/call.test.js).
      assert.ok(create, `${n} creates a session`)
      const muts = mine.filter(e => e.inflight)
      assert.ok(muts.every(e => e.inflight === 1), `${n}: SFU changes never overlap ${JSON.stringify(muts.map(e => [e.path, e.inflight]))}`)
      for (let i = 1; i < muts.length; i++) assert.ok(muts[i].start >= muts[i - 1].end, `${n}: each change starts after the last one ended`)
      assert.equal(muts[0].body.tracks[0].location, 'local', `${n} publishes first`)
      const other = n === 'A' ? ids.B : ids.A
      const pulls = muts.filter(e => e.body?.tracks?.[0]?.location === 'remote')
      assert.ok(pulls.length >= 1 && pulls.every(e => e.body.tracks.every(t => t.sessionId === other)), `${n} pulls the other side's tracks`)
      assert.ok(mine.some(e => e.path === `/rtc/sessions/${ids[n]}/renegotiate`), `${n} answers the SFU's offer`)
    }
    assert.ok(log.filter(e => e.page === 'A' && e.body?.tracks?.[0]?.location === 'remote').length >= 2, 'a pull that found no media is retried')

    // A call that can't start says why, in words that say what to do.
    await A.click('.call .call-btn.hang'); await sleep(1500)
    await A.evaluate(() => {
      window.__gum = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices)
      navigator.mediaDevices.getUserMedia = () => Promise.reject(new DOMException('in use', 'NotReadableError'))
    })
    await A.click('.thread [data-item="audio"]')
    await A.locator('.toast', { hasText: '麦克风正被其他应用占用' }).waitFor({ timeout: 5000 })
    await sleep(1500)
    // The call service refusing: the server's own plain answer (src/call.js refusal).
    await A.evaluate(() => { navigator.mediaDevices.getUserMedia = window.__gum })
    await A.route('**/rtc/sessions/new', r => r.fulfill({ status: 401, contentType: 'application/json', body: JSON.stringify({ ok: false, error: '通话服务配置有误，暂时无法通话', reason: 'RTC_AUTH', code: 'unauthorized' }) }))
    await A.click('.thread [data-item="audio"]')
    await A.locator('.toast', { hasText: '通话服务配置有误，暂时无法通话' }).waitFor({ timeout: 5000 })
    await sleep(500)
    assert.deepEqual(problems, [])
    console.log('PASS: publish first; one SFU change at a time per session; callee pulls tracks announced before it was ready; failed pull retried; both sides answer the SFU offer; a busy microphone and a refusing call service each say why; no page errors')
  } finally {
    await browser.close()
  }
})().catch(e => { console.error(e); process.exit(1) })
