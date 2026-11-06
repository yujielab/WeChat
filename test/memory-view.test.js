import { test } from 'node:test'
import assert from 'node:assert/strict'
import { emptyMemory, summarize, confidenceLabel, when, SHOWN } from '../public/js/views/memory-model.js'

test('nothing remembered is not an error', () => {
  const empty = emptyMemory()
  assert.deepEqual(empty.style.words, [])
  assert.equal(empty.confidence, 'none')
  assert.deepEqual(empty.digests, [])
  assert.equal(summarize(empty).empty, true)
})

test('what is remembered is read into what the sheet shows', () => {
  const s = summarize({
    style: { words: ['材料', '电脑'], endings: ['明天见'], messages: 42, at: 1 },
    confidence: 'medium',
    digests: [{ room: 'r1', text: '约好明天开会', at: 2 }]
  })
  assert.deepEqual(s.words, ['材料', '电脑'])
  assert.deepEqual(s.endings, ['明天见'])
  assert.equal(s.messages, 42)
  assert.equal(s.confidence, 'medium')
  assert.equal(s.empty, false)
  assert.equal(s.digests.length, 1)
})

test('a server that says nothing odd is read as an empty memory', () => {
  for (const odd of [null, undefined, {}, { style: null }, { style: { words: '材料' } }, { digests: 'x' }]) {
    const s = summarize(odd)
    assert.equal(s.empty, true, `read as empty: ${JSON.stringify(odd)}`)
    assert.deepEqual(s.words, [])
    assert.deepEqual(s.digests, [])
  }
})

test('only what is worth showing is shown', () => {
  const many = Array.from({ length: SHOWN + 10 }, (_, i) => `词${i}`)
  const s = summarize({ style: { words: many, endings: many, messages: 100 }, digests: [] })
  assert.equal(s.words.length, SHOWN)
  assert.equal(s.endings.length, SHOWN)
})

test('a digest without any text is not shown', () => {
  const s = summarize({ style: { messages: 1 }, digests: [{ room: 'r', text: '' }, { room: 'r2', text: '有的' }] })
  assert.equal(s.digests.length, 1)
  assert.equal(s.digests[0].text, '有的')
})

test('how much of it there is, said in words', () => {
  assert.equal(confidenceLabel('none'), 'Still too little')
  assert.equal(confidenceLabel('low'), 'Starting to remember')
  assert.equal(confidenceLabel('medium'), 'Remembers some')
  assert.equal(confidenceLabel('high'), 'Knows you well')
  assert.equal(confidenceLabel('something-else'), 'Still too little', 'an unknown level reads as too little')
  assert.equal(confidenceLabel(undefined), 'Still too little')
})

test('when it was last read reads as a moment ago, or a day', () => {
  const now = 1_700_000_000_000
  assert.equal(when(0, now), '')
  assert.equal(when(now - 30 * 1000, now), 'Just now')
  assert.equal(when(now - 5 * 60 * 1000, now), '5 min ago')
  assert.equal(when(now - 3 * 3600 * 1000, now), '3 hr ago')
  assert.equal(when(now - 5 * 24 * 3600 * 1000, now), '5 days ago')
  assert.notEqual(when(now - 90 * 24 * 3600 * 1000, now), '', 'an old day is still a day')
})
