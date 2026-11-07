// Time in a conversation: marks in the middle after five minutes of quiet whoever speaks, a new one at
// midnight, the day named only on a day's first mark, no capsules; no time on each bubble, and one line
// under your latest message saying where it stands (Read 10:28) — gone once they reply; 3px within a run,
// 12px when the other speaks. Swipe left and every message on screen shows when it was sent, springing
// back on release; the long-press menu has the full time (and when it was edited); scrolling back floats
// the day you're reading, which fades after you stop; a jump to a quoted message shows its day. Settings:
// 12/24-hour, every message's time, and read receipts (kept on the server). The floating day stands over the
// messages' middle; the field, the mic and jump-to-latest are frosted glass. Fixtures in the page, plus a
// real account for the receipts setting. npm run dev:e2e; node tools/e2e/chat-time.cjs [outdir]
const { chromium } = require('playwright'), assert = require('node:assert/strict'), fs = require('fs'), path = require('path')
const BASE = process.env.BASE || 'http://127.0.0.1:8787', OUT = process.argv[2] || path.join(process.cwd(), 'screenshots-chat-time')
if (!['127.0.0.1', 'localhost', '[::1]'].includes(new URL(BASE).hostname)) throw new Error('Use a local dev server')
fs.mkdirSync(OUT, { recursive: true })
const sleep = ms => new Promise(r => setTimeout(r, ms))
const json = body => ({ contentType: 'application/json', body: JSON.stringify(body) })

async function fixture(p, { older = 0 } = {}) {
  await p.route('**/auth/status', r => r.fulfill(json({ authed: false })))
  await p.route('**/api/**', r => r.fulfill(json({ ok: true, messages: [] })))
  await p.goto(BASE)
  await p.locator('.auth').waitFor()
  await p.evaluate(SAID)
  await p.evaluate(async older => {
    localStorage.setItem('ui:time-format', '24')
    const { state, thread, mergeMessages } = await import('/js/store.js'), { createThread } = await import('/js/views/thread.js')
    state.me = { id: 'me', display: 'Me' }
    const day = new Date(); day.setHours(0, 0, 0, 0)
    const t = (h, m, d = 0) => day.getTime() + d * 86400e3 + (h * 60 + m) * 60e3
    window.T = t
    let n = 0
    const M = (ts, out, text, extra = {}) => ({ id: `m${n++}`, chat: 'r', type: 'text', text, from: out ? 'me' : 'p', out, ts: ts + (n % 50) * 500, status: 'sent', ...extra })
    const list = []
    for (let i = 0; i < older; i++) list.push(M(t(9, 0, -3) + i * 60e3, i % 2 === 0, `Earlier, number ${i + 1}`))
    list.push(
      M(t(21, 0, -1), false, 'Good night!'),
      M(t(23, 58, -1), true, 'Still up?'),
      M(t(0, 1), false, 'Yes, just now'), // 3 minutes later, but a new day
      M(t(9, 41), true, 'Good morning!'), M(t(9, 41), true, 'Free today?'),
      M(t(9, 42), false, 'Yes, why?'),
      M(t(9, 43), true, 'Want to see a movie?', { edited: 1, meta: { editedAt: t(9, 50), history: [{ text: 'Movie?', ts: t(9, 43) }] } }),
      M(t(9, 43), false, 'Sure!'),
      M(t(10, 26), false, 'What time does it start?', older ? { replyTo: 'm0', reply: { id: 'm0', sender: 'me', type: 'text', body: 'Earlier, number 1' } } : {}),
      M(t(10, 26), true, 'Half past two'),
      M(t(10, 27), true, "Let's meet at two!"))
    const last = list.at(-1)
    state.chats = new Map([['r', { id: 'r', kind: 'dm', name: 'Mika', peer: { id: 'p', display: 'Mika' }, unread: 0, peerRead: last.ts, peerReadAt: t(10, 28) }]])
    const th = thread('r'); th.loaded = true; th.hasMore = false
    mergeMessages('r', list)
    const shell = document.createElement('div'); shell.className = 'shell'; shell.dataset.layout = 'stack'; shell.dataset.thread = 'open'
    const pane = document.createElement('section'); pane.className = 'pane'; pane.dataset.role = 'single'; shell.append(pane)
    document.querySelector('#app').replaceChildren(shell)
    window.view = createThread(pane, { onBack() {}, onInfo() {}, onDraw() {}, onCall() {}, socketSend() {} })
    view.setLayout('single'); await view.open('r')
  }, older)
  await sleep(700)
}
const marks = p => p.evaluate(() => [...document.querySelectorAll('.thread:not([hidden]) .ts.mark')].map(e => e.textContent))
// what a bubble says on screen (not its time for screen readers)
const SAID = `window.said = b => { const c = b.cloneNode(true); c.querySelectorAll('.sr-only, .m-meta, .pick-marks').forEach(x => x.remove()); return c.textContent }`
const statusLine = p => p.evaluate(() => [...document.querySelectorAll('.m-status')].map(e => ({ text: e.textContent, of: said(e.closest('.m').querySelector('.bubble')) })))

