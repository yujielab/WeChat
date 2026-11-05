// What the writing help remembers, and the way to forget it — the parts of
// it that are only about the memory, kept apart from the sheet that shows it
// so they can be read and tested on their own.
//
// The prediction keeps three things: how this person writes (the words they
// reach for, across conversations), what each conversation was about before
// it scrolled out of view, and their routine and habits (when they are up,
// how they answer). All are built from their own use, and all belong to the
// one they were made of.
//
// This is where that is shown, so it is never a surprise: what is
// remembered, when it was last read, and a way to clear it all.

/** How many words and endings are shown. */
export const SHOWN = 24

/** What the memory is worth, said in words rather than a number. */
const CONFIDENCE = {
  none: '还太少',
  low: '刚开始记住',
  medium: '已经记得一些',
  high: '已经熟悉'
}

/** How much of it there is, in words. */
export const confidenceLabel = level => CONFIDENCE[level] || CONFIDENCE.none

/** A date as it reads: how long ago, or the day it was. */
export function when(ts, now = Date.now()) {
  if (!ts) return ''
  const diff = now - ts
  const day = 24 * 3600 * 1000
  if (diff < 60 * 1000) return '刚刚'
  if (diff < 3600 * 1000) return `${Math.floor(diff / 60000)} 分钟前`
  if (diff < day) return `${Math.floor(diff / 3600000)} 小时前`
  if (diff < 30 * day) return `${Math.floor(diff / day)} 天前`
  return new Date(ts).toLocaleDateString('zh-CN')
}

/** Nothing remembered — which is not an error, just nothing yet. */
export const emptyMemory = () => ({
  style: { words: [], endings: [], messages: 0, at: 0 },
  confidence: 'none',
  digests: [],
  routine: emptyRoutine()
})

// ---------------------------------------------------------------- routine and habits
// When this person is usually up and about, and how they use the app
// (src/routine.js): counted from their own use only, shown here in words.

/** A routine nobody has seen yet: learning on, nothing known. */
export const emptyRoutine = () => ({
  learning: true, days: 0, confidence: 'none', wake: null, sleep: null, weekday: null, weekend: null,
  hours: Array.from({ length: 24 }, () => 0), peak: null, quiet: null, reply: null, length: null,
  kinds: [], emoji: [], peers: []
})

const ROUTINE_CONFIDENCE = { none: '还在了解你', low: '刚开始了解', medium: '已经了解一些', high: '已经熟悉' }
export const routineConfidenceLabel = level => ROUTINE_CONFIDENCE[level] || ROUTINE_CONFIDENCE.none

const minute = v => (Number.isFinite(v) && v >= 0 && v < 1440 ? Math.round(v) : null)
const hourPair = v => (Array.isArray(v) && v.length === 2 && v.every(x => Number.isInteger(x) && x >= 0 && x < 24) ? [v[0], v[1]] : null)
const span = v => (v && minute(v.wake) !== null && minute(v.sleep) !== null ? { wake: minute(v.wake), sleep: minute(v.sleep) } : null)

/** The routine as the server sent it; anything odd is read as not known. */
export function routineOf(memory) {
  const r = memory?.routine
  const base = emptyRoutine()
  if (!r || typeof r !== 'object') return base
  return {
    learning: r.learning !== false,
    days: Number.isFinite(r.days) && r.days > 0 ? Math.floor(r.days) : 0,
    confidence: ROUTINE_CONFIDENCE[r.confidence] ? r.confidence : 'none',
    wake: minute(r.wake),
    sleep: minute(r.sleep),
    weekday: span(r.weekday),
    weekend: span(r.weekend),
    hours: Array.isArray(r.hours) && r.hours.length === 24 ? r.hours.map(x => (Number.isFinite(x) ? Math.max(0, Math.min(1, x)) : 0)) : base.hours,
    peak: hourPair(r.peak),
    quiet: hourPair(r.quiet),
    reply: Number.isFinite(r.reply) && r.reply >= 0 ? r.reply : null,
    length: Number.isFinite(r.length) && r.length > 0 ? Math.round(r.length) : null,
    kinds: Array.isArray(r.kinds) ? r.kinds.filter(k => k && typeof k.kind === 'string' && Number.isFinite(k.share)) : [],
    emoji: Array.isArray(r.emoji) ? r.emoji.filter(e => typeof e === 'string' && e).slice(0, 5) : [],
    peers: Array.isArray(r.peers) ? r.peers.filter(p => p && BAND[p.band] && typeof p.name === 'string' && p.name) : []
  }
}

