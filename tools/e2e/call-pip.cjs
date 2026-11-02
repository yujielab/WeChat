// Calls that step aside: two real accounts call each other through a stand-in for the Realtime SFU (a second
// RTCPeerConnection inside each page that really connects and sends the fake camera and microphone), so
// pictures, sound levels and the clock are real. Checks the call shrinking into a picture in picture over the
// app (button, swipe down, Escape), the app in use underneath (send a message), throwing it into corners and
// tucking it against a side, its menu (mute reaches the other side as 对方已静音), keys, the camera off showing
// the face, the self view thrown and swapped, the controls stepping aside, unfolding (the call takes the column
// beside the conversation, which stays bright and in use; back from the picture in picture into the half it was
// put in), someone else calling meanwhile (对方正在通话中 / 对方忙线), the record afterwards, and a voice
// call's little window with its face, speaking ring and clock.
// npm run dev:e2e; node tools/e2e/call-pip.cjs [outdir]
const { chromium } = require('playwright')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const BASE = process.env.BASE || 'http://127.0.0.1:8787'
const OUT = process.argv[2] || path.join(process.cwd(), 'screenshots-call-pip')
if (!['127.0.0.1', 'localhost', '[::1]'].includes(new URL(BASE).hostname)) throw new Error('Use a local dev server')
fs.mkdirSync(OUT, { recursive: true })
const sleep = ms => new Promise(r => setTimeout(r, ms))
const uniq = Date.now().toString(36)

