// A layout audit of every screen, with real accounts, on an ordinary phone and on the iPhone Duo's outer screen
// (with its rail). On each screen, in the top layer (an open sheet, menu or viewer, else the app), every control
// that shows is checked:
//   covered   — something else is on top of it where it would be tapped (a stacking mistake)
//   clipped   — part of it is cut off by the screen's edge or a box that doesn't scroll
//   overlaps  — two controls sit on top of each other
//   small     — smaller than 28 × 28 to tap
//   truncated — a label cut short ("…") or clamped
// Findings are printed per screen and written to <outdir>/audit.json, with a screenshot of each screen.
// npm run dev:e2e; node tools/e2e/ui-audit.cjs [outdir]
const { chromium } = require('playwright'), fs = require('fs'), path = require('path')
const BASE = process.env.BASE || 'http://127.0.0.1:8787', OUT = process.argv[2] || path.join(process.cwd(), 'screenshots-audit')
if (!['127.0.0.1', 'localhost', '[::1]'].includes(new URL(BASE).hostname)) throw new Error('Use a local dev server')
fs.mkdirSync(OUT, { recursive: true })
const sleep = ms => new Promise(r => setTimeout(r, ms))
const uniq = Date.now().toString(36).slice(-5)
const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 27_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2 Mobile/15E148 Safari/604.1'
const DEVICES = {
  phone: { viewport: { width: 393, height: 852 }, isMobile: true, hasTouch: true },
  duo: { viewport: { width: 466, height: 678 }, screen: { width: 466, height: 678 }, userAgent: UA, isMobile: true, hasTouch: true }
}

