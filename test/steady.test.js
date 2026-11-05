// What keeps the page from being pulled out of shape (public/js/ui/steady.js, the viewport meta, css/base.css).
import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { initSteady, isZoomKey, refusesDrop, refusesDrag, cappedRootSize, DYNAMIC_TYPE_MAX } from '../public/js/ui/steady.js'

const read = path => readFileSync(new URL(`../public/${path}`, import.meta.url), 'utf8')

// A tiny element: a tag, classes, attributes, a parent, and closest() over a selector list.
function el(tag, { classes = [], attrs = {}, parent = null } = {}) {
  const node = {
    tagName: tag.toUpperCase(), parent, scrollTop: 0, scrollLeft: 0,
    classList: { contains: c => classes.includes(c) },
    closest(list) {
      const tests = list.split(',').map(s => s.trim()).map(s => {
        const a = /^\[([\w-]+)="([^"]*)"\]$/.exec(s)
        return a ? n => n.attrs[a[1]] === a[2] : n => n.tagName.toLowerCase() === s
      })
      for (let n = node; n; n = n.parent) if (tests.some(t => t(n))) return n
      return null
    },
    attrs
  }
  return node
}

function page({ scale = 1, fontSize = 17, typing = false, scrollY = 0 } = {}) {
  const listeners = new Map()
  const add = (type, fn, options) => { (listeners.get(type) || listeners.set(type, []).get(type)).push({ fn, options }) }
  const meta = { content: 'width=device-width, initial-scale=1, minimum-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover' }
  const root = { style: { _: {}, removeProperty(n) { delete this._[n]; if (n === 'font-size') this.fontSize = undefined }, setProperty(n, v) { this._[n] = v } } }
  const body = {}
  const frames = []
  const vv = { scale, addEventListener: add }
  const doc = {
    documentElement: root, body, hidden: false,
    activeElement: typing ? { tagName: 'TEXTAREA' } : { tagName: 'BODY' },
    addEventListener: add,
    querySelector: sel => (/viewport/.test(sel) ? meta : null)
  }
  const win = {
    visualViewport: vv, scrollX: 0, scrollY, scrolledTo: null,
    addEventListener: add,
    scrollTo(x, y) { this.scrolledTo = [x, y]; this.scrollX = x; this.scrollY = y },
    requestAnimationFrame: fn => frames.push(fn),
    getComputedStyle: () => ({ fontSize: `${root.style.fontSize ? parseFloat(root.style.fontSize) : fontSize}px` })
  }
  initSteady(win, doc)
  const fire = (type, event = {}, target = 'doc') => {
    const e = { type, defaultPrevented: false, preventDefault() { this.defaultPrevented = true }, ...event }
    for (const { fn } of listeners.get(type) || []) fn(e)
    return e
  }
  return { win, doc, root, body, meta, vv, fire, listeners, frames }
}

test('browser zoom shortcuts are recognised: Ctrl/⌘ with + − 0, nothing else', () => {
  for (const key of ['+', '=', '-', '_', '0']) {
    assert.equal(isZoomKey({ key, ctrlKey: true }), true, `ctrl ${key}`)
    assert.equal(isZoomKey({ key, metaKey: true }), true, `meta ${key}`)
    assert.equal(isZoomKey({ key }), false, `${key} alone types`)
  }
  assert.equal(isZoomKey({ key: 'Add', code: 'NumpadAdd', ctrlKey: true }), true, 'the numeric pad')
  assert.equal(isZoomKey({ key: 'a', ctrlKey: true }), false, 'select all stays')
  assert.equal(isZoomKey({ key: 'c', metaKey: true }), false, 'copy stays')
  assert.equal(isZoomKey({ key: '-', ctrlKey: true, altKey: true }), false, 'AltGr combinations are someone typing')
})

test('files dropped anywhere, and anything dropped outside a field, are refused; text into a field is not', () => {
  const field = el('textarea'), bubble = el('div')
  assert.equal(refusesDrop({ target: bubble, dataTransfer: { types: ['Files'] } }), true)
  assert.equal(refusesDrop({ target: field, dataTransfer: { types: ['Files'] } }), true, 'a file onto the field would open it')
  assert.equal(refusesDrop({ target: bubble, dataTransfer: { types: ['text/uri-list', 'text/plain'] } }), true, 'a link onto the page')
  assert.equal(refusesDrop({ target: field, dataTransfer: { types: ['text/plain'] } }), false, 'text into the field')
  assert.equal(refusesDrop({ target: el('div', { attrs: { contenteditable: 'true' } }), dataTransfer: { types: ['text/plain'] } }), false)
})

test('links, pictures and the like are not dragged out of the page; text in a field is', () => {
  assert.equal(refusesDrag({ target: el('img') }), true)
  assert.equal(refusesDrag({ target: el('a') }), true)
  assert.equal(refusesDrag({ target: el('svg', { parent: el('a') }) }), true)
  assert.equal(refusesDrag({ target: el('span', { parent: el('a') }) }), true, 'what is inside a link')
  assert.equal(refusesDrag({ target: el('div', { attrs: { draggable: 'true' } }) }), true)
  assert.equal(refusesDrag({ target: el('textarea') }), false)
  assert.equal(refusesDrag({ target: el('div') }), false)
  assert.equal(refusesDrag({ target: {} }), false, 'a text node')
})

test('the system text size is capped where the layout stops holding', () => {
  assert.equal(DYNAMIC_TYPE_MAX, 21)
  assert.equal(cappedRootSize(17), '')
  assert.equal(cappedRootSize(21), '')
  assert.equal(cappedRootSize(23), '21px')
  assert.equal(cappedRootSize(53), '21px')
  assert.equal(cappedRootSize(NaN), '')
})