;(async () => {
  const browser = await chromium.launch({ args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream', '--disable-features=WebRtcHideLocalIpsWithMdns', '--autoplay-policy=no-user-gesture-required'] })
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

    // ---------------------------------------------------------------- two accounts, one conversation
    const A = await page('A')
    const B = await page('B')
    const C = await page('C')
    assert.ok(await register(A, `pa_${uniq}`, '小明'))
    assert.ok(await register(B, `pb_${uniq}`, '小红'))
    assert.ok(await register(C, `pc_${uniq}`, '小刚'))
    const room = (await post(A, '/api/dm', { username: `pb_${uniq}` })).room.id
    await post(B, '/api/messages', { room, type: 'text', text: '晚点视频？' })
    const roomCB = (await post(C, '/api/dm', { username: `pb_${uniq}` })).room.id
    await post(C, '/api/messages', { room: roomCB, type: 'text', text: '在忙吗' })
    await open(A, room)
    await open(B, room)

    // ---------------------------------------------------------------- a video call, under way
    await A.click('.thread [data-item="video"]')
    await B.locator('.call-btn.accept').click()
    for (const p of [A, B]) {
      await until(p, () => document.querySelector('.call.remote-video'), null, 'their picture comes through')
      await until(p, () => /^\d\d:\d\d$/.test(document.querySelector('.call-status')?.textContent || ''), null, 'the clock runs')
    }
    const t0 = await A.locator('.call-status').textContent()
    await sleep(1300)
    assert.notEqual(await A.locator('.call-status').textContent(), t0, 'the clock moves on')
    assert.equal(await A.evaluate(() => document.getElementById('app').inert), true, 'folded, the full call is all there is')
    assert.equal(await A.evaluate(() => document.querySelector('.call').getAttribute('aria-modal')), 'true')
    // Toggles say what they are: 静音 is pressed when muted (not while the microphone is on).
    assert.equal(await A.getAttribute('.call-controls .call-btn[aria-label="静音"]', 'aria-pressed'), 'false')
    await shot(A, '80-call-video-full.png')

    // ---------------------------------------------------------------- into the picture in picture, the app in use underneath
    await A.click('.call-min')
    await resting(A)
    let s = await pipState(A)
    assert.equal(s.mode, 'pip')
    assert.equal(s.appInert, false, 'the app is back in use')
    assert.equal(s.corner, 'tr', 'first time: the top trailing corner')
    assert.ok(near(s.pip.right, s.frame.right) && near(s.pip.top, s.frame.top), 'resting in that corner of its room: ' + JSON.stringify(s))
    assert.ok(near(s.surface.left, s.pip.left, 1.5) && near(s.surface.width, s.pip.width, 1.5), 'the call itself is under the little window')
    assert.ok(s.pip.width >= 88 && s.pip.width <= 136, 'about a quarter of the screen wide: ' + s.pip.width)
    await A.fill('.composer textarea', '小窗里也能聊天')
    await A.keyboard.press('Enter')
    await A.locator('.msgs .bubble', { hasText: '小窗里也能聊天' }).waitFor()
    await shot(A, '81-pip-over-chat.png')

    // Thrown down and to the left: it lands in the bottom leading corner, above the bar at the foot.
    await fling(A, '.call-pip', -120, 160)
    await resting(A)
    s = await pipState(A)
    assert.equal(s.corner, 'bl', 'thrown into the corner it was heading for')
    assert.ok(near(s.pip.left, s.frame.left) && near(s.pip.bottom, s.frame.bottom), 'in that corner: ' + JSON.stringify(s))
    const composerTop = (await box(A, '.thread .composer .field')).top
    assert.ok(s.pip.bottom <= composerTop, 'clear of the message field')
    // Thrown across the screen it lands in the far corner, not tucked away.
    await fling(A, '.call-pip', 150, 0)
    await resting(A)
    assert.equal((await pipState(A)).corner, 'br', 'a throw across lands in the far corner')
    // Flicked hard at the side it's near: tucked against it with a strip showing; a tap brings it back out.
    await fling(A, '.call-pip', 140, -10, { steps: 2 })
    await resting(A)
    s = await pipState(A)
    assert.equal(s.stashed, 'right', 'tucked against the side it was flung past')
    const showing = 466 - s.pip.left
    assert.ok(showing > 20 && showing < 40, 'a strip still shows: ' + showing)
    await shot(A, '82-pip-tucked.png')
    await A.mouse.click(s.pip.left + 12, s.pip.top + s.pip.height / 2)
    await resting(A)
    s = await pipState(A)
    assert.ok(!s.stashed && s.corner?.endsWith('r'), 'out again on that side: ' + s.corner)

    // Its menu (a long press): 静音 reaches the other side.
    const pr = s.pip
    await A.mouse.move(pr.left + pr.width / 2, pr.top + pr.height / 2)
    await A.mouse.down(); await sleep(650); await A.mouse.up()
    await A.locator('.menu.call-pip-menu').waitFor()
    const items = await A.locator('.menu.call-pip-menu .menu-item .label').allTextContents()
    assert.deepEqual(items.filter(t => t !== '在其他应用上方显示'), ['返回通话', '静音', '关闭摄像头', '挂断'])
    assert.equal(await A.evaluate(() => document.querySelector('.call').dataset.mode), 'pip', 'the release after a hold doesn\'t open the call')
    await A.locator('.menu.call-pip-menu .menu-item', { hasText: '静音' }).click()
    await A.locator('.call-pip-mute:not([hidden])').waitFor()
    await B.locator('.call-badge', { hasText: '对方已静音' }).waitFor()
    assert.equal(await A.getAttribute('.call-controls .call-btn[aria-label="静音"]', 'aria-pressed'), 'true')

    // Keys: arrows move it, Enter brings the call back, Escape sends it away again.
    await A.evaluate(() => document.querySelector('.call-pip').focus())
    await A.keyboard.press('ArrowUp'); await A.keyboard.press('ArrowLeft')
    await resting(A)
    assert.equal((await pipState(A)).corner, 'tl', 'arrow keys move it between corners')
    await A.keyboard.press('Enter')
    await fullAgain(A)
    s = await pipState(A)
    assert.equal(s.appInert, true)
    assert.ok(near(s.surface.left, 0, 1) && near(s.surface.width, 466, 1), 'full screen again: ' + JSON.stringify(s.surface))
    assert.equal(await A.evaluate(() => document.activeElement === document.querySelector('.call')), true, 'focus goes with it')
    await A.keyboard.press('Escape')
    await resting(A)
    assert.equal((await pipState(A)).corner, 'tl', 'back to where it was put')
    // A tap brings it back.
    s = await pipState(A)
    await A.mouse.click(s.pip.left + s.pip.width / 2, s.pip.top + s.pip.height / 2)
    await fullAgain(A)

    // ---------------------------------------------------------------- the other side: a swipe down
    const st = await box(B, '.call-stage')
    await B.mouse.move(st.left + st.width / 2, st.top + st.height * 0.45)
    await B.mouse.down()
    for (let i = 1; i <= 6; i++) { await B.mouse.move(st.left + st.width / 2 + i * 8, st.top + st.height * 0.45 + i * 40); await sleep(14) }
    await B.mouse.up()
    await resting(B)
    s = await pipState(B)
    assert.equal(s.mode, 'pip', 'a swipe down shrinks the call')
    assert.ok(s.corner?.startsWith('b'), 'into a corner the swipe was heading for: ' + s.corner)

    // ---------------------------------------------------------------- your camera off: they see your face
    await A.click('.call-controls .call-btn[aria-label="关闭摄像头"]')
    await until(B, () => !document.querySelector('.call').classList.contains('remote-video'), null, 'their face instead of a dark picture')
    assert.ok(await B.locator('.call-badge', { hasText: '对方已关闭摄像头' }).count())
    await until(B, () => getComputedStyle(document.querySelector('.call-pip-time')).display !== 'none', null, 'the window shows the clock over the face')
    await shot(B, '83-pip-face-camera-off.png')
    assert.equal(await A.evaluate(() => getComputedStyle(document.querySelector('.call-tile-off')).display), 'grid', 'your own tile shows the camera struck through')
    await A.click('.call-controls .call-btn[aria-label="关闭摄像头"]')
    await until(B, () => document.querySelector('.call').classList.contains('remote-video'), null, 'their picture back')

    // ---------------------------------------------------------------- the self view: thrown, and swapped
    await fling(A, '.call-tile', -300, 300)
    await until(A, () => !document.querySelector('.call-tile')?.getAnimations().length, null, 'tile at rest')
    await sleep(800)
    const tile = await box(A, '.call-tile'), tf = await box(A, '.call-tile-frame')
    assert.ok(near(tile.left, tf.left, 3) && near(tile.bottom, tf.bottom, 3), 'the self view thrown into the bottom leading corner: ' + JSON.stringify([tile, tf]))
    await A.mouse.click(tile.left + tile.width / 2, tile.top + tile.height / 2)
    await until(A, () => document.querySelector('.call').classList.contains('swapped'), null, 'a tap swaps the pictures')
    assert.equal(await A.evaluate(() => document.querySelector('.call-remote').classList.contains('mirror')), true, 'your own picture, mirrored, fills the screen')
    await A.mouse.click(tile.left + tile.width / 2, tile.top + tile.height / 2)
    await until(A, () => !document.querySelector('.call').classList.contains('swapped'), null, 'and back')

    // ---------------------------------------------------------------- the controls step aside
    await until(A, () => document.querySelector('.call').classList.contains('calm'), null, 'controls go after a few seconds', 7000)
    await shot(A, '84-call-calm.png')
    await A.mouse.click(233, 330)
    await until(A, () => !document.querySelector('.call').classList.contains('calm'), null, 'a tap brings them back')

    // ---------------------------------------------------------------- unfolded: side by side with the conversation
    await A.setViewportSize({ width: 951, height: 669 })
    await until(A, () => document.querySelector('.call')?.dataset.place, null, 'the call takes a column')
    await sleep(500)
    let split = await A.evaluate(() => {
      const c = document.querySelector('.call'), r = c.getBoundingClientRect(), thread = document.querySelector('.pane[data-col="thread"]')
      return { place: c.dataset.place, side: c.dataset.side, shadow: getComputedStyle(c).boxShadow, inert: document.getElementById('app').inert, modal: c.getAttribute('aria-modal'), left: r.left, width: r.width, threadRole: thread.dataset.role }
    })
    assert.equal(split.threadRole, 'trailing')
    assert.equal(split.place, 'leading', 'the column beside the conversation: ' + JSON.stringify(split))
    assert.equal(split.shadow, 'none', 'the conversation beside it isn\'t dimmed')
    assert.equal(split.inert, false, 'and is in use')
    assert.equal(split.modal, 'false')
    await A.fill('.composer textarea', '分屏：一边通话一边聊')
    await A.keyboard.press('Enter')
    await A.locator('.msgs .bubble', { hasText: '分屏：一边通话一边聊' }).waitFor()
    await shot(A, '85-split-call-beside-chat.png')
    // Into the picture in picture; thrown to the trailing half; a tap brings the call back into that half.
    await A.click('.call-min')
    await resting(A)
    await fling(A, '.call-pip', 380, 150, { steps: 10 })
    await resting(A)
    s = await pipState(A)
    assert.ok(s.pip.left > 951 / 2, 'thrown across the fold: ' + JSON.stringify(s.pip))
    assert.ok(s.pip.right <= s.frame.right + 1 && s.pip.left >= s.frame.left - 1, 'inside its room')
    await shot(A, '86-split-pip-light.png')
    await A.evaluate(() => { document.documentElement.dataset.theme = 'dark' })
    await sleep(300)
    await shot(A, '87-split-pip-dark.png')
    await A.mouse.click(s.pip.left + s.pip.width / 2, s.pip.top + s.pip.height / 2)
    await fullAgain(A)
    split = await A.evaluate(() => document.querySelector('.call').dataset.place)
    assert.equal(split, 'trailing', 'back into the half it was put in')
    // Folded again, in the picture in picture: still in its corner, still in its room.
    await A.click('.call-min')
    await resting(A)
    await A.setViewportSize({ width: 466, height: 678 })
    await sleep(900)
    s = await pipState(A)
    assert.ok(s.pip.left >= s.frame.left - 1 && s.pip.right <= s.frame.right + 1 && s.pip.top >= s.frame.top - 1 && s.pip.bottom <= s.frame.bottom + 1, 'refitted to the folded screen: ' + JSON.stringify(s))
    assert.ok(near(s.surface.width, s.pip.width, 1.5), 'the call is still under it')
    await shot(A, '88-pip-folded-dark.png')
    await A.evaluate(() => { delete document.documentElement.dataset.theme })

    // ---------------------------------------------------------------- busy: someone else calls while the call goes on
    await C.reload()
    await C.locator(`.row[data-id="${roomCB}"] .row-inner`).click()
    await C.waitForSelector('.thread:not([hidden]) .msgs .m')
    await C.click('.thread [data-item="video"]')
    await C.locator('.call-status', { hasText: '对方正在通话中' }).waitFor()
    await B.locator('.toast', { hasText: '小刚邀请你视频通话，你正在通话中' }).waitFor()
    assert.equal(await B.locator('.call').count(), 1, 'the call under way is left as it was')
    await C.locator('.call').waitFor({ state: 'detached', timeout: 8000 })
    await C.locator('.msgs .bubble.call-log', { hasText: '对方忙线' }).waitFor({ timeout: 8000 })

    // ---------------------------------------------------------------- hang up from the window's menu: the record afterwards
    s = await pipState(A)
    await A.mouse.click(s.pip.left + s.pip.width / 2, s.pip.top + s.pip.height / 2, { button: 'right' })
    await A.locator('.menu.call-pip-menu .menu-item', { hasText: '挂断' }).click()
    for (const p of [A, B]) await p.locator('.call').waitFor({ state: 'detached', timeout: 8000 })
    assert.equal(await A.evaluate(() => document.getElementById('app').inert), false)
    await A.locator('.msgs .bubble.call-log', { hasText: '通话时长' }).waitFor({ timeout: 8000 })

    // ---------------------------------------------------------------- a voice call's little window: the face and the clock
    await A.click('.thread [data-item="audio"]')
    await B.locator('.call-btn.accept').click()
    await until(A, () => /^\d\d:\d\d$/.test(document.querySelector('.call-status')?.textContent || ''), null, 'voice call under way')
    await until(A, () => parseFloat(document.querySelector('.call-ring')?.style.getPropertyValue('--level') || '0') > 0, null, 'their voice shows as a ring')
    await A.click('.call-min')
    await resting(A)
    const voice = await A.evaluate(() => {
      const t = document.querySelector('.call-pip-time'), a = document.querySelector('.call-face .avatar').getBoundingClientRect(), p = document.querySelector('.call-pip').getBoundingClientRect()
      return { time: t.textContent, shown: getComputedStyle(t).display !== 'none', face: a.width, inside: a.left >= p.left && a.right <= p.right && a.top >= p.top && a.bottom <= p.bottom }
    })
    assert.ok(voice.shown && /^\d\d:\d\d$/.test(voice.time), 'the clock in the window: ' + JSON.stringify(voice))
    assert.ok(voice.face > 40 && voice.face < 64 && voice.inside, 'a face that reads in the window: ' + JSON.stringify(voice))
    await shot(A, '89-pip-voice.png')
    await A.evaluate(() => { document.documentElement.dataset.theme = 'dark' })
    await sleep(300)
    await shot(A, '90-pip-voice-dark.png')
    await A.evaluate(() => { delete document.documentElement.dataset.theme })
    // The other side hangs up: the window says so and goes.
    await B.click('.call-controls .call-btn.hang')
    await until(A, () => /通话结束/.test(document.querySelector('.call-pip-time')?.textContent || ''), null, 'the window says the call ended')
    for (const p of [A, B]) await p.locator('.call').waitFor({ state: 'detached', timeout: 8000 })

    assert.deepEqual(errors, [])
    console.log('PASS: video call with a running clock; into the picture in picture (button, swipe down, Escape) with the app in use underneath; thrown into corners clear of the bars, tucked against a side and brought out; its menu (mute reaches the other side); arrow keys, Enter; camera off shows the face; the self view thrown and swapped; the controls step aside; unfolded, the call sits beside the conversation (bright, in use) and comes back into the half it was put in; refitted when folding; a third person calling meanwhile hears 对方正在通话中 and gets 对方忙线; hang up from the menu leaves a timed record; a voice call\'s window shows the face (with its speaking ring) and the clock, and says when the other side hangs up; no page errors')
  } finally {
    await browser.close()
  }
})().catch(e => { console.error(e); process.exit(1) })
