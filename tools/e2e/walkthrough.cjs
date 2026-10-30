// UI walkthrough for the messenger, at iPhone Duo sizes. Registers two users
// against a local `wrangler dev` and drives a full session, writing
// screenshots to [outdir]. Pass REALTIME dummy vars to the dev server to see
// the call UI. Needs Playwright with Chromium.
//   node tools/e2e/walkthrough.cjs [outdir]
const { chromium } = require('playwright')
const fs = require('fs')
const path = require('path')

const BASE = process.env.BASE || 'http://127.0.0.1:8787'
const OUT = process.argv[2] || path.join(process.cwd(), 'screenshots')
fs.mkdirSync(OUT, { recursive: true })
const FOLDED = { width: 466, height: 678 }
const UNFOLDED = { width: 890, height: 626 }
const sleep = ms => new Promise(r => setTimeout(r, ms))
const uniq = Math.random().toString(36).slice(2, 7)

;(async () => {
  const browser = await chromium.launch({ args: ['--use-fake-ui-for-media-stream', '--use-fake-device-for-media-stream'] })
  const problems = []
  async function mk(name, vp) {
    const ctx = await browser.newContext({ viewport: vp, deviceScaleFactor: Number(process.env.DSF || 2), isMobile: true, hasTouch: true, locale: 'zh-CN', permissions: ['microphone', 'camera'] })
    const p = await ctx.newPage()
    p.on('pageerror', e => problems.push(`[${name}] ${e.message}`))
    p.on('console', m => { if (m.type() === 'error') problems.push(`[${name}] ${m.text()}`) })
    return p
  }
  const shot = async (p, n) => { await sleep(800); await p.screenshot({ path: path.join(OUT, `${n}.png`) }); console.log('shot', n) }
  async function reg(p, u, d) {
    await p.goto(BASE); await p.waitForSelector('.auth')
    await p.click('.auth-tab:has-text("创建账号")')
    await p.fill('#auth-u', u); await p.fill('#auth-d', d); await p.fill('#auth-p', 'hunter2')
    await p.click('.auth-form button[type=submit]'); await p.waitForSelector('.shell', { timeout: 10000 })
  }

  const A = await mk('A', FOLDED), B = await mk('B', FOLDED)
  await A.goto(BASE); await A.waitForSelector('.auth'); await shot(A, '01-auth')
  const amy = `amy_${uniq}`, ben = `ben_${uniq}`
  await reg(A, amy, '艾米'); await reg(B, ben, '本'); await sleep(400)

  // settings (from the sidebar, one column back from the list)
  await A.click('.pane-list [data-item="back"]'); await A.waitForSelector('.shell[data-focus=sidebar]:not([data-anim])')
  await A.click('.side-me'); await A.waitForSelector('.sheet'); await sleep(500); await shot(A, '07-settings')
  await A.keyboard.press('Escape'); await sleep(400)
  await A.click('.side-scope[data-scope="all"]'); await A.waitForSelector('.shell[data-focus=list]:not([data-anim])')

  // open a DM
  await A.click('.pane-list [data-item="compose"]'); await A.waitForSelector('.sheet'); await sleep(400)
  await A.fill('.sheet-search input', ben); await sleep(600); await shot(A, '02-newchat')
  await A.click(`.sheet .cell:has-text("@${ben}")`); await A.waitForSelector('.thread:not([hidden])'); await sleep(400)
  await B.click('.row'); await B.waitForSelector('.thread:not([hidden])'); await sleep(300)

  // live typing + send
  await A.click('.composer textarea'); await A.type('.composer textarea', '你好，本 👋 这是 Cloudflare 自建的', { delay: 55 })
  await sleep(400); await shot(B, '03-live-typing')
  await A.keyboard.press('Enter'); await sleep(700)
  await B.fill('.composer textarea', '收到！延迟很低'); await B.keyboard.press('Enter'); await sleep(700)
  await shot(A, '04-thread')

  // drawing board (the details column, slid in beside the conversation)
  await A.click('.thread .composer-action');await A.click('.composer-tool[data-tool="draw"]')
  await A.waitForSelector('.shell[data-focus=artifact]:not([data-anim]) .draw'); await sleep(300)
  const box = await (await A.$('.draw-canvas')).boundingBox()
  await A.mouse.move(box.x + 60, box.y + 90); await A.mouse.down()
  for (let i = 0; i < 22; i++) await A.mouse.move(box.x + 60 + i * 11, box.y + 90 + Math.sin(i / 2) * 46)
  await A.mouse.up()
  await A.click('.draw-color[style*="007aff"]')
  await A.mouse.move(box.x + 80, box.y + 210); await A.mouse.down()
  for (let i = 0; i < 18; i++) await A.mouse.move(box.x + 80 + i * 10, box.y + 210 + Math.cos(i / 2) * 38)
  await A.mouse.up()
  await shot(A, '05-drawboard')
  await A.click('.draw-send'); await A.waitForSelector('.shell[data-focus=thread]:not([data-anim])'); await sleep(800); await shot(A, '06-thread-drawing')

  // call UI (needs REALTIME_* dummy vars on the dev server)
  await A.click('.thread [data-item="audio"]').catch(() => {})
  await sleep(700); await shot(B, '08-incoming-call')
  await A.click('.call .hang').catch(() => {}); await sleep(300)

  // unfolded split
  await A.setViewportSize(UNFOLDED); await sleep(800); await shot(A, '09-unfolded')
  await A.evaluate(() => document.documentElement.setAttribute('data-theme', 'dark')); await sleep(400); await shot(A, '10-unfolded-dark')

  console.log('\nPROBLEMS:\n' + (problems.filter(x => !/rtc|realtime|500|504|sessions/i.test(x)).join('\n') || 'none'))
  await browser.close()
})().catch(e => { console.error(e); process.exit(1) })