/** "7:40" */
export function clock(m) {
  const v = ((Math.round(m) % 1440) + 1440) % 1440
  return `${Math.floor(v / 60)}:${String(v % 60).padStart(2, '0')}`
}

/** "21–24 点" */
export const hoursText = ([a, b]) => `${a}–${b === 0 ? 24 : b} 点`

/** How soon someone usually answers, in words. */
export function replyText(seconds) {
  if (seconds < 60) return '通常 1 分钟内'
  if (seconds < 3600) return `通常约 ${Math.round(seconds / 60)} 分钟`
  return `通常约 ${Math.round(seconds / 3600)} 小时`
}

/** How long their messages usually are, in words. */
export function lengthText(n) {
  if (n <= 8) return `多是短句，大约 ${n} 个字`
  if (n <= 30) return `一般 ${n} 个字左右`
  return `常写长段，大约 ${n} 个字`
}

const KIND = { text: '文字', sticker: '表情', image: '图片', drawing: '手绘', voice: '语音', video: '视频', file: '文件' }
/** "文字 82% · 表情 10%" */
export const kindsText = kinds => kinds.map(k => `${KIND[k.kind] || k.kind} ${k.share}%`).join(' · ')

const BAND = { morning: '早上', afternoon: '下午', evening: '晚上', night: '深夜' }
/** "早上常和 小红 · 晚上常和 小明" */
export const peersText = peers => peers.map(p => `${BAND[p.band]}常和 ${p.name}`).join(' · ')

/** When they are usually up, said once — or for weekdays and weekends apart, when those differ. */
export function sleepText(r) {
  if (r.weekday && r.weekend) {
    return `工作日 ${clock(r.weekday.wake)} 起来、${clock(r.weekday.sleep)} 睡；周末 ${clock(r.weekend.wake)} 起来、${clock(r.weekend.sleep)} 睡`
  }
  if (r.wake !== null && r.sleep !== null) return `通常 ${clock(r.wake)} 起来、${clock(r.sleep)} 睡`
  return ''
}

/** Whether an hour lies in a span of hours [from, to), which may run past midnight. */
export function inHours(hour, [from, to]) {
  return from <= to ? hour >= from && hour < to : hour >= from || hour < to
}

/**
 * The memory as the sheet shows it: what is kept, and how much of it there
 * is. A server that says nothing, or says something odd, is read as an
 * empty memory rather than as an error.
 */
export function summarize(memory) {
  const style = memory?.style || {}
  const words = Array.isArray(style.words) ? style.words.filter(w => typeof w === 'string') : []
  const endings = Array.isArray(style.endings) ? style.endings.filter(e => typeof e === 'string') : []
  const digests = Array.isArray(memory?.digests)
    ? memory.digests.filter(d => d && typeof d.text === 'string' && d.text).map(d => ({ room: String(d.room || ''), text: d.text, at: d.at || 0 }))
    : []
  const messages = Number(style.messages) || 0
  const routine = routineOf(memory)
  return {
    words: words.slice(0, SHOWN),
    endings: endings.slice(0, SHOWN),
    digests,
    messages,
    confidence: memory?.confidence || 'none',
    routine,
    empty: !messages && !digests.length && !routine.days
  }
}
