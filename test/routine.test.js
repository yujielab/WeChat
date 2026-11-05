// The routine and habits (src/routine.js): what a person's own use says about when they are up and how they
// use the app, counted, faded over time, and read back in words.
import test from 'node:test'
import assert from 'node:assert/strict'
import {
  emptyRoutine, record, summarizeRoutine, routineText, setLearning, localParts, emojiIn, clampTz, clock, median,
  HALF_LIFE, SLOT, bandOf, routineConfidence, readable
} from '../src/routine.js'
import { contextText } from '../src/assist.js'

const MIN = 60 * 1000
const HOUR = 60 * MIN
const DAY = 24 * HOUR
const TZ = -480 // UTC+8, as Date#getTimezoneOffset reports it
// A moment on the person's own clock: day n (2026-11-02 is a Monday), hh:mm local.
const at = (n, hh, mm = 0) => Date.UTC(2026, 10, 2 + n, hh, mm) + TZ * MIN

/** Days of a steady routine: up at `wake`, a few messages through the day, last seen at `sleep` (past midnight is the same day). */
function live(days, { wake = [7, 40], sleep = [24, 30], start = 0, weekend } = {}) {
  let r = emptyRoutine()
  for (let d = start; d < start + days; d++) {
    const weekday = new Date(Date.UTC(2026, 10, 2 + d)).getUTCDay()
    const [w, s] = (weekday === 0 || weekday === 6) && weekend ? [weekend.wake, weekend.sleep] : [wake, sleep]
    r = record(r, { kind: 'open', tz: TZ }, at(d, ...w))
    r = record(r, { kind: 'text', room: 'r-amy', text: '早', tz: TZ }, at(d, w[0], w[1] + 5))
    for (const hh of [10, 13, 15, 18]) r = record(r, { kind: 'read', tz: TZ }, at(d, hh))
    r = record(r, { kind: 'text', room: 'r-ben', text: '晚上吃什么😂', latency: 90 * 1000, tz: TZ }, at(d, 21, 10))
    r = record(r, { kind: 'sticker', room: 'r-ben', emoji: '👍', tz: TZ }, at(d, 21, 40))
    r = record(r, { kind: 'text', room: 'r-ben', text: '好的👍', latency: 30 * 1000, tz: TZ }, at(d, 22, 15))
    r = record(r, { kind: 'read', tz: TZ }, at(d, ...s))
  }
  return r
}

test('a moment is placed in the person\'s own day, which runs from 04:00 to 04:00', () => {
  const late = localParts(at(0, 23, 50), TZ)
  assert.equal(late.hour, 23); assert.equal(late.day, '2026-11-02')
  const pastMidnight = localParts(at(0, 24 + 1, 20), TZ)
  assert.equal(pastMidnight.hour, 1); assert.equal(pastMidnight.day, '2026-11-02', '01:20 still belongs to the evening before')
  assert.equal(pastMidnight.sinceStart, 21 * 60 + 20)
  assert.equal(localParts(at(1, 4, 0), TZ).day, '2026-11-03', 'a new day at 04:00')
  assert.equal(localParts(at(5, 10), TZ).weekend, true, 'Saturday')
  assert.equal(localParts(at(0, 10), TZ).weekend, false)
})

test('time zones as devices report them, and nothing else', () => {
  assert.equal(clampTz('-480'), -480); assert.equal(clampTz(300), 300); assert.equal(clampTz(0), 0)
  for (const odd of [null, undefined, '', 'x', 10000, NaN]) assert.equal(clampTz(odd), null, String(odd))
})

test('being active is counted once a quarter hour: a burst is one busy quarter hour', () => {
  let r = emptyRoutine()
  for (let i = 0; i < 20; i++) r = record(r, { kind: 'text', room: 'a', text: 'x', tz: TZ }, at(0, 9, 0) + i * 20 * 1000)
  assert.equal(r.slots, 1)
  assert.equal(r.hours.wd[9], 1)
  assert.equal(Math.round(r.kinds.text), 20, 'every message still counts as sent')
  r = record(r, { kind: 'read' }, at(0, 9, 0) + SLOT)
  assert.equal(r.slots, 2)
})

