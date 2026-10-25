// UI walkthrough against the mock WeChat server at iPhone Duo sizes.
// Needs Playwright with Chromium (npx playwright install chromium) and
// `npm run dev:mock` running in another terminal (fresh .wrangler state).
//   node tools/e2e/flows.cjs [outdir]      DSF=2 for smaller images
const { chromium } = require('playwright')
const fs = require('fs')
const path = require('path')

const BASE = 'http://127.0.0.1:8787'
const MOCK = 'http://127.0.0.1:8790'
const OUT = process.argv[2] || path.join(process.cwd(), 'screenshots')
fs.mkdirSync(OUT, { recursive: true })
const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Mobile/15E148 Safari/604.1'
const ctl = (cmd, body) => fetch(`${MOCK}/__ctl/${cmd}`, { method: 'POST', body: JSON.stringify(body || {}) }).then(r => r.json())
const sleep = ms => new Promise(r => setTimeout(r, ms))

;(async () => {
  const browser = await chromium.launch()
  const context = await browser.newContext({ viewport: { width: 466, height: 678 }, deviceScaleFactor: Number(process.env.DSF || 3), isMobile: true, hasTouch: true, userAgent: UA, locale: 'zh-CN', timezoneId: 'Asia/Shanghai' })
  const page = await context.newPage()
  const problems = []
  page.on('console', m => { if (['error', 'warning'].includes(m.type())) problems.push(`console.${m.type()}: ${m.text()}`) })
  page.on('pageerror', e => problems.push(`pageerror: ${e.message}`))
  const shot = async name => {
    await sleep(450)
    await page.screenshot({ path: path.join(OUT, `${name}.png`) })
    console.log('shot', name)
  }

  await page.goto(BASE)
  await page.waitForSelector('#pw')
  await page.fill('#pw', 'demo')
  await page.click('button[type=submit]')
  await page.waitForSelector('.shell .row', { timeout: 20000 })
  await sleep(800)

  // Incoming reorders the list while at the top
  await ctl('incoming', { from: 3, text: '会议改到 15:30 了' })
  await sleep(5500)
  await shot('a1-reorder')

  // Pinyin search
  await page.click('.search-pill input')
  await page.keyboard.type('zk')
  await sleep(1200)
  await shot('a2-search-pinyin')
  await page.click('.search-cancel')
  await sleep(500)

  // Swipe a row with touch
  const row = page.locator('.row', { hasText: '陈一鸣' }).first()
  const b = await row.boundingBox()
  await page.dispatchEvent('.row:has-text("陈一鸣") .row-inner', 'pointerdown', { pointerId: 7, clientX: b.x + 300, clientY: b.y + 30, button: 0, isPrimary: true, pointerType: 'touch' })
  for (let i = 1; i <= 8; i++) {
    await page.dispatchEvent('.row:has-text("陈一鸣") .row-inner', 'pointermove', { pointerId: 7, clientX: b.x + 300 - i * 15, clientY: b.y + 31, isPrimary: true, pointerType: 'touch' })
    await sleep(16)
  }
  await page.dispatchEvent('.row:has-text("陈一鸣") .row-inner', 'pointerup', { pointerId: 7, clientX: b.x + 180, clientY: b.y + 31, isPrimary: true, pointerType: 'touch' })
  await sleep(700)
  await shot('a3-swipe-left')
  await page.evaluate(() => document.querySelector('.list-scroll').dispatchEvent(new Event('scroll')))
  await sleep(600)

  // New chat from contacts
  await page.click('.bar-btn.tint')
  await sleep(1500)
  await shot('a4-contacts')
  await page.locator('.sheet .contact-row', { hasText: '赵磊' }).first().click()
  await sleep(1200)
  await shot('a5-new-thread')
  await page.click('.composer textarea')
  await page.keyboard.type('周末一起去爬山吗？自动回复')
  await page.keyboard.press('Enter')
  await sleep(4000)
  await shot('a6-reply')

  // Send a photo
  await page.setInputFiles('.composer input[type=file]', path.join(__dirname, '../../public/icons/icon-512.png'))
  await sleep(2500)
  await shot('a7-photo-sent')

  // Group info
  await page.click('.thread-nav .back')
  await sleep(600)
  await page.locator('.pin', { hasText: '产品设计组' }).first().click()
  await sleep(1000)
  await page.click('.thread-nav .info')
  await sleep(1500)
  await shot('a8-group-info')
  await page.keyboard.press('Escape')
  await sleep(600)
  await page.click('.thread-nav .back')
  await sleep(600)

  // Session ends on the phone
  await ctl('logout')
  await sleep(9000)
  await shot('a9-offline-banner')
  await page.click('.offline-banner .text-button')
  await sleep(2500)
  await shot('a10-relogin-qr')

  console.log('\nPROBLEMS:\n' + (problems.join('\n') || 'none'))
  await browser.close()
})().catch(e => { console.error(e); process.exit(1) })
