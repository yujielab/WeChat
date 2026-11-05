// Back's place and its steadiness (js/ui/strip.js, js/views/thread.js, css): the parts that are plain text; the
// behaviour — where it is, and that it stays put as columns slide — is tools/e2e/back.cjs.
import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const read = path => readFileSync(new URL(`../public/${path}`, import.meta.url), 'utf8')

test('each column\'s Back is carried against its column\'s slide, only while one column fills the screen', () => {
  const js = read('js/ui/strip.js')
  assert.match(js, /\.bar-item\[data-item="back"\]/)
  assert.match(js, /const by = count === 1 && !off \? \(p - i\) \* slide : 0/)
  assert.match(js, /el\.style\.translate = /, 'the individual translate property: it composes with the press transform')
  // A column's Back can arrive after the slide begins; and the width is measured when a slide starts.
  assert.match(js, /new MutationObserver\(\(\) => \{ stale = true \}\)/)
  assert.equal((js.match(/\bcarry\(\)/g) || []).length >= 3, true, 'carried at the start of a slide, of a swipe, and when the columns change')
  assert.match(read('css/duo-layout.css'), /\.bar-item\[data-item="back"\] \{ z-index: 2; \}/, 'what slides beneath passes under it')
})

test('a conversation has a Back only when one column fills the screen: beside the list or the details the other column is the way', () => {
  assert.match(read('js/views/thread.js'), /const back = pane\.dataset\.layout === 'single' \? \[\['back'\]\] : \[\]/)
})

test('the bars at the foot share their edges, so Back and New Chat don\'t shift between columns', () => {
  assert.match(read('css/list.css'), /\.list-bottombar \{[^}]*left: calc\(var\(--margin\) \+ var\(--safe-left\)\); right: calc\(var\(--margin\) \+ var\(--safe-right\)\); bottom: max\(var\(--safe-bottom\), 16px\)/)
  assert.match(read('css/columns.css'), /\.pane-sidebar \.side-bottombar \{ left: calc\(var\(--margin\) \+ var\(--safe-left\)\); right: calc\(var\(--margin\) \+ var\(--safe-right\)\); \}/)
  assert.match(read('css/draw.css'), /max\(var\(--safe-bottom\), 16px\) calc\(var\(--margin\) \+ var\(--safe-left\)\)/, 'the board\'s bar sits where every other column\'s does')
})