test('pinching (Safari), Ctrl/⌘ + wheel and the zoom keys are all stopped; scrolling and typing are not', () => {
  const p = page()
  for (const type of ['gesturestart', 'gesturechange', 'gestureend']) {
    assert.equal(p.fire(type).defaultPrevented, true, type)
    assert.equal(p.listeners.get(type)[0].options.passive, false, `${type} can be cancelled`)
  }
  assert.equal(p.fire('wheel', { ctrlKey: true }).defaultPrevented, true, 'trackpad pinch and ctrl+wheel')
  assert.equal(p.fire('wheel', { metaKey: true }).defaultPrevented, true)
  assert.equal(p.fire('wheel', { ctrlKey: false, metaKey: false }).defaultPrevented, false, 'plain scrolling')
  assert.equal(p.listeners.get('wheel')[0].options.passive, false)
  assert.equal(p.fire('keydown', { key: '+', ctrlKey: true }).defaultPrevented, true)
  assert.equal(p.fire('keydown', { key: '0', metaKey: true }).defaultPrevented, true)
  assert.equal(p.fire('keydown', { key: '+' }).defaultPrevented, false, 'typing a plus')
  assert.equal(p.listeners.get('keydown')[0].options, true, 'before anything else sees the key')
})

test('a file or link dropped on the page does not navigate; one dragged out of it does not leave', () => {
  const p = page()
  assert.equal(p.fire('dragover', { target: el('div'), dataTransfer: { types: ['Files'] } }).defaultPrevented, true)
  assert.equal(p.fire('drop', { target: el('div'), dataTransfer: { types: ['Files'] } }).defaultPrevented, true)
  assert.equal(p.fire('drop', { target: el('textarea'), dataTransfer: { types: ['text/plain'] } }).defaultPrevented, false)
  assert.equal(p.fire('dragstart', { target: el('img') }).defaultPrevented, true)
  assert.equal(p.fire('dragstart', { target: el('textarea') }).defaultPrevented, false)
})

test('the page, or a container that is never meant to scroll, is put back when it scrolls', () => {
  const p = page({ scrollY: 120 })
  p.fire('scroll', { target: p.doc })
  assert.deepEqual(p.win.scrolledTo, [0, 0], 'the page')
  for (const c of ['app', 'shell', 'pane']) {
    const box = el('div', { classes: [c, 'x'] })
    box.scrollTop = 40; box.scrollLeft = 8
    p.fire('scroll', { target: box })
    assert.deepEqual([box.scrollTop, box.scrollLeft], [0, 0], c)
  }
  const list = el('div', { classes: ['scroll'] })
  list.scrollTop = 300
  p.fire('scroll', { target: list })
  assert.equal(list.scrollTop, 300, 'a list scrolls as it should')
  assert.equal(p.listeners.get('scroll')[0].options, true, 'caught on the way down: scroll does not bubble')
})

test('with the keyboard up the page scroll is the system\'s doing and is left to ui/viewport.js', () => {
  const p = page({ scrollY: 120, typing: true })
  p.fire('scroll', { target: p.doc })
  assert.equal(p.win.scrolledTo, null)
})

test('a page scaled anyway is set back to 1 by setting the viewport again, and not more than once in a while', () => {
  const p = page({ scale: 1.6 })
  const keep = p.meta.content
  p.fire('resize')
  assert.match(p.meta.content, /maximum-scale=1/)
  assert.notEqual(p.meta.content, keep, 'set again for a moment')
  p.frames.shift()()
  assert.equal(p.meta.content, keep, 'then as it was')
  p.fire('resize')
  assert.equal(p.meta.content, keep, 'a second resize straight away leaves it')
  const calm = page({ scale: 1 })
  calm.fire('resize')
  assert.equal(calm.frames.length, 0, 'nothing to do at scale 1')
})

test('Dynamic Type past the cap is held at it; the default and smaller sizes are the system\'s', () => {
  const big = page({ fontSize: 53 })
  assert.equal(big.root.style.fontSize, '21px')
  const normal = page({ fontSize: 17 })
  assert.equal(normal.root.style.fontSize, undefined)
  // Back from Settings with a different size: read again.
  const again = page({ fontSize: 17 })
  again.win.getComputedStyle = () => ({ fontSize: '28px' })
  again.fire('pageshow')
  assert.equal(again.root.style.fontSize, '21px')
})

test('the viewport asks for no scaling, wide mode too; no element takes a pinch', () => {
  const html = read('index.html')
  const meta = /<meta name="viewport" content="([^"]+)"/.exec(html)[1]
  assert.match(meta, /(?:^|,\s*)width=device-width/)
  assert.match(meta, /initial-scale=1(?:,|$)/)
  assert.match(meta, /minimum-scale=1(?:,|$)/)
  assert.match(meta, /maximum-scale=1(?:,|$)/)
  assert.match(meta, /user-scalable=no/)
  assert.match(meta, /viewport-fit=cover/)
  const wide = /var wide = '([^']+)'/.exec(read('js/viewport-boot.js'))[1]
  assert.match(wide, /maximum-scale=1(?:,|$)/)
  assert.match(wide, /user-scalable=no/)
  assert.match(read('css/base.css'), /^\* \{ touch-action: pan-x pan-y; \}$/m)
  assert.match(read('sw.js'), /'\/js\/ui\/steady\.js'/, 'cached with the rest of the shell')
  assert.match(read('js/main.js'), /initSteady\(\)/)
})
