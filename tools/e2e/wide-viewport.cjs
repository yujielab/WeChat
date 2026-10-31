// App integration checks for the early Duo viewport. Chromium can check the
// resulting DOM/CSS, not Safari's native side column: confirm painting on Duo.
// npm run dev:e2e; node tools/e2e/wide-viewport.cjs
const { chromium } = require('playwright')
const assert = require('node:assert/strict')
const BASE = process.env.BASE || 'http://127.0.0.1:8787'
if (!['127.0.0.1', 'localhost', '[::1]'].includes(new URL(BASE).hostname)) throw new Error('Use a local dev server')
const UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 27_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2 Mobile/15E148 Safari/604.1'

;(async () => {
  const browser = await chromium.launch()
  try {
    const context = await browser.newContext({
      viewport: { width: 466, height: 678 }, screen: { width: 466, height: 678 },
      userAgent: UA, isMobile: true, hasTouch: true, serviceWorkers: 'block', locale: 'zh-CN'
    })
    const page = await context.newPage()
    const errors = []
    page.on('pageerror', error => errors.push(error.message))
    await page.route('**/auth/status', route => route.fulfill({ json: { authed: false } }))
    await page.route('**/api/**', route => route.fulfill({ json: { ok: true, messages: [] } }))
    await page.goto(BASE)
    await page.locator('.auth').waitFor()
    assert.equal(await page.evaluate(() => document.documentElement.dataset.wide), 'outer')
    assert.match(await page.locator('meta[name="viewport"]').getAttribute('content'), /^width=466,/)
    const auth = await page.evaluate(() => {
      const box = document.querySelector('.auth').getBoundingClientRect()
      const field = document.querySelector('.auth input').getBoundingClientRect()
      return { width: box.width, inputRight: field.right, inset: getComputedStyle(document.documentElement).getPropertyValue('--wide-inset-right') }
    })
    assert.equal(auth.width, 466)
    assert.equal(auth.inset.trim(), '90px')
    assert.ok(auth.inputRight <= 376, 'sign-in fields stay clear of system controls')

    // Browser-local conversation fixture; no accounts or messages are stored.
    await page.evaluate(async () => {
      const { state, thread, mergeMessages } = await import('/js/store.js')
      const { createThread } = await import('/js/views/thread.js')
      state.me = { id: 'me', display: '我' }
      state.calls = { enabled: true }
      state.chats = new Map([['wide-test', { id: 'wide-test', kind: 'dm', name: '全屏验证', peer: { id: 'peer', display: '朋友' } }]])
      const t = thread('wide-test'); t.loaded = true; t.hasMore = false
      mergeMessages('wide-test', [{ id: 'one', chat: 'wide-test', type: 'text', text: '背景铺满，按钮仍在可点击区域。', from: 'peer', ts: Date.now(), status: 'sent' }])
      const shell = document.createElement('div'); shell.className = 'shell'; shell.dataset.layout = 'stack'
      const pane = document.createElement('section'); pane.className = 'pane'; pane.dataset.role = 'single'
      shell.append(pane); document.querySelector('#app').replaceChildren(shell)
      window.wideActions = []
      window.wideThread = createThread(pane, { onBack() {}, onInfo() {}, onCall(id, type) { wideActions.push(type) }, socketSend() {} })
      wideThread.setLayout('single'); await wideThread.open('wide-test')
      const backdrop = document.querySelector('.thread-backdrop')
      backdrop.dataset.backdrop = 'test'
      backdrop.style.background = 'linear-gradient(90deg, #007aff, #ff2d55)'
    })
    await page.waitForTimeout(500)
    const geometry = () => page.evaluate(() => {
      const rect = selector => { const b = document.querySelector(selector).getBoundingClientRect(); return { left: b.left, right: b.right, top: b.top, bottom: b.bottom, width: b.width } }
      const backdrop = getComputedStyle(document.querySelector('.thread-backdrop'))
      return {
        app: rect('#app'), backdrop: rect('.thread-backdrop'), field: rect('.composer .field'), action: rect('.composer-action'),
        mask: backdrop.maskImage, fade: backdrop.getPropertyValue('--fade-right').trim(),
        controls: [...document.querySelectorAll('.thread .bar-item')].filter(e => e.getClientRects().length).map(e => { const b = e.getBoundingClientRect(); return { left: b.left, right: b.right, width: b.width, height: b.height } }),
        column: document.documentElement.dataset.column, kb: document.documentElement.dataset.kb
      }
    })
    const wide = await geometry()
    assert.equal(wide.app.width, 466)
    assert.equal(wide.backdrop.right, 466, 'background reaches the expanded layout edge')
    assert.equal(wide.mask, 'none', 'no background fade at the side column')
    assert.equal(wide.fade, '0px')
    assert.equal(wide.column, undefined)
    assert.ok(wide.field.right <= 376 && wide.action.right <= 376)
    for (const control of wide.controls) {
      assert.ok(control.left >= 0 && control.right <= 376, 'heading and bar controls avoid the system column')
      assert.ok(control.width >= 44 && control.height >= 44, 'touch targets retain their size')
    }
    await page.locator('.thread [data-item="audio"]').click()
    assert.deepEqual(await page.evaluate(() => wideActions), ['audio'])

    // The boot script leaves keyboard sizing to the existing visual viewport
    // tracker. Only that height is simulated here; Safari keyboard needs Duo.
    await page.locator('.composer textarea').focus()
    await page.evaluate(() => {
      Object.defineProperty(visualViewport, 'height', { configurable: true, get: () => 350 })
      visualViewport.dispatchEvent(new Event('resize'))
    })
    await page.waitForTimeout(150)
    const keyboard = await geometry()
    assert.equal(keyboard.kb, '1')
    assert.equal(keyboard.app.bottom, 350)
    assert.ok(keyboard.field.bottom <= 350 && keyboard.action.right <= 376)
    await page.evaluate(() => {
      document.querySelector('.composer textarea').blur()
      delete visualViewport.height
      visualViewport.dispatchEvent(new Event('resize'))
    })
    await page.waitForTimeout(200)
    assert.equal((await geometry()).app.bottom, 678)

    await page.goto(BASE + '/?wide=off')
    await page.locator('.auth').waitFor()
    assert.equal(await page.evaluate(() => document.documentElement.dataset.wide), undefined)
    assert.match(await page.locator('meta[name="viewport"]').getAttribute('content'), /^width=device-width,/)
    assert.deepEqual(errors, [])
    console.log('PASS: early wide app viewport; full-width backdrop without fade; sign-in and chat controls clear of side column; tappable calls; keyboard sizing/restoration; query opt-out; no page errors. Native Safari side-column painting still needs Duo.')
  } finally {
    await browser.close()
  }
})().catch(error => { console.error(error); process.exitCode = 1 })
