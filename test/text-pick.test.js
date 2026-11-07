// Picking words out of a message (public/js/ui/text-pick.js): a double-tap
// takes the word under the finger; a slide takes whole words in spaced text
// and single characters in Chinese and Japanese; a dragged handle moves one end. The gesture itself is
// checked in a browser (tools/e2e/explain.cjs).
import test from 'node:test'
import assert from 'node:assert/strict'
import { segmentsOf, wordAt, unitAt, pickSpan, dragEdge, pickedText } from '../public/js/ui/text-pick.js'

const pick = (text, anchor, focus = anchor, moved = false) => pickedText(text, pickSpan(text, segmentsOf(text), anchor, focus, moved))

test('a double-tap takes the word under the finger', () => {
  const t = 'Shall we go to the Ghibli museum?'
  assert.equal(pick(t, t.indexOf('Ghibli') + 2), 'Ghibli')
  assert.equal(pick(t, t.indexOf('museum') + 5), 'museum')
  // on a space or a mark: the nearest word
  assert.equal(pick(t, t.indexOf(' Ghibli')), 'the')
  assert.equal(pick(t, t.length - 1), 'museum')
  const zh = '我们周六去吉卜力美术馆吧'
  assert.equal(pick(zh, zh.indexOf('周') + 1), '周六')
})

test('sliding in spaced text reaches whole words, either way', () => {
  const t = 'Shall we go to the Ghibli museum?'
  const a = t.indexOf('Ghibli') + 1
  assert.equal(pick(t, a, t.indexOf('museum') + 1, true), 'Ghibli museum')
  assert.equal(pick(t, a, t.length - 1, true), 'Ghibli museum', 'the question mark is left out')
  assert.equal(pick(t, a, t.indexOf('the'), true), 'the Ghibli', 'backwards too')
})

test('sliding in Chinese and Japanese reaches single characters', () => {
  const zh = '我们周六去吉卜力美术馆吧'
  const a = zh.indexOf('吉')
  assert.equal(pick(zh, a, a, true), '吉', 'one character')
  assert.equal(pick(zh, a, zh.indexOf('力'), true), '吉卜力')
  assert.equal(pick(zh, a, zh.indexOf('馆'), true), '吉卜力美术馆')
  const ja = '東京タワーに行こう'
  assert.equal(pick(ja, 0, 1, true), '東京')
  // mixed: Latin words stay whole inside Chinese
  const mix = '用ChatGPT写代码'
  assert.equal(pick(mix, 0, mix.indexOf('GPT'), true), '用ChatGPT')
})

test('characters outside the basic plane are never cut in half', () => {
  const t = '𠮷野家 is open'
  const u = unitAt(t, segmentsOf(t), 1) // the low half of 𠮷
  assert.deepEqual(u, { start: 0, end: 2 })
  assert.equal(pick(t, 1, 1, true), '𠮷')
})

test('nothing to pick in punctuation alone, and the edges are tidied', () => {
  assert.equal(wordAt(segmentsOf('?!'), 0), null)
  assert.equal(pick('...', 0, 2, true), '...', 'marks only are kept as they are')
  assert.equal(pickedText('“Hello,” she said', { start: 0, end: 8 }), 'Hello')
  assert.equal(pickedText('x', null), '')
})

test('dragging a handle moves that end only, and may cross the other', () => {
  const t = 'Shall we go to the Ghibli museum on Saturday?'
  const segs = segmentsOf(t)
  const g = t.indexOf('Ghibli'), m = t.indexOf('museum')
  const word = { start: g, end: g + 'Ghibli'.length }
  const take = span => t.slice(span.start, span.end)
  // the end handle, out to "museum": the start stays
  assert.equal(take(dragEdge(t, segs, word.start, m + 2)), 'Ghibli museum')
  // the start handle, back to "the": the end stays
  assert.equal(take(dragEdge(t, segs, word.end, t.indexOf('the') + 1)), 'the Ghibli')
  // the end handle dragged past the start: the span turns round
  assert.equal(take(dragEdge(t, segs, word.start, t.indexOf('to'))), 'to the ')
  assert.equal(pickedText(t, dragEdge(t, segs, word.start, t.indexOf('to'))), 'to the')
  // characters at a time in Chinese
  const zh = '我们周六去吉卜力美术馆吧'
  const zs = segmentsOf(zh)
  assert.equal(zh.slice(...Object.values(dragEdge(zh, zs, zh.indexOf('吉'), zh.indexOf('力')))), '吉卜力')
  assert.equal(zh.slice(...Object.values(dragEdge(zh, zs, zh.indexOf('馆') + 1, zh.indexOf('美')))), '美术馆')
})
