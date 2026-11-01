// Destructive actions ask first (HIG P0-5): closing the drawing board with
// ink on it (Close, Escape, the 手绘 tool again, switching to the details) and
// "从本设备删除". An empty board and a sent drawing close without asking; a
// message deleted here stays deleted after a reload, and the other side still
// has it. Neither the list's preview nor its search shows the words of a
// deleted last message, before or after a reload: the one before it takes
// its place, or only the time when this device doesn't have it. Screenshots for light / dark × folded / unfolded go to [outdir].
//   node tools/e2e/confirm-discard.cjs [outdir]        (CHECK=0: screenshots only)
const { chromium } = require('playwright')
const fs = require('fs')
const path = require('path')

const BASE = process.env.BASE || 'http://127.0.0.1:8787'
const OUT = process.argv[2] || path.join(process.cwd(), 'screenshots-confirm')
const CHECK = process.env.CHECK !== '0'
fs.mkdirSync(OUT, { recursive: true })
const sleep = ms => new Promise(r => setTimeout(r, ms))
const uniq = Math.random().toString(36).slice(2, 7)
const FOLDED = { width: 466, height: 678 }
const UNFOLDED = { width: 951, height: 669 }

;(async () => {
  const browser = await chromium.launch()
  const problems = []
  const results = {}
  let n = 0
  async function mk(name, vp, dark) {
    const ctx = await browser.newContext({ viewport: vp, locale: 'zh-CN', deviceScaleFactor: 1 })
    if (dark) await ctx.addInitScript(() => localStorage.setItem('ui:theme', 'dark'))
    const p = await ctx.newPage()
    p.on('pageerror', e => problems.push(`[${name}] ${e.message}`))
    return p
  }
  const shot = async (p, name) => { await sleep(450); await p.screenshot({ path: path.join(OUT, `${name}.png`) }) }
  async function reg(p, u) {
    await p.goto(BASE); await p.waitForSelector('.auth')
    await p.click('.auth-tab:has-text("创建账号")')
    await p.fill('#auth-u', u); await p.fill('#auth-p', 'hunter2')
    await p.click('.auth-form button[type=submit]'); await p.waitForSelector('.shell', { timeout: 15000 })
  }
  const expect = (key, ok) => { results[key] = ok; if (CHECK && !ok) problems.push(`expected: ${key}`) }

  for (const [combo, vp, dark] of [['light-folded', FOLDED, false], ['light-unfolded', UNFOLDED, false], ['dark-folded', FOLDED, true], ['dark-unfolded', UNFOLDED, true]]) {
    const amy = `amy${n}_${uniq}`, ben = `ben${n++}_${uniq}`
    const A = await mk(`A ${combo}`, vp, dark), B = await mk(`B ${combo}`, FOLDED, false)
    await reg(A, amy); await reg(B, ben)
    await A.click('.pane-list [data-item="compose"]'); await A.waitForSelector('.sheet'); await sleep(400)
    await A.fill('.sheet-search input', ben); await sleep(800)
    await A.click(`.sheet .cell:has-text("@${ben}")`); await A.waitForSelector('.thread:not([hidden])'); await sleep(400)
    for (const t of ['第一条', '第二条：要从本设备删除的']) { await A.fill('.composer textarea', t); await A.keyboard.press('Enter'); await sleep(500) }

    const onBoard = () => A.evaluate(() => document.querySelector('.shell').dataset.focus === 'artifact')
    const menuTitle = () => A.evaluate(() => document.querySelector('.menu .menu-title')?.textContent || null)
    const hasMsg = p => p.evaluate(() => [...document.querySelectorAll('.thread .m .bubble')].some(b => b.textContent.includes('要从本设备删除的')))
    async function openBoard(ink) {
      await A.click('.thread .composer-action'); await A.click('.composer-tool[data-tool="draw"]')
      await A.waitForSelector('.shell[data-focus=artifact]:not([data-anim]) .draw'); await sleep(300)
      if (!ink) return
      const box = await A.locator('.shell[data-focus=artifact] .draw-canvas').boundingBox()
      await A.mouse.move(box.x + 40, box.y + 60); await A.mouse.down()
      for (let i = 0; i < 20; i++) await A.mouse.move(box.x + 40 + i * 10, box.y + 60 + Math.sin(i / 2) * 30)
      await A.mouse.up()
    }
    const closeBoard = () => A.click('.pane-artifact .draw-close')

    // Close with ink asks; Cancel keeps the board.
    await openBoard(true)
    await closeBoard(); await sleep(500)
    expect(`${combo}: close asks`, Boolean(await menuTitle()))
    await shot(A, `${combo}-draw-close`)
    if (await menuTitle()) { await A.locator('.menu-item:has-text("取消")').click(); await sleep(500) }
    if (CHECK) {
      expect(`${combo}: cancel keeps board`, await onBoard())
      // Escape asks too; Escape again is Cancel.
      await A.keyboard.press('Escape'); await sleep(500)
      expect(`${combo}: escape asks`, Boolean(await menuTitle()))
      await A.keyboard.press('Escape'); await sleep(500)
      expect(`${combo}: escape cancel keeps board`, (await onBoard()) && !(await menuTitle()))
      // The 手绘 tool again asks; the 聊天信息 button asks.
      if (await A.locator('.thread .composer-tool[data-tool="draw"]').isVisible()) {
        await A.click('.thread .composer-tool[data-tool="draw"]'); await sleep(500)
        expect(`${combo}: tool toggle asks`, Boolean(await menuTitle()))
        await A.keyboard.press('Escape'); await sleep(400)
      }
      if (await A.locator('.thread [data-item="info"]').isVisible()) {
        await A.click('.thread [data-item="info"]'); await sleep(500)
        expect(`${combo}: details asks`, Boolean(await menuTitle()))
        await A.keyboard.press('Escape'); await sleep(400)
        expect(`${combo}: details cancel keeps board`, await A.evaluate(() => Boolean(document.querySelector('.pane-artifact .draw'))))
      }
      // Discard closes.
      await closeBoard(); await sleep(500)
      await A.locator('.menu-item.destructive:has-text("放弃")').click(); await sleep(800)
      expect(`${combo}: discard closes`, !(await onBoard()))
      // An empty board closes at once; sending doesn't ask.
      await openBoard(false); await closeBoard(); await sleep(600)
      expect(`${combo}: empty closes at once`, !(await onBoard()) && !(await menuTitle()))
      await openBoard(true); await A.click('.pane-artifact .draw-send'); await sleep(1200)
      expect(`${combo}: send does not ask`, !(await onBoard()) && !(await menuTitle()))
    } else if (await onBoard()) {
      await closeBoard(); await sleep(500)
      if (await menuTitle()) await A.locator('.menu-item.destructive:has-text("放弃")').click()
    }
    await sleep(500)

    // 从本设备删除 asks; Cancel keeps; Delete removes and survives a reload.
    await A.locator('.m .bubble:has-text("要从本设备删除的")').click({ button: 'right' }); await sleep(350)
    await A.locator('.menu-item:has-text("从本设备删除")').click(); await sleep(500)
    expect(`${combo}: delete asks`, Boolean(await menuTitle()))
    await shot(A, `${combo}-delete-confirm`)
    if (await menuTitle()) {
      await A.locator('.menu-item:has-text("取消")').click(); await sleep(400)
      expect(`${combo}: cancel keeps message`, await hasMsg(A))
      await A.locator('.m .bubble:has-text("要从本设备删除的")').click({ button: 'right' }); await sleep(350)
      await A.locator('.menu-item:has-text("从本设备删除")').click(); await sleep(500)
      await A.locator('.menu-item.destructive:has-text("删除")').click(); await sleep(500)
    }
    expect(`${combo}: deleted`, !(await hasMsg(A)))
    await A.reload(); await A.waitForSelector('.shell'); await sleep(900)
    if (!(await A.locator('.thread:not([hidden]) .m').count())) { await A.click('.row'); await A.waitForSelector('.thread:not([hidden]) .m') }
    await sleep(700)
    expect(`${combo}: still deleted after reload`, !(await hasMsg(A)))
    await shot(A, `${combo}-delete-reload`)
    await B.click('.row'); await B.waitForSelector('.thread:not([hidden]) .m'); await sleep(500)
    expect(`${combo}: the other side still has it`, await hasMsg(B))

    // A deleted *last* message: gone from the list's preview and its search.
    const LAST = '第三条：最后一条要删掉'
    const toList = async () => {
      if (await A.locator('.pane-list .row').first().isVisible()) return
      await A.click('.thread:not([hidden]) [data-item="back"]'); await A.waitForSelector('.shell[data-focus=list]:not([data-anim])'); await sleep(300)
    }
    const toThread = async () => {
      if (await A.locator('.thread:not([hidden]) .composer textarea').isVisible()) return
      await A.click('.row'); await A.waitForSelector('.thread:not([hidden]) .m'); await sleep(400)
    }
    const listText = () => A.evaluate(() => [...document.querySelectorAll('.pane-list .row')].map(r => `${r.textContent} ${r.getAttribute('aria-label') || ''} ${r.querySelector('[aria-label]')?.getAttribute('aria-label') || ''}`).join(' | '))
    const searchFor = async q => {
      await toList()
      await A.click('.pane-list input[type=search]'); await sleep(300)
      await A.fill('.pane-list input[type=search]', q); await sleep(700)
      const t = await A.evaluate(() => document.querySelector('.search-results')?.textContent || '')
      await A.fill('.pane-list input[type=search]', ''); await sleep(400)
      const recent = await A.evaluate(() => document.querySelector('.search-results')?.textContent || '')
      await A.keyboard.press('Escape'); await sleep(400)
      return t + ' ' + recent
    }
    await toThread()
    await A.fill('.composer textarea', LAST); await A.keyboard.press('Enter'); await sleep(700)
    expect(`${combo}: list shows the last message first`, (await listText()).includes('最后一条要删掉'))
    await A.locator(`.m .bubble:has-text("${LAST}")`).click({ button: 'right' }); await sleep(350)
    await A.locator('.menu-item:has-text("从本设备删除")').click(); await sleep(500)
    if (await menuTitle()) { await A.locator('.menu-item.destructive:has-text("删除")').click(); await sleep(600) }
    await toList()
    const after = await listText()
    expect(`${combo}: preview moves off the deleted last message`, !after.includes('最后一条要删掉'))
    expect(`${combo}: preview falls back to the one before`, CHECK ? after.includes('[手绘]') : true)
    await shot(A, `${combo}-list-after-delete`)
    expect(`${combo}: search doesn't find the deleted words`, !(await searchFor('最后一条')).includes('最后一条要删掉'))
    await A.reload(); await A.waitForSelector('.shell'); await sleep(1200)
    await toList()
    expect(`${combo}: after a reload the preview still hides it`, !(await listText()).includes('最后一条要删掉'))
    await shot(A, `${combo}-list-after-reload`)
    expect(`${combo}: after a reload search still doesn't find it`, !(await searchFor('最后一条')).includes('最后一条要删掉'))
    await A.context().close(); await B.context().close()
  }
  await browser.close()
  for (const [k, v] of Object.entries(results)) console.log(v ? 'ok  ' : 'FAIL', k)
  if (problems.length) { console.log('\nPROBLEMS:\n' + problems.join('\n')); process.exit(1) }
  console.log('\nall good')
})().catch(err => { console.error(err); process.exit(1) })
