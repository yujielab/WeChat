// Time in a conversation (views/thread.js): three things, each in its place,
// all from the same timestamps.
//
//   - a mark in the middle of the conversation says when a stretch of it
//     happened: a new one after five minutes of quiet, whoever speaks next,
//     and always when the day changes. A day's first mark names the day
//     ("Today 09:41"); the rest give just the time ("10:26").
//   - each message's own time, when you ask for it (swipe left, hover, the
//     menu), or always, if you choose.
//   - under your latest message, where it stands: Sending, Delivered,
//     Read 10:28.
//
// Gaps are measured in real milliseconds, never by subtracting clock times,
// so a change of daylight saving can't split or join a stretch; days are
// the local calendar's, so the marks follow the device's time zone.

const WEEK = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']
const pad = n => String(n).padStart(2, '0')

/** Five minutes of quiet start a new stretch. */
export const GAP = 5 * 60 * 1000

/** Whole local days from `ts`'s day to `now`'s (0 today, 1 yesterday). */
export function daysAgo(ts, now = Date.now()) {
  const a = new Date(ts), b = new Date(now)
  return Math.round((Date.UTC(b.getFullYear(), b.getMonth(), b.getDate()) - Date.UTC(a.getFullYear(), a.getMonth(), a.getDate())) / 86400000)
}
export const sameDay = (a, b) => daysAgo(a, b) === 0

/** Does a mark stand before `m`, coming after `prev`? Five minutes apart, or another day. */
export function marksBefore(prev, m) {
  if (!prev) return true
  return m.ts - prev.ts >= GAP || !sameDay(prev.ts, m.ts)
}

/** Is a mark before `m` the first of its day (so it names the day)? */
export const opensDay = (prev, m) => !prev || !sameDay(prev.ts, m.ts)

// ---------------------------------------------------------------- the clock

/** 12-hour clock? 'system' asks the device (its locale and its own setting). */
export function uses12h(format = 'system') {
  if (format === '12') return true
  if (format === '24') return false
  try {
    const o = new Intl.DateTimeFormat(undefined, { hour: 'numeric' }).resolvedOptions()
    return o.hourCycle ? o.hourCycle === 'h12' || o.hourCycle === 'h11' : Boolean(o.hour12)
  } catch {
    return false
  }
}

/** 09:41, or 9:41 AM. */
export function clock(ts, h12 = false) {
  const d = new Date(ts)
  const h = d.getHours(), m = pad(d.getMinutes())
  return h12 ? `${h % 12 || 12}:${m} ${h < 12 ? 'AM' : 'PM'}` : `${pad(h)}:${m}`
}

// ---------------------------------------------------------------- days

const short = d => `${WEEK[d.getDay()].slice(0, 3)}, ${MONTHS[d.getMonth()].slice(0, 3)} ${d.getDate()}`

/** A mark's day: Today · Yesterday · Thursday (this week) · Sat, Nov 7 · Nov 7, 2025. */
export function markDay(ts, now = Date.now()) {
  const d = new Date(ts)
  const n = daysAgo(ts, now)
  if (n <= 0) return 'Today'
  if (n === 1) return 'Yesterday'
  if (n < 7) return WEEK[d.getDay()]
  if (d.getFullYear() === new Date(now).getFullYear()) return short(d)
  return `${MONTHS[d.getMonth()].slice(0, 3)} ${d.getDate()}, ${d.getFullYear()}`
}

/**
 * A mark's words: the day and time for a day's first ("Today 09:41",
 * "Sat, Nov 7 at 09:41"), the time alone for the rest ("10:26").
 */
export function markText(ts, { opens = true, now = Date.now(), h12 = false } = {}) {
  const time = clock(ts, h12)
  if (!opens) return { day: '', time, text: time }
  const day = markDay(ts, now)
  const dated = daysAgo(ts, now) >= 7
  return { day, time, text: dated ? `${day} at ${time}` : `${day} ${time}` }
}

/** The day, written out, for the date that floats while you scroll back. */
export function historyDate(ts, now = Date.now()) {
  const d = new Date(ts)
  const n = daysAgo(ts, now)
  if (n <= 0) return 'Today'
  if (n === 1) return 'Yesterday'
  const day = `${WEEK[d.getDay()]}, ${MONTHS[d.getMonth()]} ${d.getDate()}`
  return d.getFullYear() === new Date(now).getFullYear() ? day : `${day}, ${d.getFullYear()}`
}

/** When a message was sent, in full, for the top of its menu. */
export function fullTime(ts, { now = Date.now(), h12 = false } = {}) {
  const n = daysAgo(ts, now)
  const time = clock(ts, h12)
  if (n <= 0) return `Today at ${time}`
  if (n === 1) return `Yesterday at ${time}`
  return `${historyDate(ts, now)} at ${time}`
}

/** A time said briefly after a word ("Read 10:28", "Edited Yesterday", "Read Nov 5"). */
export function briefly(ts, { now = Date.now(), h12 = false } = {}) {
  const n = daysAgo(ts, now)
  if (n <= 0) return clock(ts, h12)
  if (n === 1) return 'Yesterday'
  if (n < 7) return WEEK[new Date(ts).getDay()]
  const d = new Date(ts)
  return d.getFullYear() === new Date(now).getFullYear() ? `${MONTHS[d.getMonth()].slice(0, 3)} ${d.getDate()}` : `${d.getMonth() + 1}/${d.getDate()}/${String(d.getFullYear()).slice(2)}`
}

// ---------------------------------------------------------------- where it stands

/**
 * The line under your latest message, from its state (format.js sendState):
 * Sending… · Sent · Delivered · Read 10:28 (Read, when the time isn't known) ·
 * Not sent.
 */
export function statusText(state, { readAt = 0, now = Date.now(), h12 = false } = {}) {
  switch (state) {
    case 'sending': return 'Sending…'
    case 'failed': return 'Not sent'
    case 'read': return readAt ? `Read ${briefly(readAt, { now, h12 })}` : 'Read'
    case 'delivered': return 'Delivered'
    case 'sent': return 'Sent'
    default: return ''
  }
}