;(async () => {
  const browser = await chromium.launch()
  const errors = []
  const watch = (p, label) => {
    p.on('pageerror', e => errors.push(`[${label}] ${e.message}`))
    p.on('console', m => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(`[${label}] ${m.text()}`) })
  }
  try {
    // ---------------------------------------------------------------- marks, status, spacing
    const ctx = await browser.newContext({ viewport: { width: 430, height: 900 }, deviceScaleFactor: 2, hasTouch: true, isMobile: true, serviceWorkers: 'block' })
    const p = await ctx.newPage(); watch(p, 'touch'); p.setDefaultTimeout(8000)
    await fixture(p)
    assert.deepEqual(await marks(p), ['Yesterday 21:00', '23:58', 'Today 00:01', '09:41', '10:26'],
      "a mark after 5 minutes' quiet whoever speaks; midnight starts a new day; only a day's first mark names it")
    assert.equal(await p.locator('.bubble > .m-meta').count(), 0, 'no time on each bubble')
    assert.ok(await p.locator('.bubble .sr-only.m-when').count() > 5, "each message's time is there for screen readers")
    assert.deepEqual(await statusLine(p), [{ text: 'Read 10:28', of: "Let's meet at two!" }], 'one status line, under the latest message, with when it was read')
    const look = await p.evaluate(() => {
      const ts = document.querySelector('.ts.mark'), cs = getComputedStyle(ts)
      const rows = [...document.querySelectorAll('.msgs > .m')]
      const gap = text => getComputedStyle(rows.find(r => said(r.querySelector('.bubble')) === text)).marginTop
      return {
        font: [cs.fontSize, cs.fontWeight, cs.lineHeight, cs.color, cs.backgroundColor, cs.boxShadow, cs.marginTop, cs.marginBottom],
        run: gap('Free today?'), turn: gap('Yes, why?'), afterMark: gap('Good morning!')
      }
    })
    assert.deepEqual(look.font, ['12px', '500', '18px', 'rgb(107, 114, 128)', 'rgba(0, 0, 0, 0)', 'none', '24px', '16px'], 'marks: 12px Medium grey, on nothing, 24 above and 16 below')
    assert.deepEqual([look.run, look.turn, look.afterMark], ['3px', '12px', '0px'], '3px within a run, 12px when the other speaks')
    await p.screenshot({ path: path.join(OUT, '1-marks.png') })

    // the status follows the latest message: Sending…, then gone once they reply
    await p.evaluate(async () => {
      const { upsertMessage } = await import('/js/store.js')
      upsertMessage({ id: 'local:1', chat: 'r', type: 'text', text: 'On my way', from: 'me', out: true, ts: T(10, 31), status: 'sending' })
    })
    await sleep(200)
    assert.deepEqual(await statusLine(p), [{ text: 'Sending…', of: 'On my way' }])
    assert.equal(await p.locator('.m-status .spinner').count(), 1, 'with a small spinner')
    await p.evaluate(async () => {
      const { upsertMessage, removeMessage } = await import('/js/store.js')
      removeMessage('local:1', 'r')
      upsertMessage({ id: 'm-reply', chat: 'r', type: 'text', text: 'See you!', from: 'p', out: false, ts: T(10, 29), status: 'sent' })
    })
    await sleep(200)
    assert.deepEqual(await statusLine(p), [], 'a reply after it says the rest')
    // midnight-in-place: the marks are redrawn when the day turns or the setting changes
    await p.evaluate(() => { localStorage.setItem('ui:time-format', '12'); dispatchEvent(new Event('chat-times')) })
    await sleep(200)
    assert.deepEqual(await marks(p), ['Yesterday 9:00 PM', '11:58 PM', 'Today 12:01 AM', '9:41 AM', '10:26 AM'], '12-hour, redrawn at once')
    await p.evaluate(() => { localStorage.setItem('ui:time-format', '24'); dispatchEvent(new Event('chat-times')) })
    await sleep(200)

    // ---------------------------------------------------------------- swipe left: every message's time
    const cdp = await ctx.newCDPSession(p)
    const touch = (type, x, y) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x, y, id: 1 }] })
    const scrollTop = () => p.evaluate(() => document.querySelector('.thread:not([hidden]) .thread-scroll').scrollTop)
    const top0 = await scrollTop()
    const at = await p.locator('.m .bubble', { hasText: 'Half past two' }).boundingBox()
    const y = at.y + at.height / 2, x0 = 300
    await touch('touchStart', x0, y); await sleep(30)
    await touch('touchMove', x0 - 8, y); await sleep(30)
    assert.equal(await p.locator('.time-reveal').count(), 0, 'not before 12px')
    for (let i = 2; i <= 12; i++) { await touch('touchMove', x0 - i * 9, y); await sleep(16) }
    const shown = await p.evaluate(() => {
      const layer = document.querySelector('.time-reveal')
      const view = document.querySelector('.thread-scroll').getBoundingClientRect()
      const onScreen = [...document.querySelectorAll('.msgs > .m .m-col > .bubble')].filter(b => { const r = b.getBoundingClientRect(); return r.bottom > view.top && r.top < view.bottom }).length
      const row = text => [...document.querySelectorAll('.msgs > .m')].find(r => said(r.querySelector('.bubble')) === text)
      return { labels: [...(layer?.children || [])].map(t => t.textContent), opacity: layer && getComputedStyle(layer).opacity, mine: getComputedStyle(row('Half past two')).transform, theirs: getComputedStyle(row('Sure!')).transform, onScreen }
    })
    await p.screenshot({ path: path.join(OUT, '2-swiped.png') })
    assert.equal(shown.labels.length, shown.onScreen, 'a time for each message on screen, and only those')
    assert.ok(shown.labels.includes('10:26') && shown.labels.includes('09:41'), "each message's own time " + JSON.stringify(shown.labels))
    assert.equal(shown.opacity, '1', 'fully shown at 64px')
    assert.equal(shown.mine, 'matrix(1, 0, 0, 1, -64, 0)', 'your messages slide aside, 64px at most')
    assert.equal(shown.theirs, 'none', "theirs stay put when their time fits beside them")
    await touch('touchEnd', x0 - 108, y); await sleep(500)
    assert.deepEqual(await p.evaluate(() => [document.querySelectorAll('.time-reveal').length, [...document.querySelectorAll('.msgs > .m')].filter(r => r.style.transform).length]), [0, 0], 'back home on release')
    assert.equal(await scrollTop(), top0, 'the conversation did not scroll')
    assert.equal(await p.locator('.composer .reply-bar:not([hidden]), .composer .replying').count(), 0, 'not taken for swipe-to-reply')
    assert.equal(await p.locator('.ctx-preview').count(), 0, 'nor a long press')

    // ---------------------------------------------------------------- the menu's full time
    const movie = await p.locator('.m .bubble', { hasText: 'Want to see a movie?' }).boundingBox()
    await touch('touchStart', movie.x + 30, movie.y + movie.height / 2); await sleep(650); await touch('touchEnd', movie.x + 30, movie.y + movie.height / 2)
    await p.locator('.ctx-time.on').waitFor()
    assert.equal(await p.locator('.ctx-time').innerText(), 'Today at 09:43 · Edited 09:50', 'the full time at the top of the menu, and when it was edited')
    const order = await p.evaluate(() => { const t = document.querySelector('.ctx-time').getBoundingClientRect(), r = document.querySelector('.ctx-reactions')?.getBoundingClientRect(), pv = document.querySelector('.ctx-preview').getBoundingClientRect(); return { aboveReactions: !r || t.bottom <= r.top + 1, abovePreview: t.bottom <= pv.top + 1 } })
    assert.deepEqual(order, { aboveReactions: true, abovePreview: true }, 'at the very top')
    await p.screenshot({ path: path.join(OUT, '3-menu.png') })
    await p.keyboard.press('Escape')
    await p.locator('.ctx-time').waitFor({ state: 'detached' })

    // ---------------------------------------------------------------- every message's time (Always)
    await p.evaluate(() => { localStorage.setItem('ui:msg-times', 'always'); dispatchEvent(new Event('chat-times')) })
    await sleep(300)
    const corners = await p.evaluate(() => [...document.querySelectorAll('.bubble > .m-meta')].map(e => ({ t: e.querySelector('time')?.textContent, ticks: e.querySelectorAll('.icon').length })))
    assert.ok(corners.length > 5 && corners.every(c => /^\d\d:\d\d$/.test(c.t) && c.ticks === 0), 'Always: each message has its time, without ticks ' + JSON.stringify(corners.slice(0, 3)))
    assert.deepEqual(await marks(p), ['Yesterday 21:00', '23:58', 'Today 00:01', '09:41', '10:26'], 'the marks stay as they are')
    await p.screenshot({ path: path.join(OUT, '4-always.png') })
    await p.evaluate(() => { localStorage.removeItem('ui:msg-times'); dispatchEvent(new Event('chat-times')) })
    await sleep(300)
    assert.equal(await p.locator('.bubble > .m-meta').count(), 0)

    // dark
    await p.evaluate(async () => (await import('/js/ui/appearance.js')).setTheme('dark'))
    await sleep(300)
    assert.equal(await p.evaluate(() => getComputedStyle(document.querySelector('.ts.mark')).color), 'rgb(161, 161, 170)', 'dark: #A1A1AA')
    await p.screenshot({ path: path.join(OUT, '5-dark.png') })
    await ctx.close()

    // ---------------------------------------------------------------- scrolling back: the floating date
    const desk = await browser.newContext({ viewport: { width: 1000, height: 760 }, deviceScaleFactor: 1, serviceWorkers: 'block' })
    const d = await desk.newPage(); watch(d, 'desk'); d.setDefaultTimeout(8000)
    await fixture(d, { older: 40 })
    const expect = await d.evaluate(async () => (await import('/js/ui/chat-time.js')).historyDate(T(9, 0, -3)))
    const sc = await d.locator('.thread:not([hidden]) .thread-scroll').boundingBox()
    await d.mouse.move(sc.x + sc.width / 2, sc.y + sc.height / 2)
    assert.equal(await d.locator('.history-date.on').count(), 0, 'not at rest at the bottom')
    for (let i = 0; i < 6; i++) { await d.mouse.wheel(0, -500); await sleep(60) }
    await d.locator('.history-date.on').waitFor()
    assert.equal(await d.locator('.history-date').innerText(), expect, 'the day of the topmost message on screen')
    const glass = await d.evaluate(() => { const cs = getComputedStyle(document.querySelector('.history-date')); return [cs.height, cs.borderRadius, cs.backdropFilter || cs.webkitBackdropFilter] })
    assert.equal(glass[0], '30px'); assert.equal(glass[1], '15px'); assert.match(glass[2], /blur\(16px\)/)
    const centred = await d.evaluate(() => { const a = document.querySelector('.history-date').getBoundingClientRect(), m = document.querySelector('.msgs').getBoundingClientRect(), n = document.querySelector('.thread-nav').getBoundingClientRect(); return { off: Math.abs(a.left + a.width / 2 - (m.left + m.width / 2)), below: Math.round(a.top - n.bottom) } })
    assert.ok(centred.off < 1.5, 'over the middle of the messages ' + JSON.stringify(centred))
    assert.equal(centred.below, 8, 'just under the heading')
    // the message field and jump-to-latest: frosted glass, not the shader
    const frost = await d.evaluate(() => ['.composer .field', '.jump', '.composer-mic'].map(sel => { const el = document.querySelector(`.thread:not([hidden]) ${sel}`), cs = getComputedStyle(el); return [el.dataset.lg || '', Boolean(el.querySelector(':scope > .lg-btn')), cs.backdropFilter || cs.webkitBackdropFilter] }))
    assert.ok(frost.every(([lg, canvas, bf]) => !lg && !canvas && /blur\(24px\)/.test(bf)), 'frosted ' + JSON.stringify(frost))
    assert.equal(await d.evaluate(() => document.querySelector('.thread:not([hidden]) .composer-action').dataset.lg), 'gl', 'the + keeps its liquid glass')
    await d.screenshot({ path: path.join(OUT, '6-history-date.png') })
    await sleep(1500)
    assert.equal(await d.locator('.history-date.on').count(), 0, 'fades 1.2s after scrolling stops')
    // new messages arriving or loading don't bring it: only the reader's own scrolling
    await d.evaluate(async () => { const { upsertMessage } = await import('/js/store.js'); upsertMessage({ id: 'x1', chat: 'r', type: 'text', text: 'ping', from: 'p', out: false, ts: Date.now(), status: 'sent' }) })
    await sleep(400)
    assert.equal(await d.locator('.history-date.on').count(), 0)
    // a jump to a quoted message shows its day for a moment
    await d.mouse.wheel(0, 4000); await sleep(600)
    await d.locator('.quote', { hasText: 'Earlier, number 1' }).click()
    await d.locator('.history-date.on').waitFor()
    assert.equal(await d.locator('.history-date').innerText(), expect)

    // with a mouse: rest on a message to see its time beside it
    await sleep(1800)
    const hb = await d.locator('.m .bubble', { hasText: 'Half past two' })
    await hb.scrollIntoViewIfNeeded(); await sleep(300)
    await hb.hover(); await sleep(600)
    const hover = await d.evaluate(() => { const l = document.querySelector('.time-hover.on'), b = [...document.querySelectorAll('.m .bubble')].find(x => said(x) === 'Half past two'); if (!l) return null; const r = l.getBoundingClientRect(), br = b.getBoundingClientRect(); return { text: l.textContent, beside: r.right <= br.left, level: Math.abs((r.top + r.bottom) / 2 - (br.top + br.bottom) / 2) < 3 } })
    assert.deepEqual(hover, { text: '10:26', beside: true, level: true }, 'beside your bubble, on its open side')
    await d.screenshot({ path: path.join(OUT, '7-hover.png') })
    await desk.close()

    // ---------------------------------------------------------------- Settings › Messages, with a real account
    const real = await browser.newContext({ viewport: { width: 430, height: 900 }, deviceScaleFactor: 2, serviceWorkers: 'block' })
    const s = await real.newPage(); watch(s, 'settings'); s.setDefaultTimeout(10000)
    await s.goto(BASE)
    const name = `ct_${Date.now().toString(36)}`
    assert.equal(await s.evaluate(async u => (await fetch('/auth/register', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify({ username: u, password: 'hunter22', display: 'Tia' }) })).status, name), 200)
    await s.reload(); await s.waitForSelector('.shell')
    await s.evaluate(async () => (await import('/js/views/sheets.js')).openSettings({ onLogout() {} }))
    const messages = s.locator('.sheet .group-title', { hasText: 'Messages' })
    await messages.evaluate(el => el.scrollIntoView({ block: 'start' })); await sleep(400)
    await s.screenshot({ path: path.join(OUT, '8-settings.png') })
    const receipts = s.locator('.sheet [role="switch"][aria-label="Read receipts"]')
    assert.equal(await receipts.getAttribute('aria-checked'), 'true', 'on by default')
    await receipts.click(); await sleep(500)
    assert.equal(await receipts.getAttribute('aria-checked'), 'false')
    assert.equal(await s.evaluate(async () => (await (await fetch('/api/bootstrap')).json()).prefs.receipts), false, 'kept on the server')
    await s.locator('.sheet [role="radiogroup"][aria-label="Time format"] [role="radio"]', { hasText: '12-hour' }).click()
    await s.locator('.sheet [role="radiogroup"][aria-label="Message times"] [role="radio"]', { hasText: 'Always' }).click()
    assert.deepEqual(await s.evaluate(() => [localStorage.getItem('ui:time-format'), localStorage.getItem('ui:msg-times')]), ['12', 'always'])
    await real.close()

    assert.deepEqual(errors, [], 'no page errors')
    console.log('PASS: marks after 5 minutes whoever speaks, a new day at midnight, the day only on its first mark, 12px grey on nothing; no time on bubbles; one status line (Sending… / Read 10:28) under the latest message, gone after a reply; 3px runs, 12px turns; swipe left shows every on-screen time (12px start, 64px max) and springs back without scrolling or replying; the menu shows the full and edited time; Always and 12-hour redraw at once; dark #A1A1AA; the floating day while scrolling back, fading after 1.2s, and on a jump; hover shows a time beside the bubble; Settings › Messages with read receipts kept on the server')
  } finally { await browser.close() }
})().catch(e => { console.error('FAIL:', e); process.exit(1) })
