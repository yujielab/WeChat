// Focused UI regressions for the shared form language and keyboard controls.
// Start npm run dev:e2e, then: node tools/e2e/ui-polish.cjs [outdir]
const { chromium } = require('playwright')
const assert = require('node:assert/strict')
const fs = require('fs')
const path = require('path')
const BASE = process.env.BASE || 'http://127.0.0.1:8787'
const OUT = process.argv[2] || path.join(process.cwd(), 'screenshots-ui-polish')
if (!['127.0.0.1', 'localhost', '[::1]'].includes(new URL(BASE).hostname)) throw new Error('Run against a local wrangler dev instance')
fs.mkdirSync(OUT, { recursive: true })

;(async () => {
  const browser = await chromium.launch()
  try {
    const ctx = await browser.newContext({ viewport: { width: 466, height: 678 }, locale: 'zh-CN', serviceWorkers: 'block', reducedMotion: 'reduce' })
    const p = await ctx.newPage(), errors = []
    p.on('pageerror', e => errors.push(e.message))
    const focused = locator => locator.evaluate(el => el === document.activeElement)
    const fieldStyle = locator => locator.evaluate(el => {
      const cs = getComputedStyle(el)
      return { height: el.getBoundingClientRect().height, radius: cs.borderRadius, padding: cs.paddingLeft, font: cs.fontSize }
    })
    const shot = async name => {
      await p.evaluate(async () => {
        await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))
        await Promise.allSettled(document.getAnimations().filter(a => a.effect?.getComputedTiming().endTime < 2000).map(a => a.finished))
      })
      await p.screenshot({ path: path.join(OUT, `${name}.png`) })
    }
    const closeAll = async () => {
      while (await p.locator('.sheet.on').count()) {
        const count = await p.locator('.sheet.on').count()
        await p.keyboard.press('Escape')
        await p.waitForFunction(n => document.querySelectorAll('.sheet.on').length < n, count)
      }
      await p.locator('.sheet').waitFor({ state: 'detached' })
    }
    const settings = async () => {
      await p.evaluate(async () => {
        const { openSettings } = await import('/js/views/sheets.js')
        openSettings({ onLogout() {} })
      })
      await p.getByRole('dialog', { name: '设置', exact: true }).waitFor()
      await p.waitForSelector('.sheet.on')
    }

    await p.goto(BASE)
    await p.waitForSelector('.auth')
    const authStyle = await fieldStyle(p.locator('#auth-u'))
    await p.locator('.auth-submit').click()
    assert.equal(await p.getAttribute('#auth-u', 'aria-invalid'), 'true', 'native validation exposes the invalid field')
    await p.fill('#auth-u', `polish_${Date.now().toString(36)}`)
    assert.equal(await p.getAttribute('#auth-u', 'aria-invalid'), null, 'typing clears the invalid state')
    await p.fill('#auth-p', 'hunter2')
    assert.equal(await p.getAttribute('#auth-p', 'aria-invalid'), null)
    const authTab = p.locator('.auth-tab[aria-pressed="true"]')
    await authTab.focus()
    await p.keyboard.press('ArrowRight')
    assert.equal(await p.getAttribute('.auth', 'data-mode'), 'register')
    assert.equal(await focused(p.getByRole('button', { name: '创建账号', exact: true }).first()), true)
    await p.keyboard.press('Home')
    assert.equal(await p.getAttribute('.auth', 'data-mode'), 'login')
    await p.keyboard.press('End')
    assert.equal(await p.getAttribute('.auth', 'data-mode'), 'register')
    await p.fill('#auth-d', '小予')
    await shot('polish-auth')
    await p.locator('.auth-submit').click()
    await p.waitForSelector('.shell')

    await settings()
    const radios = p.getByRole('radiogroup', { name: '外观', exact: true })
    const assertRadio = async name => {
      const selected = radios.locator('[aria-checked="true"]')
      assert.equal(await selected.count(), 1)
      assert.equal(await selected.textContent(), name)
      assert.equal(await focused(selected), true, 'selection and keyboard focus move together')
      assert.equal(await radios.locator('[tabindex="0"]').count(), 1, 'one Tab stop per group')
    }
    await radios.locator('[aria-checked="true"]').focus()
    for (const [key, name] of [['ArrowRight', '深色'], ['ArrowDown', '自动'], ['ArrowRight', '浅色'], ['ArrowLeft', '自动'], ['ArrowUp', '深色'], ['Home', '浅色'], ['End', '自动'], ['Home', '浅色']]) {
      await p.keyboard.press(key)
      await assertRadio(name)
    }
    await p.keyboard.press('Tab')
    assert.equal(await focused(p.getByRole('switch', { name: '降低透明度', exact: true })), true)
    await p.keyboard.press('Shift+Tab')
    await assertRadio('浅色')
    await p.keyboard.press('Shift+Tab')
    assert.equal(await focused(p.getByRole('button', { name: '修改密码', exact: true })), true)
    await p.keyboard.press('Tab')
    await assertRadio('浅色')

    const auditWidth = async label => {
      const result = await p.getByRole('dialog', { name: '设置', exact: true }).evaluate(sheet => {
        const seg = sheet.querySelector('.seg'), cell = seg.closest('.cell')
        const s = seg.getBoundingClientRect(), c = cell.getBoundingClientRect()
        return {
          overflow: [sheet, sheet.querySelector('.sheet-body'), ...sheet.querySelectorAll('.group')].some(el => el.scrollWidth > el.clientWidth + 1),
          contained: s.left >= c.left && s.right <= c.right,
          close: sheet.querySelector('.sheet-head button').getBoundingClientRect().width
        }
      })
      assert.equal(result.overflow, false, `${label}: sheet and groups do not overflow`)
      assert.equal(result.contained, true, `${label}: appearance controls stay inside their row`)
      assert.ok(result.close >= 44, `${label}: close target is at least 44px`)
    }
    await p.setViewportSize({ width: 320, height: 678 })
    await auditWidth('320px')
    await shot('polish-settings-320')
    await p.evaluate(() => { document.documentElement.style.fontSize = '140%' })
    await auditWidth('320px, 140% text')
    await shot('polish-settings-large-text')
    await p.evaluate(() => { document.documentElement.style.fontSize = '' })
    await p.setViewportSize({ width: 466, height: 678 })

    // Put the real settings control at a dialog boundary. The Tab trap must
    // skip its unchecked radios when wrapping in either direction.
    await radios.locator('[aria-checked="true"]').focus()
    await p.keyboard.press('ArrowRight')
    await assertRadio('深色')
    await p.evaluate(async () => {
      const { openSheet } = await import('/js/views/overlay.js')
      openSheet({ title: '外观', content: document.querySelector('.seg') })
    })
    const appearance = p.getByRole('dialog', { name: '外观', exact: true })
    await p.waitForSelector('.sheet.on[aria-label="外观"]')
    const close = appearance.getByRole('button', { name: '关闭', exact: true })
    await close.focus()
    await p.keyboard.press('Shift+Tab')
    assert.equal(await focused(appearance.locator('[aria-checked="true"]')), true, 'backward wrap reaches the selected radio')
    await p.keyboard.press('Tab')
    assert.equal(await focused(close), true, 'forward wrap returns to Close')
    await closeAll()

    await settings()
    const mainSettings = p.getByRole('dialog', { name: '设置', exact: true })
    await mainSettings.locator('.profile-btn').click()
    const profile = p.getByRole('dialog', { name: '编辑资料', exact: true })
    await profile.waitFor()
    for (const id of ['profile-display', 'profile-bio']) {
      await profile.locator(`label[for="${id}"]`).click()
      assert.equal(await focused(p.locator(`#${id}`)), true, `${id}: label focuses its field`)
    }
    assert.deepEqual(await fieldStyle(p.locator('#profile-display')), authStyle, 'sign-in and sheet fields share height, radius, inset and text size')
    await p.keyboard.press('Escape')
    await profile.waitFor({ state: 'detached' })
    await mainSettings.getByRole('button', { name: '修改密码', exact: true }).click()
    const password = p.getByRole('dialog', { name: '修改密码', exact: true })
    await password.waitFor()
    for (const id of ['password-current', 'password-new']) {
      await password.locator(`label[for="${id}"]`).click()
      assert.equal(await focused(p.locator(`#${id}`)), true, `${id}: label focuses its field`)
    }
    assert.deepEqual(await fieldStyle(p.locator('#password-current')), authStyle)
    await shot('polish-password-dark')
    const prompt = () => p.locator('#password-current').evaluate(el => {
      const foreground = getComputedStyle(el, '::placeholder').color
      const background = getComputedStyle(el).backgroundColor
      const luminance = color => {
        const rgb = color.match(/[\d.]+/g).slice(0, 3).map(Number).map(v => {
          v /= 255
          return v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4
        })
        return rgb[0] * 0.2126 + rgb[1] * 0.7152 + rgb[2] * 0.0722
      }
      const a = luminance(foreground), b = luminance(background)
      return { foreground, background, contrast: (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05) }
    })
    const darkPrompt = await prompt()
    assert.ok(darkPrompt.contrast >= 4.5, 'dark placeholder contrast: ' + JSON.stringify(darkPrompt))
    await p.emulateMedia({ colorScheme: 'dark' })
    await p.evaluate(async () => { const { setTheme } = await import('/js/ui/appearance.js'); setTheme('system') })
    const systemPrompt = await prompt()
    assert.deepEqual(systemPrompt, darkPrompt, 'system dark and explicit dark share prompt colors')
    await shot('polish-password-system-dark')
    assert.deepEqual(errors, [])
    console.log('PASS: local registration; validation clears on input; keyboard auth modes; settings radio arrows/Home/End and one Tab stop; adjacent controls and dialog-boundary Tab wrap; 320px/140% text without overflow; 44px Close; labels focus fields; shared form dimensions; dark/system-dark placeholder contrast; no page errors.')
  } finally {
    await browser.close()
  }
})().catch(e => { console.error(e); process.exitCode = 1 })
