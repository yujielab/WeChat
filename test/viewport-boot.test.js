import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { runInNewContext } from 'node:vm'

const original = 'width=device-width, initial-scale=1, viewport-fit=cover'
const safari = 'Mozilla/5.0 (iPhone; CPU iPhone OS 27_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.2 Mobile/15E148 Safari/604.1'
const source = () => readFileSync(new URL('../public/js/viewport-boot.js', import.meta.url), 'utf8')

function events(object = {}) {
  const handlers = new Map()
  object.addEventListener = (name, listener) => {
    if (!handlers.has(name)) handlers.set(name, new Set())
    handlers.get(name).add(listener)
  }
  object.removeEventListener = (name, listener) => handlers.get(name)?.delete(listener)
  object.emit = (name, details = {}) => {
    for (const listener of [...(handlers.get(name) || [])]) listener.call(object, { type: name, ...details })
  }
  return object
}

// A small browser boundary, rather than a layout emulation. The invariant this
// checks is that the synchronous boot changes the meta without asking WebKit to
// lay out the default-width document first. Actual painting needs the Duo.
function browser(options = {}) {
  const properties = new Map()
  const dataset = {}
  const root = {
    dataset,
    style: {
      setProperty: (name, value) => properties.set(name, String(value)),
      removeProperty: name => properties.delete(name),
      getPropertyValue: name => properties.get(name) || ''
    },
    setAttribute(name, value) { if (name.startsWith('data-')) dataset[name.slice(5)] = String(value) },
    removeAttribute(name) { if (name.startsWith('data-')) delete dataset[name.slice(5)] },
    getAttribute(name) { return name.startsWith('data-') ? dataset[name.slice(5)] ?? null : null }
  }
  for (const name of ['clientWidth', 'clientHeight', 'offsetWidth', 'offsetHeight']) {
    Object.defineProperty(root, name, { get() { throw new Error(`early DOM layout read: ${name}`) } })
  }
  root.getBoundingClientRect = () => { throw new Error('early DOM geometry read') }
  const meta = { content: options.meta ?? original }
  const document = events({
    documentElement: root,
    hidden: false,
    visibilityState: 'visible',
    querySelector(selector) {
      assert.match(selector, /^meta\[name=["']?viewport["']?\]$/)
      return options.missingMeta ? null : meta
    }
  })
  const screen = {
    width: options.screenWidth ?? 466,
    height: options.screenHeight ?? 678,
    orientation: options.noOrientation ? undefined : events({ type: options.orientation ?? 'portrait-primary', angle: 0 })
  }
  const visualViewport = events({ width: options.visualWidth ?? 376, height: 626, scale: 1, offsetLeft: 0, offsetTop: 0 })
  const tasks = new Map()
  let taskId = 0
  let booting = true
  let naturalInnerWidth = options.innerWidth ?? 376
  const context = events({
    document, screen, visualViewport,
    navigator: { userAgent: options.userAgent ?? safari, standalone: options.standalone ?? false, platform: 'iPhone', maxTouchPoints: options.coarse === false ? 0 : 5 },
    location: { search: options.search ?? '', href: `https://cuven.test/${options.search ?? ''}` },
    outerWidth: options.outerWidth ?? 466,
    outerHeight: 678,
    orientation: options.windowOrientation ?? 0,
    scrollX: 0,
    scrollY: 0,
    URLSearchParams,
    matchMedia(query) {
      const matches = query.includes('pointer: coarse') ? options.coarse !== false
        : query.includes('standalone') ? options.standalone === true
          : query.includes('portrait') ? !screen.orientation?.type.startsWith('landscape')
            : false
      return events({ matches, media: query })
    },
    setTimeout(callback) { const id = ++taskId; tasks.set(id, callback); return id },
    clearTimeout(id) { tasks.delete(id) },
    requestAnimationFrame(callback) { const id = ++taskId; tasks.set(id, callback); return id },
    cancelAnimationFrame(id) { tasks.delete(id) },
    scrollTo() {},
    localStorage: { getItem() { throw new Error('viewport boot must not depend on storage') }, setItem() { throw new Error('viewport boot must not persist a query override') } }
  })
  Object.defineProperty(context, 'innerWidth', {
    get() { if (booting) throw new Error('early innerWidth read'); return naturalInnerWidth },
    set(value) { naturalInnerWidth = value }
  })
  context.window = context
  context.self = context
  runInNewContext(source(), context, { filename: 'viewport-boot.js' })
  booting = false
  return {
    context, root, meta, document, screen, visualViewport,
    flush() {
      for (let pass = 0; tasks.size && pass < 50; pass++) {
        const current = [...tasks.values()]
        tasks.clear()
        for (const callback of current) callback()
      }
      assert.equal(tasks.size, 0, 'viewport refresh must settle instead of repeatedly scheduling itself')
    }
  }
}

function assertWide(b) {
  assert.equal(b.root.dataset.wide, 'outer')
  assert.match(b.meta.content, /(?:^|,)\s*width=466(?:,|$)/)
  assert.match(b.meta.content, /height=device-height/)
  assert.match(b.meta.content, /initial-scale=1/)
  assert.match(b.meta.content, /minimum-scale=1/)
  assert.match(b.meta.content, /viewport-fit=cover/)
}

function assertDefault(b, expected = original) {
  assert.equal(b.meta.content, expected)
  assert.equal(b.root.dataset.wide, undefined)
  assert.equal(b.root.style.getPropertyValue('--wide-inset-right'), '')
}

test('Duo Safari applies the tested B parameters synchronously before any layout reads', () => {
  const b = browser()
  assertWide(b)
  assert.equal(b.root.style.getPropertyValue('--wide-inset-right'), '90px')
})

test('only the portrait Duo outer display is widened; other devices and browser hosts retain their viewport', () => {
  const cases = [
    { label: 'ordinary iPhone', screenWidth: 393, screenHeight: 852 },
    { label: 'unfolded Duo', screenWidth: 890, screenHeight: 626 },
    { label: 'inner-display split window', screenWidth: 890, screenHeight: 626, innerWidth: 445, outerWidth: 445 },
    { label: 'narrow outer-display window', outerWidth: 300 },
    { label: 'desktop pointer', coarse: false },
    { label: 'desktop Safari', userAgent: 'Mozilla/5.0 (Macintosh; Intel Mac OS X 15_0) AppleWebKit/605.1.15 Version/27.2 Safari/605.1.15' },
    { label: 'Chrome on iOS', userAgent: safari.replace('Version/27.2', 'CriOS/140.0.0.0') },
    { label: 'Firefox on iOS', userAgent: safari.replace('Version/27.2', 'FxiOS/140.0') },
    { label: 'Edge on iOS', userAgent: safari.replace('Version/27.2', 'EdgiOS/140.0') },
    { label: 'embedded WebKit without Safari', userAgent: safari.replace('Version/27.2 ', '').replace(' Safari/604.1', '') },
    { label: 'landscape-primary', orientation: 'landscape-primary', windowOrientation: 90 },
    { label: 'landscape-secondary', orientation: 'landscape-secondary', windowOrientation: -90 },
    { label: 'privacy-reported generic screen', screenWidth: 390, screenHeight: 844 }
  ]
  for (const { label, ...options } of cases) {
    const b = browser(options)
    assertDefault(b)
    b.flush()
    assertDefault(b)
  }
})

test('Home Screen WebKit is eligible, including a standalone user agent without the Safari token', () => {
  const b = browser({ standalone: true, userAgent: safari.replace('Version/27.2 ', '').replace(' Safari/604.1', '') })
  assertWide(b)
})

test('wide=off opts out before the initial layout and remains off after refresh', () => {
  const b = browser({ search: '?wide=off' })
  assertDefault(b)
  b.context.emit('resize')
  b.context.emit('pageshow')
  b.flush()
  assertDefault(b)
})

test('legacy orientation fallback supports portrait and rejects landscape', () => {
  assertWide(browser({ noOrientation: true, windowOrientation: 0 }))
  assertDefault(browser({ noOrientation: true, windowOrientation: 90 }))
  assertDefault(browser({ noOrientation: true, windowOrientation: -90 }))
})

test('the narrow visual viewport and keyboard changes do not disable an expanded layout', () => {
  const b = browser()
  b.visualViewport.width = 376
  b.visualViewport.height = 300
  b.context.innerWidth = 466
  b.context.emit('resize')
  b.visualViewport.emit('resize')
  b.flush()
  assertWide(b)
  assert.equal(b.root.style.getPropertyValue('--wide-inset-right'), '90px')
})

test('refreshed gutters account for zoom, distinguish narrow windows, and fall back for implausible measurements', () => {
  const b = browser()
  b.visualViewport.width = 191
  b.visualViewport.scale = 2
  b.context.emit('resize')
  b.flush()
  assertWide(b)
  assert.equal(b.root.style.getPropertyValue('--wide-inset-right'), '84px')
  b.visualViewport.width = 100
  b.visualViewport.scale = 1
  b.context.emit('resize')
  b.flush()
  assertDefault(b)
  for (const width of [600, 0]) {
    b.visualViewport.width = width
    b.context.emit('resize')
    b.flush()
    assertWide(b)
    assert.equal(b.root.style.getPropertyValue('--wide-inset-right'), '90px')
  }
})

test('the native screen orientation change event restores the original viewport', () => {
  const b = browser()
  assertWide(b)
  b.screen.orientation.type = 'landscape-secondary'
  b.screen.orientation.emit('change')
  b.flush()
  assertDefault(b)
})

test('a document without a viewport meta is left alone', () => {
  const b = browser({ missingMeta: true })
  b.context.emit('resize')
  b.context.emit('pageshow')
  b.flush()
  assertDefault(b)
})

test('rotating or unfolding restores the exact original meta, then refolding enables wide mode again', () => {
  const custom = 'width=device-width, initial-scale=1, viewport-fit=cover, interactive-widget=resizes-content'
  const b = browser({ meta: custom })
  assertWide(b)
  b.screen.orientation.type = 'landscape-primary'
  b.context.orientation = 90
  b.context.emit('orientationchange')
  b.flush()
  assertDefault(b, custom)
  b.screen.orientation.type = 'portrait-primary'
  b.context.orientation = 0
  b.screen.width = 890
  b.screen.height = 626
  b.context.emit('resize')
  b.flush()
  assertDefault(b, custom)
  b.screen.width = 466
  b.screen.height = 678
  b.context.emit('resize')
  b.flush()
  assertWide(b)
})

test('entering a narrow window disables the mode without confusing its own widened innerWidth with full-screen availability', () => {
  const b = browser()
  b.context.innerWidth = 466
  b.context.outerWidth = 300
  b.context.emit('resize')
  b.flush()
  assertDefault(b)
  b.context.outerWidth = 466
  b.context.emit('resize')
  b.flush()
  assertWide(b)
})

test('returning from the background and pageshow re-evaluate the physical screen', () => {
  const b = browser()
  b.screen.width = 890
  b.screen.height = 626
  b.document.hidden = false
  b.document.visibilityState = 'visible'
  b.document.emit('visibilitychange')
  b.flush()
  assertDefault(b)
  b.screen.width = 466
  b.screen.height = 678
  b.context.emit('pageshow')
  b.flush()
  assertWide(b)
})

test('the first-layout script is synchronous, precedes styles, and is available in the offline shell', () => {
  const html = readFileSync(new URL('../public/index.html', import.meta.url), 'utf8')
  const sw = readFileSync(new URL('../public/sw.js', import.meta.url), 'utf8')
  const headers = readFileSync(new URL('../public/_headers', import.meta.url), 'utf8')
  const script = html.match(/<script\b[^>]*\bsrc=["']\/js\/viewport-boot\.js["'][^>]*>/)
  assert.ok(script, 'index must load the early viewport boot script')
  assert.doesNotMatch(script[0], /\b(?:async|defer|type\s*=)/, 'the viewport script must block parsing')
  assert.ok(script.index > html.indexOf('name="viewport"'))
  const firstStyle = html.search(/<(?:link\b[^>]*\brel=["']stylesheet["']|style\b)/)
  assert.ok(firstStyle > script.index, 'no stylesheet can precede the viewport boot script')
  assert.match(sw, /['"]\/js\/viewport-boot\.js['"]/, 'the early script must be cached for offline startup')
  assert.doesNotMatch(sw, /const SHELL = 'shell-v34'/, 'existing clients need a fresh app shell cache')
  assert.match(headers, /script-src 'self'/, 'keep the existing CSP instead of allowing inline scripts')
})