// ---------------------------------------------------------------- the checks, in the page
function auditPage() {
  const INTERACTIVE = 'button, a[href], input:not([type=hidden]), textarea, select, [role=button], [role=switch], [role=radio], [role=tab], [role=menuitem], [role=menuitemradio], [role=link]'
  const shows = el => {
    if (!el.isConnected || el.closest('[hidden], [inert], [aria-hidden="true"]')) return false
    const r = el.getBoundingClientRect()
    if (r.width < 1 || r.height < 1) return false
    for (let e = el; e && e !== document.documentElement; e = e.parentElement) {
      const cs = getComputedStyle(e)
      if (cs.display === 'none' || cs.visibility === 'hidden' || Number(cs.opacity) < 0.05) return false
    }
    return true
  }
  const label = el => {
    const t = (el.getAttribute('aria-label') || el.getAttribute('title') || el.getAttribute('placeholder') || el.textContent || '').trim().replace(/\s+/g, ' ').slice(0, 40)
    const cls = typeof el.className === 'string' ? el.className.split(/\s+/).filter(c => c && !/^(is-|lg-|on$)/.test(c)).slice(0, 2).join('.') : ''
    return `${el.tagName.toLowerCase()}${cls ? '.' + cls : ''}${t ? ` “${t}”` : ''}`
  }
  // The top layer: the last open dialog, menu, viewer or call, else the whole app.
  const layers = [...document.querySelectorAll('.sheet.on, [role=dialog][aria-modal=true], .menu, [role=menu], .viewer, .call-screen, .call')].filter(shows)
  const root = layers.at(-1) || document.getElementById('app')
  const vw = innerWidth, vh = innerHeight
  const scrolls = el => { const cs = getComputedStyle(el); return /(auto|scroll)/.test(cs.overflowY + cs.overflowX) && (el.scrollHeight > el.clientHeight + 1 || el.scrollWidth > el.clientWidth + 1) }
  // the box that shows it: its nearest scroller, if any, else the screen
  const viewOf = el => {
    for (let e = el.parentElement; e && e !== document.body; e = e.parentElement) if (scrolls(e)) return { el: e, r: e.getBoundingClientRect() }
    return { el: null, r: { left: 0, top: 0, right: vw, bottom: vh } }
  }
  // the part of a box its view shows
  const cut = (r, v) => ({ left: Math.max(r.left, v.left, 0), top: Math.max(r.top, v.top, 0), right: Math.min(r.right, v.right, vw), bottom: Math.min(r.bottom, v.bottom, vh) })
  // under something floating, but its list still scrolls it clear
  const scrollsClear = (view, hit) => {
    if (!view.el || view.el.contains(hit)) return false
    const s = view.el, down = s.scrollHeight - s.clientHeight - Math.abs(s.scrollTop)
    return down > 8
  }
  const inField = (a, b) => {
    const field = [a, b].find(x => /^(INPUT|TEXTAREA)$/.test(x.el.tagName)), other = [a, b].find(x => x !== field)
    if (!field || !other) return false
    return other.r.left >= field.r.left - 1 && other.r.right <= field.r.right + 1 && other.r.top >= field.r.top - 1 && other.r.bottom <= field.r.bottom + 1
  }
  const findings = []
  const add = (kind, el, detail = '') => findings.push(`${kind}: ${label(el)}${detail ? ' — ' + detail : ''}`)
  const controls = [...root.querySelectorAll(INTERACTIVE)].filter(el => shows(el) && !el.closest('.lg-btn') && !el.disabled)
  const seen = []
  for (const el of controls) {
    const r = el.getBoundingClientRect()
    const view = viewOf(el)
    const v = view.r
    // wholly out of its view: scrolled away, not a problem
    if (r.bottom <= v.top || r.top >= v.bottom || r.right <= v.left || r.left >= v.right) continue
    // cut by the screen, or by a box that doesn't scroll
    if (!view.el && (r.left < -1 || r.right > vw + 1 || r.top < -1 || r.bottom > vh + 1)) add('clipped', el, `by the screen edge (${Math.round(r.left)},${Math.round(r.top)} ${Math.round(r.width)}×${Math.round(r.height)})`)
    for (let e = el.parentElement; e && e !== view.el && e !== document.body; e = e.parentElement) {
      const cs = getComputedStyle(e)
      if (!/(hidden|clip)/.test(cs.overflowX + cs.overflowY)) continue
      const c = e.getBoundingClientRect()
      const shown = Math.max(0, Math.min(r.right, c.right) - Math.max(r.left, c.left)) * Math.max(0, Math.min(r.bottom, c.bottom) - Math.max(r.top, c.top))
      const lost = 1 - shown / (r.width * r.height)
      if (lost > 0.25) { add('clipped', el, `by ${label(e)} (${Math.round(lost * 100)}% hidden)`); break }
    }
    const before = getComputedStyle(el, '::before')
    const grown = before.content !== 'none' && before.position === 'absolute' && parseFloat(before.left) < 0
    if (Math.min(r.width, r.height) < 28 && !/^(A|INPUT|TEXTAREA)$/.test(el.tagName) && !grown && !el.closest('p, li > a')) add('small', el, `${Math.round(r.width)}×${Math.round(r.height)}`)
    // what a tap lands on: the middle and four points inside
    const pts = [[0.5, 0.5], [0.3, 0.3], [0.7, 0.3], [0.3, 0.7], [0.7, 0.7]].map(([fx, fy]) => [r.left + r.width * fx, r.top + r.height * fy])
      .filter(([x, y]) => x > v.left && x < v.right && y > v.top && y < v.bottom && x > 0 && x < vw && y > 0 && y < vh)
    const over = new Map()
    for (const [x, y] of pts) {
      const hit = document.elementFromPoint(x, y)
      if (!hit || hit === el || el.contains(hit) || hit.contains(el) || scrollsClear(view, hit)) continue
      const top = hit.closest(INTERACTIVE) || hit
      over.set(label(top), (over.get(label(top)) || 0) + 1)
    }
    const centre = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2)
    const centreCovered = centre && centre !== el && !el.contains(centre) && !centre.contains(el) && !scrollsClear(view, centre) && pts.length
    for (const [what, n] of over) if (centreCovered || n >= 2) add('covered', el, `by ${what}`)
    // two controls on top of each other
    const vis = cut(r, v)
    for (const o of seen) {
      if (o.el.contains(el) || el.contains(o.el) || inField({ el, r }, o)) continue
      const ix = Math.min(vis.right, o.vis.right) - Math.max(vis.left, o.vis.left)
      const iy = Math.min(vis.bottom, o.vis.bottom) - Math.max(vis.top, o.vis.top)
      const area = x => Math.max(0, x.right - x.left) * Math.max(0, x.bottom - x.top)
      if (ix > 4 && iy > 4 && ix * iy > 0.2 * Math.min(area(vis), area(o.vis))) add('overlaps', el, label(o.el))
    }
    seen.push({ el, r, vis })
  }
  // labels cut short
  for (const el of root.querySelectorAll('*')) {
    if (!el.childNodes.length || !shows(el)) continue
    const cs = getComputedStyle(el)
    const ellipsis = cs.textOverflow === 'ellipsis' && el.scrollWidth > el.clientWidth + 1
    const clamped = cs.webkitLineClamp && cs.webkitLineClamp !== 'none' && el.scrollHeight > el.clientHeight + 2
    if (!ellipsis && !clamped) continue
    const r = el.getBoundingClientRect(), v = viewOf(el).r
    if (r.bottom <= v.top || r.top >= v.bottom) continue
    findings.push(`truncated: ${label(el)}`)
  }
  return { layer: layers.length ? label(layers.at(-1)) : 'app', findings: [...new Set(findings)] }
}

