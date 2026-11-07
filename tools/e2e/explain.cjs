// Search and explain: double-tap a message (yours or theirs) to start picking — the word under the finger
// is taken, with a handle at each end and an Explain button by it, and nothing is asked yet. Then slide
// to pick (whole words where words are spaced, single characters in Chinese), drag a handle to move one
// end, or tap a word to take it; a touch anywhere else stops picking. Explain asks. The page doesn't
// scroll and the long-press menu doesn't open while picking. The sheet shows each step as it happens,
// streams the answer with [n] marks pointing at the source cards, and offers questions to ask next (glass
// chips) that carry the conversation so far. Closing the sheet stops the answer and clears the marks.
// With a mouse, a selection gets the same Explain button; without the AI, a double-tap still loves the
// message. Uses browser-only fixtures and a scripted /api/ai/explain stream; no server data is created.
// npm run dev:e2e; node tools/e2e/explain.cjs [outdir]
const { chromium } = require('playwright'), assert = require('node:assert/strict'), fs = require('fs'), path = require('path')
const BASE = process.env.BASE || 'http://127.0.0.1:8787', OUT = process.argv[2] || path.join(process.cwd(), 'screenshots-explain')
if (!['127.0.0.1', 'localhost', '[::1]'].includes(new URL(BASE).hostname)) throw new Error('Use a local dev server')
fs.mkdirSync(OUT, { recursive: true })
const sleep = ms => new Promise(r => setTimeout(r, ms))
const json = body => ({ contentType: 'application/json', body: JSON.stringify(body) })

const EN = 'Shall we go to the Ghibli museum on Saturday? I heard the tickets sell out fast.'
const ZH = '我们周六去吉卜力美术馆吧'
const SOURCES = [
  { id: 1, title: 'Ghibli Museum, Mitaka', url: 'https://www.ghibli-museum.jp/en/', site: 'ghibli-museum.jp', snippet: '' },
  { id: 2, title: 'Ghibli Museum - Wikipedia', url: 'https://en.wikipedia.org/wiki/Ghibli_Museum', site: 'en.wikipedia.org', snippet: '' },
  { id: 3, title: 'Tickets | Lawson Ticket', url: 'https://l-tike.com/ghibli', site: 'l-tike.com', snippet: '' }
]
// what the server would stream, with the pauses between
const SCRIPT = [
  [0, { type: 'stage', stage: 'plan' }],
  [150, { type: 'queries', queries: ['Ghibli Museum', 'Ghibli Museum tickets'], lang: 'en' }],
  [0, { type: 'stage', stage: 'search' }],
  [500, { type: 'sources', sources: SOURCES }],
  [0, { type: 'stage', stage: 'compare' }],
  [300, { type: 'stage', stage: 'answer' }],
  [120, { type: 'delta', text: 'The **Ghibli Museum** is a museum in Mitaka, Tokyo, ' }],
  [700, { type: 'delta', text: 'devoted to the work of Studio Ghibli [1][2].\n\n' }],
  [700, { type: 'delta', text: '- Tickets are sold in advance only [3]\n- Entry is by a set time [1]' }],
  [100, { type: 'followups', questions: ['How do I get tickets?', 'Is it open on Tuesdays?', 'How do I get there?'] }],
  [0, { type: 'done' }]
]

// fetch('/api/ai/explain') answered in the page by a scripted stream, piece by piece
const STREAM = script => {
  window.__asked = []
  window.__aborted = 0
  const real = window.fetch
  window.fetch = (url, init) => {
    if (!String(url).includes('/api/ai/explain')) return real(url, init)
    window.__asked.push(JSON.parse(init.body))
    const steps = window.__script || script
    const enc = new TextEncoder()
    const body = new ReadableStream({
      async start(c) {
        for (const [wait, ev] of steps) {
          await new Promise(r => setTimeout(r, wait * (window.__slow || 1)))
          if (init.signal?.aborted) { window.__aborted++; c.error(new DOMException('aborted', 'AbortError')); return }
          c.enqueue(enc.encode(JSON.stringify(ev) + '\n'))
        }
        c.close()
      }
    })
    return Promise.resolve(new Response(body, { headers: { 'content-type': 'application/x-ndjson' } }))
  }
}

