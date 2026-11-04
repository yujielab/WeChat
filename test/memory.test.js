import { test } from 'node:test'
import assert from 'node:assert/strict'
import { DatabaseSync } from 'node:sqlite'
import { webcrypto } from 'node:crypto'
import { Store } from '../src/store.js'
import {
  words, endings, styleOf, styleText, mergeStyle, confidence,
  readStyle, writeStyle, readDigest, writeDigest, digestPrompt, readDigestAnswer
} from '../src/memory.js'

globalThis.crypto ??= webcrypto

function makeStore() {
  const db = new DatabaseSync(':memory:')
  return new Store((q, ...b) => db.prepare(q).all(...b).map(r => ({ ...r })))
}
const msgs = (...texts) => texts.map((text, i) => ({ ts: i + 1, text }))

test('the pieces of a text: Chinese in two-character pieces, Latin words whole', () => {
  // A sliding pair, so a word is found wherever it falls in the run.
  assert.deepEqual(words('我们明天'), ['我们', '们明', '明天'])
  assert.deepEqual(words('see you tomorrow'), ['see', 'tomorrow'])
  assert.ok(!words('我 你').includes('我'), 'function words are left out')
  assert.ok(!words('好的').includes('的'))
})

test('a style is counted from the messages a person sent', () => {
  const style = styleOf(msgs(
    '好的，我准备一下材料。',
    '那我们明天见。',
    '我先准备一下材料。',
    '开会的时候记得带电脑。'
  ))
  assert.ok(style.words.includes('材料'), 'a word that recurs is kept')
  assert.equal(style.messages, 4)
})

test('a piece that only shows up once is not a habit', () => {
  const style = styleOf(msgs('我想去西藏。', '好的。', '嗯。'))
  assert.ok(!style.words.includes('西藏'), 'one mention is an accident, not a habit')
})

test('a habit needs to show up in more than one message', () => {
  const style = styleOf(msgs(
    '明天开会带上电脑。',
    '好的，我带电脑。',
    '开会的时候记得带电脑。',
    '我先准备材料。'
  ))
  assert.ok(style.words.includes('电脑'), 'three messages is a habit')
})

test('a style needs more than a few messages to be trusted', () => {
  assert.equal(confidence({ messages: 0 }), 'none')
  assert.equal(confidence({ messages: 2 }), 'none', 'too thin to lean on')
  assert.equal(confidence({ messages: 5 }), 'low')
  assert.equal(confidence({ messages: 20 }), 'medium')
  assert.equal(confidence({ messages: 100 }), 'high')
})

test('a style too thin to trust is not read into the suggestion', () => {
  const store = makeStore()
  writeStyle(store, 'thin', { words: ['材料'], endings: [], messages: 2, at: Date.now(), counted: 0 })
  // The words are there, but the profile is not yet a voice.
  assert.equal(confidence(readStyle(store, 'thin')), 'none')
  assert.equal(styleText(readStyle(store, 'thin')).includes('材料'), true, 'the words are still kept')
})

test('how a person ends a message is kept, without the punctuation', () => {
  assert.ok(endings('明天见！').includes('明天见'))
  assert.ok(endings('我们明天开会吧').length >= 1, 'a message without punctuation still ends somewhere')
  assert.ok(!endings('好的。').some(e => e.includes('。')))
})

test('the style reads as a few lines for the model', () => {
  const style = styleOf(msgs('好的，我准备材料。', '那我们明天见。', '我准备一下材料。', '明天见！'))
  const text = styleText(style)
  assert.match(text, /我常用的词/)
  assert.ok(text.length < 300, 'a hint, not a document')
  assert.equal(styleText({ messages: 0 }), '')
})

test('styles merge: the counts add up, so a habit is judged over the whole history', () => {
  const a = styleOf(msgs('我把材料准备好了。', '材料我放桌上了。'))
  const b = styleOf(msgs('明天开会带电脑。', '电脑我带好了。'))
  const merged = mergeStyle(a, b)
  assert.ok(merged.words.includes('材料'), 'what the first batch said is kept')
  assert.ok(merged.words.includes('电脑'), 'and what the second said')
  assert.equal(merged.messages, 4)
  assert.equal(mergeStyle(null, b), b, 'no old style yet')
  assert.equal(mergeStyle(a, null), a, 'nothing new yet')
})

test('a small batch on its own says little, and does not throw the rest away', () => {
  const many = styleOf(msgs(
    '我把材料准备好了。', '材料我放桌上了。', '材料还在吗？', '材料我带来了。'
  ))
  assert.ok(many.words.includes('材料'), 'a habit is there')
  // One more message on its own would say nothing on its own — but merged,
  // it must not empty what was already known.
  const one = styleOf(msgs('嗯'))
  const merged = mergeStyle(many, one)
  assert.ok(merged.words.includes('材料'), 'a thin batch does not throw the style away')
  assert.equal(merged.messages, 5)
})

test('a stored style survives and is read back', () => {
  const store = makeStore()
  const style = styleOf(msgs('好的，我准备材料。', '那我们明天见。', '我准备一下材料。', '明天见！'))
  writeStyle(store, 'u1', style)
  const back = readStyle(store, 'u1')
  assert.ok(back.words.includes('材料'))
  assert.equal(back.messages, style.messages)
})

test('a stale style is not read back', () => {
  const store = makeStore()
  writeStyle(store, 'u1', { words: ['材料'], endings: [], messages: 10, at: Date.now() - 200 * 24 * 3600 * 1000 })
  assert.equal(readStyle(store, 'u1').messages, 0, 'a year-old profile is not read')
})

test("one person's style is not another's", () => {
  const store = makeStore()
  writeStyle(store, 'u1', { words: ['藏羚羊'], endings: [], messages: 9, at: Date.now() })
  writeStyle(store, 'u2', { words: ['会议'], endings: [], messages: 9, at: Date.now() })
  assert.deepEqual(readStyle(store, 'u1').words, ['藏羚羊'])
  assert.deepEqual(readStyle(store, 'u2').words, ['会议'])
})

test("a conversation's digest stays in that conversation", () => {
  const store = makeStore()
  writeDigest(store, 'u1', 'room-a', '聊了开会的事')
  writeDigest(store, 'u1', 'room-b', '聊了旅行的事')
  assert.equal(readDigest(store, 'u1', 'room-a').text, '聊了开会的事')
  assert.equal(readDigest(store, 'u1', 'room-b').text, '聊了旅行的事')
  assert.equal(readDigest(store, 'u2', 'room-a').text, '', 'another person does not see it')
})

test('the digest prompt asks for points, not guesses', () => {
  const p = digestPrompt('我：明天开会\n对方：好的')
  const said = p.map(m => m.content).join('\n')
  assert.match(said, /我：明天开会/)
  assert.match(said, /不要推测/)
})

test("the digest's answer is short lines, cleaned", () => {
  assert.equal(readDigestAnswer('- 约好明天开会\n2. 在会议室'), '约好明天开会\n在会议室')
  assert.equal(readDigestAnswer(''), '')
  assert.equal(readDigestAnswer('   \n  '), '')
})
