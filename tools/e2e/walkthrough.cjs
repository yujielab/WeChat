// UI walkthrough against the mock WeChat server at iPhone Duo sizes.
// Needs Playwright with Chromium (npx playwright install chromium) and
// `npm run dev:mock` running in another terminal (fresh .wrangler state).
//   node tools/e2e/walkthrough.cjs [outdir]      DSF=2 for smaller images
const { chromium } = require('playwright')
const fs = require('fs')
const path = require('path')

const BASE = process.env.BASE || 'http://127.0.0.1:8787'
const MOCK = process.env.MOCK || 'http://127.0.0.1:8790'
const OUT = process.argv[2] || path.join(process.cwd(), 'screenshots')
fs.mkdirSync(OUT, { recursive: true })

const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 26_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/26.1 Mobile/15E148 Safari/604.1'
const FOLDED = { width: 466, height: 678 }
const UNFOLDED = { width: 890, height: 626 }

const ctl = (cmd, body) => fetch(`${MOCK}/__ctl/${cmd}`, { method: 'POST', body: JSON.stringify(body || {}) }).then(r => r.json())
const sleep = ms => new Promise(r => setTimeout(r, ms))

;(async () => {
  const browser = await chromium.launch()
  const context = await browser.newContext({
    viewport: FOLDED,
    deviceScaleFactor: Number(process.env.DSF || 3),
    isMobile: true,
    hasTouch: true,
    userAgent: UA,
    colorScheme: process.env.SCHEME || 'light',
    locale: 'zh-CN',
    timezoneId: 'Asia/Shanghai'
  })
  const page = await context.newPage()
  const problems = []
  page.on('console', m => { if (['error', 'warning'].includes(m.type())) problems.push(`console.${m.type()}: ${m.text()}`) })
  page.on('pageerror', e => problems.push(`pageerror: ${e.message}`))
  const shot = async name => {
    await sleep(500)
    await page.screenshot({ path: path.join(OUT, `${name}.png`) })
    console.log('shot', name)
  }

  await page.goto(BASE)
  await page.waitForSelector('#pw', { timeout: 10000 })
  await shot('01-gate')
  await page.fill('#pw', 'wrong')
  await page.click('button[type=submit]')
  await page.waitForSelector('.field-error:not(:empty)')
  await shot('02-gate-error')
  await page.fill('#pw', 'demo')
  await page.click('button[type=submit]')

  // Either straight to chats (session alive) or the QR screen.
  await page.waitForSelector('.qr-wrap, .shell', { timeout: 15000 })
  if (await page.$('.qr-wrap')) {
    await page.waitForSelector('.qr-wrap img:not([hidden])', { timeout: 15000 })
    await shot('03-qr')
    await ctl('scan')
    await page.waitForSelector('.qr-wrap.scanned', { timeout: 15000 })
    await shot('04-scanned')
    await ctl('confirm')
  }
  await page.waitForSelector('.shell .row', { timeout: 30000 })
  await sleep(2500)
  await shot('05-list')

  // Scroll a little to collapse the title
  await page.evaluate(() => document.querySelector('.list-scroll').scrollTo(0, 120))
  await shot('06-list-scrolled')
  await page.evaluate(() => document.querySelector('.list-scroll').scrollTo(0, 0))

  // Open the design group chat
  const row = page.locator('.row', { hasText: '产品设计组' }).first()
  if (await row.count()) await row.click()
  else await page.locator('.pin', { hasText: '产品设计组' }).first().click()
  await page.waitForSelector('.thread:not([hidden]) .m', { timeout: 10000 })
  await sleep(800)
  await shot('07-thread-group')

  // Send a message
  await page.click('.composer textarea')
  await page.keyboard.type('好的，晚上把新版本发群里 👍')
  await shot('08-composer-typing')
  await page.keyboard.press('Enter')
  await sleep(1200)
  await shot('09-sent')

  // Long press menu
  const bubble = page.locator('.m.out .bubble').last()
  const box = await bubble.boundingBox()
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2)
  await page.mouse.down()
  await sleep(700)
  await page.mouse.up()
  await sleep(400)
  await shot('10-context-menu')
  await page.keyboard.press('Escape')
  await sleep(400)

  // Back to list
  await page.click('.thread-nav .back')
  await sleep(700)
  await shot('11-back-list')

  // Mom chat with a photo
  await page.locator('.row', { hasText: '妈妈' }).first().click()
  await page.waitForSelector('.thread:not([hidden]) .bubble.media img.loaded', { timeout: 10000 }).catch(() => {})
  await sleep(800)
  await shot('12-thread-photo')
  await page.click('.bubble.media')
  await sleep(900)
  await shot('13-viewer')
  await page.keyboard.press('Escape')
  await sleep(700)

  // Incoming message while in the chat list
  await page.click('.thread-nav .back')
  await sleep(600)
  await ctl('incoming', { from: 3, text: '好的，下午三点见～' })
  await sleep(6000)
  await shot('14-incoming')

  // Settings sheet
  await page.click('.me-btn')
  await sleep(900)
  await shot('15-settings')
  await page.keyboard.press('Escape')
  await sleep(600)

  // Unfold: iPhone Duo inner display
  await page.setViewportSize(UNFOLDED)
  await sleep(900)
  await shot('16-unfolded')
  await page.locator('.row', { hasText: '周末徒步' }).first().click()
  await sleep(1200)
  await shot('17-unfolded-thread')

  // Fold back with the chat open
  await page.setViewportSize(FOLDED)
  await sleep(900)
  await shot('18-folded-again')

  // Dark mode
  await page.emulateMedia({ colorScheme: 'dark' })
  await sleep(600)
  await shot('19-dark-thread')
  await page.click('.thread-nav .back')
  await sleep(700)
  await shot('20-dark-list')

  // Unfolded dark
  await page.setViewportSize(UNFOLDED)
  await sleep(800)
  await shot('21-dark-unfolded')

  // Reduced transparency fallback
  await page.evaluate(() => document.documentElement.setAttribute('data-glass', 'solid'))
  await sleep(400)
  await shot('22-solid-unfolded')

  console.log('\nPROBLEMS:\n' + (problems.join('\n') || 'none'))
  await browser.close()
})().catch(e => {
  console.error(e)
  process.exit(1)
})