;(async () => {
  const browser = await chromium.launch()
  const report = {}
  const errors = []
  try {
    // ---------------------------------------------------------------- people and things to look at
    async function account(device, username, display) {
      const ctx = await browser.newContext({ serviceWorkers: 'block', deviceScaleFactor: 2, ...DEVICES[device] })
      const p = await ctx.newPage()
      p.on('pageerror', e => errors.push(`[${device} ${display}] ${e.message}`))
      p.setDefaultTimeout(8000)
      await p.goto(BASE)
      const st = await p.evaluate(async b => (await fetch('/auth/register', { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(b) })).status, { username, password: 'hunter22', display })
      if (st !== 200) throw new Error(`register ${username}: ${st}`)
      await p.reload(); await p.waitForSelector('.shell')
      return p
    }
    const api = (p, url, body) => p.evaluate(async ([url, body]) => (await fetch(url, body === undefined ? {} : { method: 'POST', headers: { 'content-type': 'application/json' }, body: JSON.stringify(body) })).json(), [url, body])
    const photo = (p, w, h, a, b) => p.evaluate(async ([w, h, a, b]) => {
      const c = document.createElement('canvas'); c.width = w; c.height = h
      const g = c.getContext('2d'), gr = g.createLinearGradient(0, 0, w, h); gr.addColorStop(0, a); gr.addColorStop(1, b); g.fillStyle = gr; g.fillRect(0, 0, w, h)
      const blob = await new Promise(r => c.toBlob(r, 'image/png'))
      const r = await fetch(`/api/media/upload?kind=moment&w=${w}&h=${h}`, { method: 'POST', headers: { 'content-type': 'image/png' }, body: blob })
      return { url: (await r.json()).url, type: 'image', w, h }
    }, [w, h, a, b])

    for (const device of Object.keys(DEVICES)) {
      const tag = `${device[0]}${uniq}`
      const B = await account(device, `ub_${tag}`, 'Coisini')
      const C = await account(device, `uc_${tag}`, 'Mira Castellanos-Whitfield')
      const A = await account(device, `ua_${tag}`, 'Tokio')
      const room = (await api(A, '/api/dm', { username: `ub_${tag}` })).room.id
      const lines = ['Morning!', 'Are we still on for Saturday?', 'Yes — the trailhead at 8, then lunch by the lake if the weather holds. I’ll bring the map.', '👍', 'Perfect', 'Can you send the photo from last time?', 'Sure', '你會說中文嗎？', '会一点点', 'Thank you very much.']
      for (let i = 0; i < lines.length; i++) await api(i % 2 ? A : B, '/api/messages', { room, type: 'text', text: lines[i] })
      await api(B, '/api/note', { text: 'Off to the mountains 🏔️ back Sunday' })
      await api(A, '/api/note', { text: 'Bad' })
      await api(C, '/api/contacts/add', { username: `ua_${tag}` })
      await api(B, '/api/moments', { text: 'Sunrise on the ridge this morning ☀️', media: [await photo(B, 1600, 1000, '#f6a35b', '#6a4c93')] })
      await api(A, '/api/moments', { text: 'Anyone up for a hike Saturday?' })
      await A.reload(); await A.waitForSelector('.row'); await sleep(800)

      const shots = []
      async function check(name, how) {
        const key = `${device} · ${name}`
        try {
          await how()
          await sleep(700)
          const r = await A.evaluate(auditPage)
          report[key] = r
          const file = `${device}-${String(shots.length + 1).padStart(2, '0')}-${name.replace(/[^\w]+/g, '-')}.png`
          await A.screenshot({ path: path.join(OUT, file) })
          shots.push(file)
          console.log(`\n${key}  [${r.layer}]${r.findings.length ? '' : '  ✓'}`)
          for (const f of r.findings) console.log('  ' + f)
        } catch (err) {
          report[key] = { error: err.message.split('\n')[0] }
          console.log(`\n${key}  ✗ couldn't reach: ${err.message.split('\n')[0]}`)
        }
      }
      const escape = async (n = 3) => { for (let i = 0; i < n; i++) { await A.keyboard.press('Escape'); await sleep(250) } }
      const home = async () => { await A.goto(BASE); await A.waitForSelector('.row'); await sleep(600) }
      const item = id => A.locator(`[data-item="${id}"]:visible`).first()
      const openChat = async () => { await A.locator(`.row[data-id="${room}"] .row-inner`).click(); await A.waitForSelector('.thread:not([hidden]) .composer'); await sleep(900) }

      // the app, signed out
      const out = await browser.newContext({ serviceWorkers: 'block', deviceScaleFactor: 2, ...DEVICES[device] })
      const O = await out.newPage()
      await O.goto(BASE); await O.waitForSelector('.auth')
      for (const [n, step] of [['sign-in', async () => {}], ['sign-up', async () => { await O.locator('.auth-tab').nth(1).click() }]]) {
        await step(); await sleep(500)
        const r = await O.evaluate(auditPage)
        report[`${device} · ${n}`] = r
        await O.screenshot({ path: path.join(OUT, `${device}-00-${n}.png`) })
        console.log(`\n${device} · ${n}  [${r.layer}]${r.findings.length ? '' : '  ✓'}`); for (const f of r.findings) console.log('  ' + f)
      }
      await out.close()

      const sidebar = async () => {
        if (device === 'duo') await A.locator('.page-item[data-page="menu"]').click()
        else await item('back').click()
        await A.locator('.side-me:visible').waitFor()
      }
      const longPress = async loc => {
        const b = await loc.boundingBox()
        const cdp = await A.context().newCDPSession(A)
        await cdp.send('Input.dispatchTouchEvent', { type: 'touchStart', touchPoints: [{ x: b.x + 20, y: b.y + b.height / 2, id: 1 }] }); await sleep(650)
        await cdp.send('Input.dispatchTouchEvent', { type: 'touchEnd', touchPoints: [] })
        await A.locator('.menu').waitFor()
      }

      await check('chats', async () => {})
      await check('chats-scrolled', async () => { await A.evaluate(() => { const s = [...document.querySelectorAll('.pane-list .scroll, .pane-list [class*="scroll"]')].find(x => x.scrollHeight > x.clientHeight + 4); if (s) s.scrollTop = s.scrollHeight }) })
      await home()
      await check('chats-search', async () => { await A.locator('.search-pill:visible, [data-item="search"]:visible').first().click(); await sleep(300) })
      await home()
      await check('new-chat', async () => { await item('compose').click(); await A.locator('.sheet.on').waitFor() })
      await escape(); await home()
      await check('sidebar', sidebar)
      await check('settings-top', async () => { await A.locator('.side-me:visible').click(); await A.locator('.sheet.on .group-title').first().waitFor() })
      for (const part of ['Messages', 'Smart', 'Notifications']) {
        await check(`settings-${part.toLowerCase()}`, async () => { await A.locator('.sheet.on .group-title', { hasText: part }).first().evaluate(el => el.scrollIntoView({ block: 'center' })) })
      }
      await check('profile', async () => { await A.locator('.sheet.on .group-title').first().evaluate(el => el.closest('.sheet-body').scrollTop = 0); await A.locator('.sheet.on .sheet-body > div > :first-child').first().click(); await sleep(600) })
      await escape(); await home()
      await check('your-note', async () => { await A.locator('.notes .note').first().click(); await A.locator('.sheet.on').waitFor() })
      await escape(); await home()
      await check('requests', async () => { await A.locator('.list-requests:visible, .page-item[data-page="requests"]:visible').first().click(); await A.locator('.sheet.on').waitFor() })
      await escape(); await home()
      await check('conversation', openChat)
      await check('conversation-typing', async () => { await A.locator('.thread:not([hidden]) .composer textarea').fill('On my way, see you in ten minutes!') })
      await A.locator('.thread:not([hidden]) .composer textarea').fill('')
      await check('add-panel', async () => { await A.locator('.thread:not([hidden]) .composer-action').click() })
      await escape(1); await sleep(400)
      await check('message-menu', async () => { await longPress(A.locator('.thread:not([hidden]) .m.in .bubble').last()) })
      await escape(1); await sleep(700)
      await check('replying', async () => { await longPress(A.locator('.thread:not([hidden]) .m.in .bubble').last()); await A.locator('.menu [role=menuitem]', { hasText: 'Reply' }).click() })
      await escape(1); await sleep(400)
      await check('stickers', async () => { await A.locator('.thread:not([hidden]) .composer-action').click(); await A.locator('.composer-tool[data-tool="sticker"]:visible').click(); await A.locator('.sheet.on').waitFor() })
      await escape()
      await check('details', async () => { await item('info').click(); await A.locator('.art-body[data-kind="info"]').waitFor() })
      await escape(); await home(); await openChat()
      await check('drawing', async () => { await A.locator('.thread:not([hidden]) .composer-action').click(); await A.locator('.composer-tool[data-tool="draw"]').click(); await A.locator('.draw-palette').waitFor() })
      await escape(); await home()
      await check('moments', async () => { await A.locator('.list-moments:visible, .page-item[data-page="moments"]:visible').first().click(); await A.locator('.moments-home').waitFor() })
      await check('moment-photo', async () => { await A.locator('.moments-home .mo-photo, .moments-home .mo-slide').first().click(); await A.locator('.viewer').waitFor() })
      await escape(1)
      await check('new-moment', async () => { await A.locator('.moments-home [aria-label="New moment"]').first().click(); await A.locator('.moments-editor').waitFor() })
      await escape(); await home()
      await check('memories', async () => { if (device === 'duo') await A.locator('.page-item[data-page="memories"]').click(); else { await sidebar(); await A.locator('.side-memories').click() } await A.locator('.memories-page').waitFor() })
      await escape(); await home()
      for (const p of [A, B, C]) await p.context().close()
    }
    fs.writeFileSync(path.join(OUT, 'audit.json'), JSON.stringify(report, null, 2))
    const total = Object.values(report).reduce((n, r) => n + (r.findings?.length || 0), 0)
    console.log(`\n${Object.keys(report).length} screens, ${total} findings; page errors: ${errors.length ? errors.join(' | ') : 'none'}`)
  } finally { await browser.close() }
})().catch(e => { console.error('FAIL:', e); process.exit(1) })
