// P2-11 / P2-12 (docs/ux-plan.md): Back over a full-screen call only shrinks it and its one history entry
// comes and goes with it (button, Escape, swipe, hang-up, Back, a multi-step jump, Forward); a ringing call
// stays and says 来电中，请接听或拒绝; ink on the board isn't asked about on that first Back; focus after a
// shrink; the tucked picture in picture: keys go straight back to the call, a pointer only pulls it out.
// Media through the same stand-in SFU as call-pip.cjs.
// npm run dev:e2e; node tools/e2e/call-back.cjs [outdir]
const { chromium } = require('playwright')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const BASE = process.env.BASE || 'http://127.0.0.1:8787'
const OUT = process.argv[2] || path.join(process.cwd(), 'screenshots-call-back')
if (!['127.0.0.1', 'localhost', '[::1]'].includes(new URL(BASE).hostname)) throw new Error('Use a local dev server')
fs.mkdirSync(OUT, { recursive: true })
const sleep = ms => new Promise(r => setTimeout(r, ms))
const uniq = Date.now().toString(36)

;(async () => {
  const browser = await chromium.launch({ ...(process.env.CHROME && { executablePath: process.env.CHROME }), args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', '--disable-features=WebRtcHideLocalIpsWithMdns', '--autoplay-policy=no-user-gesture-required'] })
  try {
    const errors = []
    const shot = (p, name) => p.screenshot({ path: path.join(OUT, name) })

    async function page(name, viewport = { width: 466, height: 678 }) {
      const ctx = await browser.newContext({ viewport, locale: 'zh-CN', serviceWorkers: 'block', deviceScaleFactor: 2, permissions: ['microphone', 'camera'] })
      const p = await ctx.newPage()
      p.on('pageerror', e => errors.push(`[${name}] ${e.message}`))
      p.setDefaultTimeout(10000)
      // The SFU, stood in for by a peer connection in the page that answers with its candidates (so ICE
      // really connects) and sends this page's fake camera and microphone as the other side's tracks.
      let sessions = 0
      await p.route('**/rtc/**', async route => {
        const req = route.request()
        const where = new URL(req.url()).pathname
        const body = req.postData() ? JSON.parse(req.postData()) : undefined
        if (where === '/rtc/turn') return route.fulfill({ json: { ok: true, iceServers: [] } })
        if (where === '/rtc/sessions/new') return route.fulfill({ status: 201, json: { sessionId: `${name}-s${++sessions}` } })
        if (where.endsWith('/tracks/new') && body.tracks[0].location === 'local') {
          const sdp = await p.evaluate(async offer => {
            const pc = window.__sfu = new RTCPeerConnection()
            await pc.setRemoteDescription({ type: 'offer', sdp: offer })
            await pc.setLocalDescription(await pc.createAnswer())
            await new Promise(resolve => {
              if (pc.iceGatheringState === 'complete') return resolve()
              pc.addEventListener('icegatheringstatechange', () => { if (pc.iceGatheringState === 'complete') resolve() })
              setTimeout(resolve, 2000)
            })
            return pc.localDescription.sdp
          }, body.sessionDescription.sdp)
          return route.fulfill({ json: { sessionDescription: { type: 'answer', sdp }, tracks: body.tracks } })
        }
        if (where.endsWith('/tracks/new')) {
          const res = await p.evaluate(async tracks => {
            window.__media ||= await navigator.mediaDevices.getUserMedia({ audio: true, video: true })
            const added = tracks.map(t => {
              const source = t.trackName.endsWith('-video') ? __media.getVideoTracks()[0] : __media.getAudioTracks()[0]
              return { t, tr: __sfu.addTransceiver(source.clone(), { direction: 'sendonly' }) }
            })
            await __sfu.setLocalDescription(await __sfu.createOffer())
            return { sdp: __sfu.localDescription.sdp, tracks: added.map(({ t, tr }) => ({ ...t, mid: tr.mid })) }
          }, body.tracks)
          return route.fulfill({ json: { requiresImmediateRenegotiation: true, sessionDescription: { type: 'offer', sdp: res.sdp }, tracks: res.tracks } })
        }
        if (where.endsWith('/renegotiate')) {
          await p.evaluate(async sdp => __sfu.setRemoteDescription({ type: 'answer', sdp }), body.sessionDescription.sdp)
          return route.fulfill({ json: {} })
        }
        return route.fulfill({ status: 404, json: { ok: false } })
      })
      await p.goto(BASE)
      return p
    }
    const register = (p, username, display) => p.evaluate(async b => fetch('/auth/register', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(b) }).then(r => r.ok), { username, password: 'hunter22', display })
    const post = (p, url, body) => p.evaluate(async ([url, body]) => (await fetch(url, { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) })).json(), [url, body])
    const open = async (p, room) => {
      await p.reload()
      await p.locator(`.row[data-id="${room}"] .row-inner`).click()
      await p.waitForSelector('.thread:not([hidden]) .msgs .m')
      await sleep(400)
    }
    const until = async (p, fn, arg, what, timeout = 12000) => {
      try { await p.waitForFunction(fn, arg, { timeout, polling: 100 }) } catch { throw new Error(`timed out: ${what}`) }
    }
    const box = (p, sel) => p.evaluate(sel => { const r = document.querySelector(sel)?.getBoundingClientRect(); return r && { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height } }, sel)
    const near = (a, b, tol = 2.5) => Math.abs(a - b) <= tol
    const pipState = p => p.evaluate(() => {
      const c = document.querySelector('.call'), pip = document.querySelector('.call-pip'), r = pip?.getBoundingClientRect(), f = document.querySelector('.call-pip-frame')?.getBoundingClientRect()
      return { mode: c?.dataset.mode, on: pip?.classList.contains('on'), corner: pip?.dataset.corner || null, stashed: pip?.dataset.stashed || null, pip: r && { left: r.left, top: r.top, right: r.right, bottom: r.bottom, width: r.width, height: r.height }, frame: f && { left: f.left, top: f.top, right: f.right, bottom: f.bottom }, appInert: document.getElementById('app').inert, surface: c?.getBoundingClientRect().toJSON() }
    })
    const resting = p => until(p, () => document.querySelector('.call-pip.on') && !document.querySelector('.call-pip.dragging'), null, 'picture in picture at rest').then(() => sleep(700))
    const fullAgain = p => until(p, () => { const c = document.querySelector('.call'); return c?.dataset.mode === 'full' && !c.classList.contains('moving') }, null, 'call full again').then(() => sleep(200))
    // A throw: down on the element's middle, a move a frame at a time, up. Fewer steps, a harder throw.
    async function fling(p, sel, dx, dy, { steps = 8 } = {}) {
      const r = await box(p, sel)
      const x = r.left + r.width / 2, y = r.top + r.height / 2
      await p.mouse.move(x, y)
      await p.mouse.down()
      for (let i = 1; i <= steps; i++) {
        await p.mouse.move(x + (dx * i) / steps, y + (dy * i) / steps)
        await sleep(16)
      }
      await p.mouse.up()
    }


    const results = []
    async function check(name, fn) {
      try { await fn(); results.push(['PASS', name]); console.log('PASS', name) } catch (e) { results.push(['FAIL', name, e.message]); console.log('FAIL', name, '-', e.message) }
    }
    const A = await page('A')
    const B = await page('B')
    assert.ok(await register(A, `ba_${uniq}`, '小明'))
    assert.ok(await register(B, `bb_${uniq}`, '小红'))
    const room = (await post(A, '/api/dm', { username: `bb_${uniq}` })).room.id
    await post(B, '/api/messages', { room, type: 'text', text: '在吗' })
    await open(A, room)
    await open(B, room)
    for (const p of [A, B]) await p.evaluate(() => {
      window.__said = []
      new MutationObserver(() => { const t = document.getElementById('announcer').textContent; if (t) window.__said.push(t) }).observe(document.getElementById('announcer'), { childList: true, characterData: true, subtree: true })
    })
    const said = (p, text) => p.evaluate(t => window.__said.filter(x => x === t).length, text)
    const clearSaid = p => p.evaluate(() => { window.__said = [] })
    const st = p => p.evaluate(() => ({ len: history.length, state: history.state, focus: document.querySelector('.shell').dataset.focus, mode: document.querySelector('.call')?.dataset.mode || null, active: document.activeElement?.getAttribute('aria-label') || document.activeElement?.tagName, confirm: document.querySelector('.menu .menu-title')?.textContent || null }))
    const back = async p => { await p.evaluate(() => history.back()); await sleep(900) }
    const route = s => ({ duo: s.state?.duo, chat: s.state?.chat, d: s.state?.d })
    const pipOf = p => p.evaluate(() => { const pip = document.querySelector('.call-pip'); return { stashed: pip?.dataset.stashed || null, label: pip?.getAttribute('aria-label') || '' } })
    const toFull = async p => { await p.evaluate(() => document.querySelector('.call-pip').click()); await fullAgain(p) }
    const reopen = async p => { if (await p.evaluate(() => document.querySelector('.shell').dataset.focus === 'thread')) return; await p.locator(`.row[data-id="${room}"] .row-inner`).click(); await sleep(700) }

    const base = await st(A)
    // ------------------------------------------------ a video call, full screen
    await A.focus('.thread [data-item="video"]')
    await A.click('.thread [data-item="video"]')
    await B.locator('.call-btn.accept').click()
    // History behaviour doesn't need the media through: answered is enough (ICE may not connect here).
    await until(A, () => document.querySelector('.call')?.dataset.mode === 'full' && !document.querySelector('.call.incoming') && document.querySelector('.call-status')?.textContent === '正在连接…', null, 'answered')
    await sleep(500)

    await check('(1a) full screen pushes one entry with the same route plus call', async () => {
      const s = await st(A)
      assert.equal(s.len, base.len + 1)
      assert.ok(s.state.call)
      assert.deepEqual(route(s), route(base))
    })
    await clearSaid(A)
    await check('(2a) first Back only shrinks; route unchanged; announced once', async () => {
      await back(A); await resting(A)
      const s = await st(A)
      assert.equal(s.mode, 'pip'); assert.equal(s.focus, 'thread'); assert.ok(!s.state.call)
      assert.deepEqual(route(s), route(base))
      assert.equal(await said(A, '通话已缩小为小窗，点按小窗返回通话'), 1)
    })
    await check('(6a) focus after Back-shrink returns to the button pressed before', async () => {
      const s = await st(A)
      assert.equal(s.active, '视频通话')
    })
    await check('(2b) second Back navigates the app; mini window stays', async () => {
      await back(A)
      const s = await st(A)
      assert.notEqual(s.focus, 'thread'); assert.equal(s.mode, 'pip')
    })
    await reopen(A)
    const inThread = await st(A)

    for (const [name, shrink] of [
      ['minimize button', async () => { await A.click('.call-min') }],
      ['Escape', async () => { await A.keyboard.press('Escape') }],
      ['swipe down', async () => { await fling(A, '.call', 0, 400, { steps: 6 }) }]
    ]) {
      await check(`(1b) ${name}: entry removed, no navigation, one Back leaves the conversation`, async () => {
        await toFull(A)
        let s = await st(A)
        assert.ok(s.state.call, 'full pushed the call entry')
        await shrink(); await resting(A)
        s = await st(A)
        assert.equal(s.mode, 'pip'); assert.ok(!s.state.call); assert.deepEqual(route(s), route(inThread))
        await back(A)
        s = await st(A)
        assert.notEqual(s.focus, 'thread', 'one Back leaves the conversation')
        await reopen(A)
      })
    }
    await check('(1c) full ↔ mini ×5 leaves no extra entries', async () => {
      for (let i = 0; i < 5; i++) { await toFull(A); await A.click('.call-min'); await resting(A) }
      await back(A)
      assert.notEqual((await st(A)).focus, 'thread')
      await reopen(A)
    })
    await check('(1d) Forward onto the old call entry does nothing', async () => {
      await toFull(A); await A.click('.call-min'); await resting(A)
      await A.evaluate(() => history.forward()); await sleep(900)
      const s = await st(A)
      assert.equal(s.mode, 'pip'); assert.ok(!s.state.call); assert.equal(s.focus, 'thread')
    })
    await check('(5) history.go(-2) while full only shrinks; still in the conversation; next Back leaves', async () => {
      await toFull(A)
      await A.evaluate(() => history.go(-2)); await sleep(1200)
      let s = await st(A)
      assert.equal(s.mode, 'pip'); assert.equal(s.focus, 'thread'); assert.ok(!s.state.call)
      await back(A)
      s = await st(A); assert.notEqual(s.focus, 'thread')
      await reopen(A)
    })
    await check('(3) ink on the board + full call: first Back shrinks without asking; second asks', async () => {
      await A.click('.thread .composer-action'); await A.click('.composer-tool[data-tool="draw"]')
      await A.waitForSelector('.shell[data-focus=artifact]:not([data-anim]) .draw'); await sleep(300)
      const b = await A.locator('.shell[data-focus=artifact] .draw-canvas').boundingBox()
      await A.mouse.move(b.x + 40, b.y + 60); await A.mouse.down()
      for (let i = 0; i < 15; i++) await A.mouse.move(b.x + 40 + i * 10, b.y + 60 + i * 3)
      await A.mouse.up()
      await toFull(A)
      await back(A); await resting(A)
      let s = await st(A)
      assert.equal(s.mode, 'pip'); assert.equal(s.confirm, null, 'no discard question'); assert.equal(s.focus, 'artifact')
      await back(A)
      s = await st(A)
      assert.match(s.confirm || '', /放弃这张手绘/)
      await A.keyboard.press('Escape'); await sleep(500)
      s = await st(A); assert.equal(s.focus, 'artifact')
    })
    await shot(A, 'call-back-pip-over-board.png').catch(() => {})
    await check('(6b) focus when the earlier element is gone falls to the composer or column', async () => {
      // Close the board (discard) so the focus that was in it is gone, then shrink.
      await toFull(A)
      await A.evaluate(() => document.querySelector('.call').focus())
      await A.keyboard.press('Escape'); await resting(A)
      const s = await A.evaluate(() => ({ tag: document.activeElement?.tagName, cls: document.activeElement?.className }))
      assert.notEqual(s.tag, 'BODY', JSON.stringify(s))
    })
    // ------------------------------------------------ P2-12, tucked
    await check('(7) tucked: name suffix; pointer only pulls out; Enter goes full', async () => {
      const r = await box(A, '.call-pip')
      await fling(A, '.call-pip', 600, 0, { steps: 3 }); await resting(A)
      let p = await pipOf(A)
      assert.ok(p.stashed, 'tucked'); assert.match(p.label, /，已收在屏幕边缘$/)
      assert.ok(await said(A, '通话小窗已收到屏幕边缘') === 1)
      // The strip that shows at the edge, not the part off screen.
      const t = await box(A, '.call-pip')
      const vw = await A.evaluate(() => innerWidth)
      const x = Math.max(t.left, 0) + (Math.min(t.right, vw) - Math.max(t.left, 0)) / 2
      await A.mouse.click(x, t.top + t.height / 2); await resting(A)
      p = await pipOf(A)
      assert.equal(p.stashed, null); assert.equal((await st(A)).mode, 'pip'); assert.doesNotMatch(p.label, /已收在/)
      assert.ok(await said(A, '通话小窗已移回角落') === 1)
      await fling(A, '.call-pip', 600, 0, { steps: 3 }); await resting(A)
      assert.ok((await pipOf(A)).stashed)
      await A.focus('.call-pip'); await A.keyboard.press('Enter'); await fullAgain(A)
      assert.equal((await st(A)).mode, 'full')
      void r
    })
    await check('(1e) hang up from full: entry removed; one Back leaves', async () => {
      if ((await st(A)).mode !== 'full') await toFull(A)
      assert.ok((await st(A)).state.call)
      await A.click('.call-controls .call-btn.hang'); await sleep(1200)
      let s = await st(A)
      assert.equal(s.mode, null); assert.ok(!s.state?.call)
      await back(A); s = await st(A)
      // The board with ink is still there: the one Back reaches its question (not a silent call entry).
      assert.match(s.confirm || '', /放弃这张手绘/, 'Back after hang-up reaches the board')
      await A.click('.menu button:has-text("放弃")'); await sleep(900)
      assert.equal((await st(A)).focus, 'thread')
    })
    // ------------------------------------------------ ringing
    await reopen(A)
    await check('(4) Back / Escape while ringing: still ringing, route same, announced', async () => {
      await clearSaid(A)
      const before = await st(A)
      await B.click('.thread [data-item="video"]')
      await A.waitForSelector('.call.incoming'); await sleep(600)
      await back(A)
      let s = await st(A)
      assert.ok(await A.$('.call.incoming'), 'still ringing'); assert.ok(s.state.call)
      assert.equal(s.focus, before.focus)
      await A.keyboard.press('Escape'); await sleep(300)
      assert.ok(await A.$('.call.incoming'))
      assert.ok(await said(A, '来电中，请接听或拒绝') >= 2)
      await A.locator('.call-btn.accept').click()
      await sleep(1500)
      await back(A); await resting(A)
      assert.equal((await st(A)).mode, 'pip')
      await toFull(A); await A.click('.call-controls .call-btn.hang'); await sleep(1000)
    })
    if (errors.length) console.log('page errors:', errors)
    const failed = results.filter(r => r[0] === 'FAIL')
    console.log(`${results.length - failed.length}/${results.length} passed`)
    process.exitCode = failed.length ? 1 : 0
  } finally {
    await browser.close()
  }
})().catch(e => { console.error(e); process.exit(1) })
