// Time in a conversation (public/js/ui/chat-time.js): marks after five
// minutes of quiet whoever speaks, a new one every day, the day named only
// on a day's first mark; real time across daylight saving; 12/24-hour clocks;
// the status under your latest message. The conversation itself is checked
// in a browser (tools/e2e/chat-time.cjs).
process.env.TZ = 'America/New_York' // a zone with daylight saving, before any Date is made
import test from 'node:test'
import assert from 'node:assert/strict'
import { GAP, marksBefore, opensDay, markText, markDay, historyDate, fullTime, briefly, statusText, clock, daysAgo, uses12h } from '../public/js/ui/chat-time.js'

const at = (y, mo, d, h = 0, mi = 0) => new Date(y, mo - 1, d, h, mi).getTime()
const NOW = at(2026, 11, 7, 12, 0) // Saturday, November 7, 2026
const msg = (ts, from = 'a') => ({ ts, from })

test('a new mark after five minutes of quiet, whoever speaks next', () => {
  const t0 = at(2026, 11, 7, 9, 41)
  const chat = [msg(t0, 'me'), msg(t0 + 60e3, 'friend'), msg(t0 + 2 * 60e3, 'me'), msg(t0 + 3 * 60e3, 'friend')]
  const marks = chat.map((m, i) => marksBefore(chat[i - 1], m))
  assert.deepEqual(marks, [true, false, false, false], 'one mark for a conversation that keeps going, though the sender keeps changing')
  assert.equal(marksBefore(msg(t0), msg(t0 + GAP - 1)), false, '4:59 later: the same stretch')
  assert.equal(marksBefore(msg(t0), msg(t0 + GAP)), true, 'five minutes: a new one')
  // a friend at 09:41, your reply at 09:52: a mark before the reply
  assert.equal(marksBefore(msg(t0, 'friend'), msg(at(2026, 11, 7, 9, 52), 'me')), true)
})

test('midnight always starts a new day, even mid-conversation', () => {
  const a = msg(at(2026, 11, 6, 23, 58)), b = msg(at(2026, 11, 7, 0, 1))
  assert.equal(marksBefore(a, b), true)
  assert.equal(opensDay(a, b), true)
  assert.equal(opensDay(msg(at(2026, 11, 7, 9, 41)), msg(at(2026, 11, 7, 10, 26))), false)
  assert.equal(opensDay(null, b), true, 'the first message shown opens its day')
})

test("a day's first mark names the day; the rest give the time", () => {
  assert.equal(markText(at(2026, 11, 7, 9, 41), { now: NOW }).text, 'Today 09:41')
  assert.equal(markText(at(2026, 11, 7, 10, 26), { now: NOW, opens: false }).text, '10:26')
  assert.equal(markText(at(2026, 11, 6, 21, 30), { now: NOW }).text, 'Yesterday 21:30')
  assert.equal(markText(at(2026, 11, 3, 8, 5), { now: NOW }).text, 'Tuesday 08:05', 'this week: the weekday')
  assert.equal(markText(at(2026, 10, 24, 9, 41), { now: NOW }).text, 'Sat, Oct 24 at 09:41', 'older: the date')
  assert.equal(markText(at(2025, 12, 31, 23, 0), { now: NOW }).text, 'Dec 31, 2025 at 23:00', 'another year: the year')
  assert.equal(markDay(at(2026, 11, 7, 0, 0), NOW), 'Today')
})

test('the clock: 24-hour, or 12-hour, by choice or the device', () => {
  const ts = at(2026, 11, 7, 9, 41)
  assert.equal(clock(ts), '09:41')
  assert.equal(clock(ts, true), '9:41 AM')
  assert.equal(clock(at(2026, 11, 7, 0, 5), true), '12:05 AM')
  assert.equal(clock(at(2026, 11, 7, 12, 0), true), '12:00 PM')
  assert.equal(clock(at(2026, 11, 7, 13, 7), true), '1:07 PM')
  assert.equal(markText(ts, { now: NOW, h12: true }).text, 'Today 9:41 AM')
  assert.equal(uses12h('12'), true)
  assert.equal(uses12h('24'), false)
  assert.equal(typeof uses12h('system'), 'boolean')
})

test('daylight saving: gaps are real time, days are calendar days', () => {
  // Spring forward (Mar 8, 2026): 01:58 EST and 03:01 EDT are 3 real minutes apart.
  const before = at(2026, 3, 8, 1, 58), after = at(2026, 3, 8, 3, 1)
  assert.equal(after - before, 3 * 60e3)
  assert.equal(marksBefore(msg(before), msg(after)), false, 'the clock jumped an hour, the conversation did not pause')
  // Fall back (Nov 1, 2026): 01:30 EDT, then 01:10 EST — 40 real minutes later.
  const edt = new Date('2026-11-01T01:30:00-04:00').getTime(), est = new Date('2026-11-01T01:10:00-05:00').getTime()
  assert.equal(est - edt, 40 * 60e3)
  assert.equal(marksBefore(msg(edt), msg(est)), true, '40 minutes passed, though the clock reads earlier')
  const edt2 = new Date('2026-11-01T01:58:00-04:00').getTime(), est2 = new Date('2026-11-01T01:01:00-05:00').getTime()
  assert.equal(marksBefore(msg(edt2), msg(est2)), false, '3 real minutes, though the clock went back 57')
  assert.equal(daysAgo(at(2026, 3, 7, 23, 0), at(2026, 3, 8, 23, 0)), 1, 'a 23-hour day is still one day')
  assert.equal(daysAgo(at(2026, 10, 31, 1, 0), at(2026, 11, 1, 23, 59)), 1, 'a 25-hour day is still one day')
})

test('the floating date, the menu time, and brief times', () => {
  assert.equal(historyDate(at(2026, 11, 7, 8), NOW), 'Today')
  assert.equal(historyDate(at(2026, 11, 6, 8), NOW), 'Yesterday')
  assert.equal(historyDate(at(2026, 11, 5, 8), NOW), 'Thursday, November 5')
  assert.equal(historyDate(at(2025, 11, 5, 8), NOW), 'Wednesday, November 5, 2025')
  assert.equal(fullTime(at(2026, 11, 7, 9, 41), { now: NOW }), 'Today at 09:41')
  assert.equal(fullTime(at(2026, 11, 5, 9, 41), { now: NOW }), 'Thursday, November 5 at 09:41')
  assert.equal(briefly(at(2026, 11, 7, 10, 32), { now: NOW }), '10:32')
  assert.equal(briefly(at(2026, 11, 6, 10, 32), { now: NOW }), 'Yesterday')
  assert.equal(briefly(at(2026, 10, 5, 10, 32), { now: NOW }), 'Oct 5')
})

test('the status under your latest message', () => {
  const readAt = at(2026, 11, 7, 10, 28)
  assert.equal(statusText('sending'), 'Sending…')
  assert.equal(statusText('sent'), 'Sent')
  assert.equal(statusText('delivered'), 'Delivered')
  assert.equal(statusText('read', { readAt, now: NOW }), 'Read 10:28')
  assert.equal(statusText('read', { readAt, now: NOW, h12: true }), 'Read 10:28 AM')
  assert.equal(statusText('read', { readAt: at(2026, 11, 6, 22), now: NOW }), 'Read Yesterday')
  assert.equal(statusText('read', { now: NOW }), 'Read', 'when the time is not known')
  assert.equal(statusText('failed'), 'Not sent')
  assert.equal(statusText(undefined), '')
})