async function fixture(p, { assist = true } = {}) {
  await p.route('**/auth/status', r => r.fulfill(json({ authed: false })))
  await p.route('**/api/**', r => r.fulfill(json({ ok: true, messages: [] })))
  await p.goto(BASE)
  await p.locator('.auth').waitFor()
  await p.evaluate(async ([EN, ZH, assist]) => {
    const { state, thread, mergeMessages } = await import('/js/store.js'), { createThread } = await import('/js/views/thread.js')
    state.me = { id: 'me', display: 'Me' }; state.assist = assist
    state.chats = new Map([['r', { id: 'r', kind: 'dm', name: 'Mika', peer: { id: 'p', display: 'Mika' }, unread: 0 }]])
    const t = thread('r'); t.loaded = true; t.hasMore = false
    const now = Date.now()
    const older = Array.from({ length: 14 }, (_, i) => ({ id: `o${i}`, chat: 'r', type: 'text', text: `Earlier message ${i + 1}`, from: i % 2 ? 'me' : 'p', out: Boolean(i % 2), ts: now - 900000 + i * 1000, status: 'sent' }))
    mergeMessages('r', [...older,
      { id: 'en', chat: 'r', type: 'text', text: EN, from: 'p', out: false, ts: now - 120000, status: 'sent' },
      { id: 'zh', chat: 'r', type: 'text', text: ZH, from: 'me', out: true, ts: now - 60000, status: 'sent' }])
    const shell = document.createElement('div'); shell.className = 'shell'; shell.dataset.layout = 'stack'; shell.dataset.thread = 'open'
    const pane = document.createElement('section'); pane.className = 'pane'; pane.dataset.role = 'single'; shell.append(pane)
    document.querySelector('#app').replaceChildren(shell)
    window.testThread = createThread(pane, { onBack() {}, onInfo() {}, onDraw() {}, onCall() {}, socketSend() {} })
    testThread.setLayout('single'); await testThread.open('r')
  }, [EN, ZH, assist])
  await sleep(500)
}

// the centre of `word` (its n-th occurrence) in message `id`, in page coordinates
const spot = (p, id, word, n = 0) => p.evaluate(([id, word, n]) => {
  const bub = document.querySelector(`.m[data-id="${id}"] .bubble`)
  const walker = document.createTreeWalker(bub, NodeFilter.SHOW_TEXT)
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    let at = -1
    for (let k = 0; k <= n; k++) { at = node.data.indexOf(word, at + 1); if (at < 0) break }
    if (at < 0) continue
    const r = document.createRange(); r.setStart(node, at); r.setEnd(node, at + word.length)
    const b = r.getBoundingClientRect()
    return { x: b.left + b.width / 2, y: b.top + b.height / 2, left: b.left + 2, right: b.right - 2 }
  }
  return null
}, [id, word, n])