test('a steady routine is read back: up at 7:40, asleep at 0:30, busiest in the evening, quiet at night', () => {
  const r = live(14)
  const s = summarizeRoutine(r, at(14, 12))
  assert.equal(s.days, 14)
  assert.equal(s.confidence, 'high')
  assert.equal(clock(s.wake), '7:40')
  assert.equal(clock(s.sleep), '0:30')
  assert.deepEqual(s.peak, [20, 23], 'the busiest three hours hold 21:10, 21:40 and 22:15')
  assert.ok(s.quiet && s.quiet[0] >= 1 && s.quiet[1] <= 7, 'a quiet stretch in the small hours ' + JSON.stringify(s.quiet))
  assert.equal(s.hours.length, 24); assert.equal(Math.max(...s.hours), 1)
  assert.equal(s.weekday, null, 'weekdays and weekends alike: said once')
})

test('weekdays and weekends are told apart when they differ', () => {
  const r = live(21, { weekend: { wake: [9, 30], sleep: [25, 40] } })
  const s = summarizeRoutine(r, at(21, 12))
  assert.ok(s.weekday && s.weekend)
  assert.equal(clock(s.weekday.wake), '7:40'); assert.equal(clock(s.weekend.wake), '9:30')
  assert.equal(clock(s.weekend.sleep), '1:40')
})

test('habits: how soon and how briefly they answer, what they send, which emoji, who at what time of day', () => {
  const s = summarizeRoutine(live(6), at(6, 12))
  assert.equal(s.reply, 60, 'the middle of 90s and 30s answers')
  assert.equal(s.length, 3, 'the middle of 1, 6 and 3 characters a day')
  assert.deepEqual(s.kinds.map(k => k.kind), ['text', 'sticker'])
  assert.equal(s.kinds[0].share, 75)
  assert.deepEqual(s.emoji.slice(0, 2), ['👍', '😂'])
  assert.deepEqual(s.peers, [{ band: 'morning', room: 'r-amy' }, { band: 'evening', room: 'r-ben' }])
})

test('what they wrote is not kept: only its length and the emoji in it', () => {
  const r = record(emptyRoutine(), { kind: 'text', room: 'a', text: '我的银行卡密码是 1234 😅', tz: TZ }, at(0, 10))
  const kept = JSON.stringify(r)
  assert.ok(!kept.includes('密码') && !kept.includes('1234'), kept)
  assert.deepEqual(r.len, [15]); assert.deepEqual(Object.keys(r.emoji), ['😅'])
})

test('emoji are read whole', () => {
  assert.deepEqual(emojiIn('好👍🏻 一起👨‍👩‍👧 🇨🇳 a'), ['👍🏻', '👨‍👩‍👧', '🇨🇳'])
  assert.deepEqual(emojiIn('没有'), [])
})

test('long-term, not forever: counts fade with a half-life, so a changed routine takes over', () => {
  let r = live(10)
  const before = r.hours.wd[21]
  r = record(r, { kind: 'read', tz: TZ }, at(10, 12) + HALF_LIFE)
  assert.ok(Math.abs(r.hours.wd[21] - before / 2) < 0.2, `halved after a half-life: ${before} → ${r.hours.wd[21]}`)
  // Two months later, a new routine: up at 6:00, asleep at 22:30.
  const later = live(14, { wake: [6, 0], sleep: [22, 30], start: 70 })
  const old = live(30)
  let merged = old
  for (const day of later.days) merged.days.push(day)
  const s = summarizeRoutine(merged, at(84, 12))
  assert.equal(clock(s.wake), '6:00', 'only the last month is read for the day\'s shape')
})

test('a few minutes, or a single day, say nothing about waking or sleeping', () => {
  // Two days of a few minutes each in the evening: not a day of use.
  let brief = emptyRoutine()
  for (const d of [0, 1]) for (const m of [0, 5, 10]) brief = record(brief, { kind: 'text', room: 'a', text: '在', tz: TZ }, at(d, 18, 30 + m))
  let b = summarizeRoutine(brief, at(1, 20))
  assert.equal(b.wake, null); assert.equal(b.sleep, null)
  // One real day: still not "usually".
  b = summarizeRoutine(live(1), at(1, 12))
  assert.equal(b.wake, null, 'one day is not a routine')
  assert.notEqual(summarizeRoutine(live(2), at(2, 12)).wake, null, 'two are')
})

