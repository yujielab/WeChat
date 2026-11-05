// The side rail's wiring (js/ui/viewport.js, js/ui/bars.js, css/rail.css): where the system's column is, the
// controls stand in a rail; elsewhere the bars stay at each column's foot. Behaviour is checked in a browser
// (tools/e2e/rail.cjs); this holds the parts that are plain text.
import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const read = path => readFileSync(new URL(`../public/${path}`, import.meta.url), 'utf8')

test('the axis is decided by the system column on the right edge, and nothing else', () => {
  const js = read('js/ui/viewport.js')
  // A right inset this wide is the Duo's column (other iPhones stay under 59pt even in landscape).
  assert.match(js, /EDGE_COLUMN_MIN = 64/)
  assert.match(js, /export function getBars\(\)/)
  assert.match(js, /export function onBars\(/)
  assert.match(js, /const next = inPage \|\| beside \? 'vertical' : 'horizontal'/)
  // The inset is read from --safe-right, which includes the early wide viewport's inset.
  assert.match(js, /width:var\(--safe-right\)/)
  assert.match(read('css/tokens.css'), /--safe-right: max\(env\(safe-area-inset-right, 0px\), var\(--wide-inset-right, 0px\)\)/)
})

test('every column that has a bar also has a rail to move it to, and moves it by axis', () => {
  for (const file of ['thread', 'chatList', 'sidebar', 'artifact']) {
    const js = read(`js/views/${file}.js`)
    assert.match(js, /class: 'duo-rail /, `${file} has a rail`)
    assert.match(js, /railed\(pane\)/, `${file} asks where its controls stand`)
    assert.match(js, /bars\.layout\('vertical', rail\.clientHeight\)/, `${file} lays out the rail by its height`)
    assert.match(js, /bars\.layout\('horizontal', /, `${file} keeps the bar at the foot`)
    assert.match(js, /onBars\(/, `${file} follows the window`)
  }
  // The leading column of a split view has no column of its own and keeps its bar.
  assert.match(read('js/ui/bars.js'), /export const railed = pane => pane\?\.dataset\.layout !== 'leading' && getBars\(\) === 'vertical'/)
})

test('the rail has its styles, linked and cached with the shell, and the bars at the foot give way to it', () => {
  const css = read('css/rail.css')
  assert.match(css, /\.duo-rail \{/)
  assert.match(css, /:is\(\.thread, \.pane-list, \.pane-sidebar, \.art-body\)\[data-bars="vertical"\] > \.duo-rail \{ display: flex; \}/)
  assert.match(css, /\[data-bars="vertical"\] :is\(\.side-bottombar, \.art-bottombar\) \{ display: none; \}/)
  assert.match(css, /:root\[data-bars="vertical"\] \.draw-dock \{/, 'the drawing board has its rail too')
  assert.match(read('index.html'), /<link rel="stylesheet" href="\/css\/rail\.css">/)
  assert.match(read('sw.js'), /'\/css\/rail\.css'/)
})

test('a menu from a control in the rail opens beside it', () => {
  assert.match(read('js/views/overlay.js'), /trigger\?\.closest\('\.duo-rail'\) && beside >= minX/)
})