;(async () => {
  const browser = await chromium.launch()
  const errors = []
  try {
    // ---------------------------------------------------------------- touch
    const ctx = await browser.newContext({ viewport: { width: 430, height: 860 }, deviceScaleFactor: 2, hasTouch: true, isMobile: true, serviceWorkers: 'block' })
    await ctx.addInitScript(STREAM, SCRIPT)
    const p = await ctx.newPage()
    p.on('pageerror', e => errors.push(e.message))
    p.on('console', m => { if (m.type() === 'error' && !/Failed to load resource/.test(m.text())) errors.push(m.text()) })
    p.setDefaultTimeout(8000)
    await fixture(p)
    const cdp = await ctx.newCDPSession(p)
    const touch = (type, x, y) => cdp.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' || type === 'touchCancel' ? [] : [{ x, y, id: 1 }] })
    const scrollTop = () => p.evaluate(() => document.querySelector('.thread:not([hidden]) .thread-scroll').scrollTop)
    const marks = () => p.evaluate(() => [...document.querySelectorAll('.pick-mark')].map(m => Math.round(m.getBoundingClientRect().width)))
    const tapAt = async ({ x, y }) => { await touch('touchStart', x, y); await sleep(40); await touch('touchEnd', x, y) }
    const slide = async (from, to, { steps = 12, shot } = {}) => {
      await touch('touchStart', from.x, from.y); await sleep(40)
      for (let i = 1; i <= steps; i++) { await touch('touchMove', from.x + ((to.x - from.x) * i) / steps, from.y + ((to.y - from.y) * i) / steps); await sleep(18) }
      const during = { marks: await marks(), away: await p.locator('.explain-pill.is-away').count() }
      if (shot) await p.screenshot({ path: path.join(OUT, shot) })
      await touch('touchEnd', to.x, to.y); await sleep(120)
      return during
    }
    // what is picked, as the Explain button reads it ('' when not picking)
    const picked = () => p.evaluate(() => {
      const b = document.querySelector('.explain-pill:not(.is-away)')
      return b ? b.getAttribute('aria-label').replace(/^Search and explain “|”$/g, '') : ''
    })
    const handle = end => p.evaluate(end => { const r = document.querySelector(`.pick-handle.${end}`).getBoundingClientRect(); return { x: r.left + r.width / 2, y: r.top + r.height / 2 } }, end)
    const confirm = async () => { const b = await p.locator('.explain-pill:not(.is-away)').boundingBox(); await tapAt({ x: b.x + b.width / 2, y: b.y + b.height / 2 }) }
    const asks = () => p.evaluate(() => window.__asked.length)
    // double-tap at `from` — keeping the finger down to slide on to `to`, or holding — then Explain
    async function pick(from, to, { hold = 0 } = {}) {
      await tapAt(from); await sleep(110)
      await touch('touchStart', from.x, from.y); await sleep(60)
      if (hold) await sleep(hold)
      const steps = to ? 12 : 0
      for (let i = 1; i <= steps; i++) { await touch('touchMove', from.x + ((to.x - from.x) * i) / steps, from.y + ((to.y - from.y) * i) / steps); await sleep(18) }
      const end = to || from
      await touch('touchEnd', end.x, end.y); await sleep(250)
      assert.equal(await p.locator('.sheet').count(), 0, 'nothing is asked until Explain')
      await confirm()
    }
    const sheetOpen = () => p.locator('.sheet .xp').waitFor()
    const closeSheet = async () => { await p.keyboard.press('Escape'); await p.locator('.sheet .xp').waitFor({ state: 'detached' }); await sleep(250) }

    // 1. Theirs, in English. A double-tap starts picking: the word, its handles, the Explain button — nothing asked.
    const top0 = await scrollTop()
    const g = await spot(p, 'en', 'Ghibli'), mu = await spot(p, 'en', 'museum')
    await tapAt(g); await sleep(110); await tapAt(g); await sleep(300)
    assert.equal(await picked(), 'Ghibli')
    assert.equal(await p.locator('.pick-handle').count(), 2, 'a handle at each end')
    assert.equal(await p.locator('.explain-pill').evaluate(x => Boolean(x.dataset.lg)), true, 'the Explain button is liquid glass')
    const clear = await p.evaluate(() => { const b = document.querySelector('.explain-pill').getBoundingClientRect(), m = document.querySelector('.m[data-id="en"] .bubble').getBoundingClientRect(); return b.bottom <= m.top || b.top >= m.bottom })
    assert.ok(clear, 'the button stands clear of the message, so every word stays free to touch')
    assert.equal(await p.locator('.sheet').count(), 0, 'a double-tap alone asks nothing')
    assert.equal(await asks(), 0)
    await p.screenshot({ path: path.join(OUT, '0-picking.png') })
    // slide from one word to another: both, whole; the button steps aside while sliding
    const during = await slide(g, { x: mu.left + 6, y: mu.y }, { shot: '1-sliding.png' })
    assert.ok(during.marks.length >= 1 && during.marks[0] > 40, 'the picked words are marked while sliding ' + JSON.stringify(during))
    assert.equal(during.away, 1, 'the button steps aside while sliding')
    assert.equal(await picked(), 'Ghibli museum')
    // drag the end handle on to "Saturday", then the start handle back to "the"
    const sat = await spot(p, 'en', 'Saturday'), the = await spot(p, 'en', 'the')
    await slide(await handle('end'), { x: sat.left + 8, y: sat.y })
    assert.equal(await picked(), 'Ghibli museum on Saturday', 'the end handle moved the end')
    await slide(await handle('start'), { x: the.left + 3, y: the.y })
    assert.equal(await picked(), 'the Ghibli museum on Saturday', 'the start handle moved the start')
    await p.screenshot({ path: path.join(OUT, '1b-handles.png') })
    // a tap on a word takes just that word
    const tk = await spot(p, 'en', 'tickets')
    await tapAt(tk); await sleep(250)
    assert.equal(await picked(), 'tickets')
    // held still on the message while picking: never the long-press menu
    await touch('touchStart', mu.x, mu.y); await sleep(800); await touch('touchEnd', mu.x, mu.y); await sleep(250)
    assert.equal(await p.locator('.ctx-preview').count(), 0, 'no long-press menu while picking')
    assert.equal(await picked(), 'museum')
    assert.equal(await scrollTop(), top0, 'the page did not scroll while picking')
    // a touch anywhere else stops picking, asking nothing
    const other = await spot(p, 'o13', 'Earlier')
    await tapAt(other); await sleep(300)
    assert.deepEqual([await picked(), await p.locator('.pick-marks').count(), await p.locator('.explain-pill').count(), await asks()], ['', 0, 0, 0], 'stopped, nothing asked')
    // again, and Explain asks
    await tapAt(g); await sleep(110); await tapAt(g); await sleep(250)
    await slide(g, { x: mu.left + 6, y: mu.y })
    await confirm()
    await sheetOpen()
    assert.equal(await p.locator('.ctx-preview').count(), 0, 'the long-press menu stayed away')
    let asked = await p.evaluate(() => window.__asked.at(-1))
    assert.deepEqual([asked.text, asked.context, asked.question, asked.history], ['Ghibli museum', EN, '', []])
    assert.equal(await p.locator('.sheet .xp-pick').innerText(), 'Ghibli museum')
    assert.equal(await p.locator('.explain-pill').count(), 0, 'the button goes once asked')
    assert.equal(await p.locator('.pick-handle').count(), 0, 'the words stay marked, without handles')
    assert.ok(await p.locator('.pick-mark').count() >= 1)

    // the steps as they happen
    await p.locator('.xp-step[data-step="search"][data-state="doing"]').waitFor()
    assert.deepEqual(await p.locator('.xp-query').allInnerTexts(), ['Ghibli Museum', 'Ghibli Museum tickets'])
    assert.equal(await p.locator('.xp-step[data-step="plan"]').getAttribute('data-state'), 'done')
    await p.screenshot({ path: path.join(OUT, '2-searching.png') })
    await p.locator('.xp-answer p').first().waitFor()
    assert.ok(await p.locator('.xp-caret').count(), 'a caret while it writes')
    await p.screenshot({ path: path.join(OUT, '3-streaming.png') })
    await p.locator('.xp-chip').first().waitFor()
    await sleep(500)
    await p.screenshot({ path: path.join(OUT, '4-answered.png') })

    // the answer: bold, a list, and citation marks; the steps fold into one line
    assert.equal(await p.locator('.xp-answer b').innerText(), 'Ghibli Museum')
    assert.equal(await p.locator('.xp-answer li').count(), 2)
    assert.deepEqual(await p.locator('.xp-answer .xp-cite').allInnerTexts(), ['1', '2', '3', '1'])
    assert.equal(await p.locator('.xp-caret').count(), 0, 'no caret once written')
    assert.equal(await p.locator('.xp-summary').innerText(), 'Searched the web · 3 sources')
    // source cards: links that open in a new tab
    const cards = await p.locator('.xp-source').evaluateAll(a => a.map(x => [x.dataset.n, x.getAttribute('href'), x.target, x.rel]))
    assert.deepEqual(cards.map(c => c[1]), SOURCES.map(s => s.url))
    assert.ok(cards.every(c => c[2] === '_blank' && /noopener/.test(c[3])))
    // a citation points at its card
    await p.locator('.xp-answer .xp-cite').nth(2).click()
    assert.ok(await p.locator('.xp-source[data-n="3"]').evaluate(el => el.classList.contains('is-flash')), 'the cited card is shown')
    // the next questions are glass buttons, like every button
    await sleep(600)
    const lg = await p.locator('.xp-chip').evaluateAll(b => b.map(x => x.dataset.lg || ''))
    assert.ok(lg.length === 3 && lg.every(Boolean), 'the follow-up chips are liquid glass ' + JSON.stringify(lg))
    assert.ok(await p.locator('.xp-send').evaluate(x => Boolean(x.dataset.lg)), 'the ask button is liquid glass')

    // 2. A follow-up carries the conversation so far.
    await p.locator('.xp-chip', { hasText: 'How do I get tickets?' }).click()
    await p.locator('.xp-turn').nth(1).locator('.xp-answer p').first().waitFor()
    asked = await p.evaluate(() => window.__asked.at(-1))
    assert.equal(asked.question, 'How do I get tickets?')
    assert.equal(asked.history.length, 1)
    assert.match(asked.history[0].q, /Ghibli museum/)
    assert.match(asked.history[0].a, /Studio Ghibli \[1\]\[2\]/)
    assert.equal(await p.locator('.xp-turn').nth(1).locator('.xp-q').innerText(), 'How do I get tickets?')
    await p.locator('.xp-turn').nth(1).locator('.xp-summary').waitFor()
    // and your own question, typed
    await p.locator('.xp-input').fill('Can I bring a camera?')
    await p.locator('.xp-input').press('Enter')
    await p.locator('.xp-turn').nth(2).locator('.xp-summary').waitFor()
    asked = await p.evaluate(() => window.__asked.at(-1))
    assert.deepEqual([asked.question, asked.history.length], ['Can I bring a camera?', 2])
    await closeSheet()
    assert.equal(await p.locator('.pick-marks').count(), 0, 'closing clears the marks')

    // 3. Mine, in Chinese: a double-tap takes the word; a slide takes single characters.
    const zhou = await spot(p, 'zh', '周')
    await pick(zhou, null)
    await sheetOpen()
    await sleep(500)
    assert.equal(await p.locator('.sheet .xp').count(), 1, "the tap's own click doesn't close the sheet it opened")
    assert.equal((await p.evaluate(() => window.__asked.at(-1))).text, '周六', 'a double-tap takes the word')
    await closeSheet()
    const ji = await spot(p, 'zh', '吉'), guan = await spot(p, 'zh', '馆')
    await tapAt(zhou); await sleep(110); await tapAt(zhou); await sleep(250)
    await slide(ji, guan, { shot: '5-picking-zh.png' })
    assert.equal(await picked(), '吉卜力美术馆', 'a slide takes characters')
    const li = await spot(p, 'zh', '力')
    await slide(await handle('end'), { x: li.x, y: li.y })
    assert.equal(await picked(), '吉卜力', 'the end handle, a character at a time')
    await confirm()
    await sheetOpen()
    assert.equal((await p.evaluate(() => window.__asked.at(-1))).text, '吉卜力')
    await closeSheet()
    // the double-tap's finger can slide straight on, too
    await pick(ji, guan)
    await sheetOpen()
    assert.equal((await p.evaluate(() => window.__asked.at(-1))).text, '吉卜力美术馆')
    await closeSheet()

    // 4. Held still after the double-tap: still picking, never the long-press menu.
    await pick(tk, null, { hold: 700 })
    await sheetOpen()
    assert.equal(await p.locator('.ctx-preview').count(), 0, 'no menu after holding')
    assert.equal((await p.evaluate(() => window.__asked.at(-1))).text, 'tickets')

    // 5. Closing the sheet mid-answer stops it.
    await closeSheet()
    await p.evaluate(() => { window.__slow = 6 })
    await pick(g, null)
    await sheetOpen()
    await sleep(400)
    await closeSheet()
    await sleep(1500)
    assert.ok(await p.evaluate(() => window.__aborted) >= 1, 'the answer was stopped')
    await p.evaluate(() => { window.__slow = 1 })

    // 6. A failed answer offers to try again.
    await p.evaluate(() => { window.__script = [[0, { type: 'stage', stage: 'plan' }], [100, { type: 'error', error: "Couldn't write the answer" }]] })
    await pick(g, null)
    await sheetOpen()
    await p.locator('.xp-error').waitFor()
    assert.match(await p.locator('.xp-error').innerText(), /Couldn't write the answer/)
    await p.screenshot({ path: path.join(OUT, '6-error.png') })
    await p.evaluate(() => { window.__script = null })
    await p.locator('.xp-retry').click()
    await p.locator('.xp-summary').waitFor()
    assert.equal(await p.locator('.xp-error').count(), 0)
    await closeSheet()

    // 7. A single tap and a scroll still behave as before.
    await tapAt(g); await sleep(500)
    assert.equal(await p.locator('.sheet').count() + await p.locator('.pick-marks').count(), 0, 'one tap opens nothing')
    // dark
    await p.evaluate(async () => (await import('/js/ui/appearance.js')).setTheme('dark'))
    await pick(g, { x: mu.left + 6, y: mu.y })
    await sheetOpen(); await p.locator('.xp-summary').waitFor(); await sleep(600)
    await p.screenshot({ path: path.join(OUT, '7-answered-dark.png') })
    await closeSheet()
    await ctx.close()

    // ---------------------------------------------------------------- mouse
    const desk = await browser.newContext({ viewport: { width: 1100, height: 800 }, deviceScaleFactor: 1, serviceWorkers: 'block' })
    await desk.addInitScript(STREAM, SCRIPT)
    const d = await desk.newPage()
    d.on('pageerror', e => errors.push(e.message))
    await fixture(d)
    const dg = await spot(d, 'en', 'Ghibli'), dm = await spot(d, 'en', 'museum')
    await d.mouse.dblclick(dg.x, dg.y)
    await d.locator('.explain-pill').waitFor()
    assert.ok(await d.locator('.explain-pill').evaluate(x => Boolean(x.dataset.lg)), 'the Explain button is liquid glass')
    assert.equal(await d.locator('.m[data-id="en"] .reaction-burst').count(), 0, 'a double-click picks words, not a heart')
    // drag on from the double-click to take in the next word (the browser's own word selection)
    await d.mouse.move(dg.x, dg.y); await d.mouse.down({ clickCount: 2 }); await d.mouse.move(dm.right, dm.y, { steps: 6 }); await d.mouse.up({ clickCount: 2 })
    await sleep(400)
    await d.screenshot({ path: path.join(OUT, '8-pill.png') })
    await d.locator('.explain-pill').click()
    await d.locator('.sheet .xp').waitFor()
    assert.equal((await d.evaluate(() => window.__asked.at(-1))).text, 'Ghibli museum')
    await desk.close()

    // ---------------------------------------------------------------- without the AI
    const plain = await browser.newContext({ viewport: { width: 430, height: 860 }, deviceScaleFactor: 1, hasTouch: true, isMobile: true, serviceWorkers: 'block' })
    const q = await plain.newPage()
    q.on('pageerror', e => errors.push(e.message))
    const reacted = []
    await fixture(q, { assist: false })
    await q.route('**/api/react', r => { reacted.push(r.request().postDataJSON()); r.fulfill(json({ ok: true })) })
    const c2 = await plain.newCDPSession(q)
    const t2 = (type, x, y) => c2.send('Input.dispatchTouchEvent', { type, touchPoints: type === 'touchEnd' ? [] : [{ x, y, id: 1 }] })
    const pg = await spot(q, 'en', 'Ghibli')
    await t2('touchStart', pg.x, pg.y); await sleep(40); await t2('touchEnd', pg.x, pg.y); await sleep(110)
    await t2('touchStart', pg.x, pg.y); await sleep(40); await t2('touchEnd', pg.x, pg.y); await sleep(600)
    assert.equal(await q.locator('.sheet').count(), 0, 'no explain sheet without the AI')
    assert.deepEqual(reacted, [{ id: 'en', emoji: '❤️' }], 'a double-tap still loves the message')
    await plain.close()

    assert.deepEqual(errors, [], 'no page errors')
    console.log('PASS: a double-tap starts picking (word, handles, Explain button; nothing asked); slides pick whole words / single characters, handles move one end, a tap takes a word, a touch elsewhere stops; Explain asks; no scroll and no menu while picking; the sheet shows each step, streams a cited answer with source cards and glass follow-ups that carry the conversation; closing stops it; errors retry; a mouse selection gets an Explain button; without the AI a double-tap still loves the message')
  } finally { await browser.close() }
})().catch(e => { console.error('FAIL:', e); process.exit(1) })