test('a day with a single moment says nothing about waking or sleeping; a thin record says little', () => {
  let r = record(emptyRoutine(), { kind: 'open', tz: TZ }, at(0, 12))
  let s = summarizeRoutine(r, at(0, 13))
  assert.equal(s.wake, null); assert.equal(s.sleep, null); assert.equal(s.confidence, 'none')
  assert.equal(s.peak, null, 'no busiest hours from one moment')
  assert.equal(routineText(s, at(0, 13)), '', 'and the writing help hears nothing of it')
  assert.equal(routineConfidence(2), 'low'); assert.equal(routineConfidence(5), 'medium'); assert.equal(routineConfidence(14), 'high')
})

test('the writing help reads a line or two: the time for the writer, their usual day, how they answer', () => {
  const s = summarizeRoutine(live(7), at(7, 12))
  const text = routineText(s, at(7, 23, 50))
  assert.match(text, /^现在是我这边的 23:50；我一般 7:40 起来、0:30 睡。/)
  assert.match(text, /我回消息一般很短，大约 3 个字。/)
  assert.match(text, /我常用的表情：👍 😂/)
  // …last in the prompt, after the conversation, its digest and the style.
  const ctx = contextText('对方：在吗', '约了周五', '我常用的词：好的', text)
  assert.ok(ctx.indexOf('聊天记录') < ctx.indexOf('早前') && ctx.indexOf('早前') < ctx.indexOf('用词') && ctx.indexOf('用词') < ctx.indexOf('我的作息和习惯'))
  assert.equal(contextText('对方：在吗'), '聊天记录：\n对方：在吗', 'nothing added without it')
})

test('switched off, nothing is learned and what was learned is gone; on again starts fresh', () => {
  const off = setLearning(live(5), false)
  assert.equal(off.off, true); assert.equal(off.slots, 0); assert.deepEqual(off.days, [])
  const after = record(off, { kind: 'text', room: 'a', text: '在吗', tz: TZ }, at(6, 10))
  assert.equal(after.slots, 0); assert.deepEqual(after.kinds, {})
  assert.equal(summarizeRoutine(after).learning, false)
  assert.equal(routineText({ ...summarizeRoutine(live(5), at(5, 12)), learning: false }), '')
  const on = setLearning(after, true)
  assert.equal(on.off, false)
  assert.equal(record(on, { kind: 'open', tz: TZ }, at(7, 9)).slots, 1)
})

test('what is kept stays small, and an odd stored record is read as a fresh one', () => {
  let r = emptyRoutine()
  for (let i = 0; i < 400; i++) r = record(r, { kind: 'text', room: `room-${i}`, text: `${i}😀`, latency: 5000, tz: TZ }, at(Math.floor(i / 4), 8 + (i % 4)))
  assert.ok(r.days.length <= 60 && r.reply.length <= 60 && r.len.length <= 100 && Object.keys(r.peers).length <= 30 && Object.keys(r.emoji).length <= 24)
  assert.ok(JSON.stringify(r).length < 8000, 'a few kilobytes: ' + JSON.stringify(r).length)
  for (const odd of [null, {}, { v: 2 }, { v: 1, hours: 'x', days: 'y' }]) {
    const fresh = readable(odd)
    assert.equal(fresh.v, 1); assert.equal(fresh.hours.wd.length, 24); assert.deepEqual(fresh.days, [])
  }
})

test('small helpers', () => {
  assert.equal(median([3, 1, 2]), 2); assert.equal(median([1, 2, 3, 4]), 2.5); assert.equal(median([]), null)
  assert.equal(clock(0), '0:00'); assert.equal(clock(7 * 60 + 5), '7:05'); assert.equal(clock(1440 + 30), '0:30')
  assert.deepEqual([4, 5, 11, 16, 17, 22, 23, 0].map(bandOf), [3, 0, 1, 1, 2, 2, 3, 3])
})
