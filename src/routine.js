// Long-term memory of how a person lives with the app: their routine
// and their habits — when they are up and about and when they go
// quiet, which hours they are busiest, who they talk to at which time of
// day, how quickly and how briefly they answer, what they send and which
// emoji they reach for.
//
// Learned by counting, never by a model, and only from the person's own use:
// the messages they send, the app opened, conversations read. Nothing anyone
// else does is counted into it, and nothing is kept of what they wrote beyond
// its length and the emoji in it. It is theirs to see (the memory sheet) and
// theirs to clear or switch off; the writing help reads a line or two of it.
//
// Long-term, not forever: everything counted fades with a half-life of
// HALF_LIFE, so a routine that changed (a new job, another time zone) takes
// over within a few weeks, while one late night changes nothing.
//
// Times are the person's own. Their device reports its offset from UTC
// (Date#getTimezoneOffset), and each moment is placed in their local day. A
// day runs from 04:00 to 04:00, so staying up past midnight belongs to the
// evening it began in, and its last moment is when they went to sleep.

const MIN = 60 * 1000
const HOUR = 60 * MIN
const DAY = 24 * HOUR

export const HALF_LIFE = 45 * DAY
export const SLOT = 15 * MIN     // being active is counted once per quarter hour
export const DAY_START = 4 * 60  // minutes after midnight a day begins
const KEEP_DAYS = 60             // days whose first and last moments are kept
const RECENT_DAYS = 30           // the days a routine is read from
const KEEP_REPLY = 60            // reply times kept
const KEEP_LENGTH = 100          // message lengths kept
const KEEP_EMOJI = 24
const KEEP_PEERS = 30
const MAX_REPLY = 12 * HOUR      // longer than this isn't an answer, it's a new conversation
const MIN_DAY_SPAN = 4 * 60      // minutes a day of use spans before its start and end mean anything

/** What is counted as something the person sent, by kind of message. */
export const SENT = new Set(['text', 'image', 'voice', 'video', 'file', 'drawing', 'sticker'])
/** Times of day, for who they talk to when: 5–11, 11–17, 17–23, 23–5. */
export const BANDS = ['morning', 'afternoon', 'evening', 'night']
export const bandOf = hour => (hour >= 5 && hour < 11 ? 0 : hour >= 11 && hour < 17 ? 1 : hour >= 17 && hour < 23 ? 2 : 3)

export const routineKey = userId => `memory:routine:${userId}`

const zeros = () => Array.from({ length: 24 }, () => 0)

export const emptyRoutine = () => ({
  v: 1,
  tz: null,      // the device's offset, as Date#getTimezoneOffset
  at: 0,         // when the counts were last faded
  slot: -1,      // the last quarter hour counted as active
  slots: 0,      // quarter hours counted, all told
  hours: { wd: zeros(), we: zeros() }, // being active, by local hour, on weekdays and weekends
  days: [],      // [day, first, last, events]: minutes into the day (from 04:00)
  kinds: {},     // what was sent
  emoji: {},     // which emoji
  peers: {},     // room → [morning, afternoon, evening, night]
  reply: [],     // seconds taken to answer
  len: [],       // characters per text message
  off: false     // switched off: nothing is learned
})

/** An offset from UTC in minutes, as a device reports it, or null for anything else. */
export function clampTz(value) {
  if (value === null || value === undefined || value === '') return null
  const n = Math.round(Number(value))
  return Number.isFinite(n) && Math.abs(n) <= 840 ? n : null
}

/** Where a moment falls in the person's own day. tz: Date#getTimezoneOffset (minutes, west of UTC positive). */
export function localParts(ts, tz = 0) {
  const local = ts - (tz || 0) * MIN
  const clock = new Date(local)
  const minute = clock.getUTCHours() * 60 + clock.getUTCMinutes()
  // The day a moment belongs to begins at 04:00.
  const belongs = new Date(local - DAY_START * MIN)
  const weekday = belongs.getUTCDay()
  return {
    hour: clock.getUTCHours(),
    minute,
    sinceStart: (minute - DAY_START + 1440) % 1440,
    day: belongs.toISOString().slice(0, 10),
    weekend: weekday === 0 || weekday === 6,
    slot: Math.floor(local / SLOT)
  }
}

/** The emoji in a text, each as written (flags and families whole). */
export function emojiIn(text) {
  return String(text || '').match(/(?:\p{Regional_Indicator}{2}|\p{Extended_Pictographic}(?:️|\p{Emoji_Modifier})?(?:‍\p{Extended_Pictographic}(?:️|\p{Emoji_Modifier})?)*)/gu) || []
}

/** A copy that is safe to change: whatever was stored, in today's shape. */
export function readable(stored) {
  const r = emptyRoutine()
  if (!stored || stored.v !== 1) return r
  const nums = (a, n) => (Array.isArray(a) && a.length === n ? a.map(x => (Number.isFinite(x) ? x : 0)) : zeros())
  return {
    ...r,
    tz: clampTz(stored.tz),
    at: Number(stored.at) || 0,
    slot: Number.isFinite(stored.slot) ? stored.slot : -1,
    slots: Number(stored.slots) || 0,
    hours: { wd: nums(stored.hours?.wd, 24), we: nums(stored.hours?.we, 24) },
    days: Array.isArray(stored.days) ? stored.days.filter(d => Array.isArray(d) && d.length === 4).map(d => [...d]) : [],
    kinds: { ...(stored.kinds || {}) },
    emoji: { ...(stored.emoji || {}) },
    peers: Object.fromEntries(Object.entries(stored.peers || {}).map(([k, v]) => [k, Array.isArray(v) && v.length === 4 ? [...v] : [0, 0, 0, 0]])),
    reply: Array.isArray(stored.reply) ? stored.reply.filter(Number.isFinite) : [],
    len: Array.isArray(stored.len) ? stored.len.filter(Number.isFinite) : [],
    off: Boolean(stored.off)
  }
}

/** Fade every count by the time that passed since it was last faded. */
function fade(r, now) {
  if (r.at && now > r.at) {
    const k = 0.5 ** ((now - r.at) / HALF_LIFE)
    // Four decimals are plenty for a count, and keep what is stored small.
    const f = x => Math.round(x * k * 1e4) / 1e4
    for (const side of ['wd', 'we']) r.hours[side] = r.hours[side].map(f)
    for (const map of [r.kinds, r.emoji]) for (const key of Object.keys(map)) map[key] = f(map[key])
    for (const key of Object.keys(r.peers)) r.peers[key] = r.peers[key].map(f)
  }
  r.at = Math.max(r.at || 0, now)
}

const keepTop = (map, n) => Object.fromEntries(Object.entries(map).sort((a, b) => b[1] - a[1]).slice(0, n))
const sum = a => a.reduce((s, x) => s + x, 0)

/**
 * Count one moment of use. event: { kind: 'open' | 'read' | a message type,
 * room, text, emoji (a sticker's), latency (ms since the message answered),
 * tz }. Returns the routine, counted (or unchanged when learning is off).
 */
export function record(stored, event = {}, now = Date.now()) {
  const r = readable(stored)
  if (r.off) return r
  const tz = clampTz(event.tz)
  if (tz !== null) r.tz = tz
  const p = localParts(now, r.tz ?? 0)
  fade(r, now)

  // The day: when it began and ended.
  let day = r.days.at(-1)
  if (!day || day[0] !== p.day) {
    day = [p.day, p.sinceStart, p.sinceStart, 0]
    r.days.push(day)
    if (r.days.length > KEEP_DAYS) r.days = r.days.slice(-KEEP_DAYS)
  }
  day[1] = Math.min(day[1], p.sinceStart)
  day[2] = Math.max(day[2], p.sinceStart)
  day[3] += 1

  // Being active, once per quarter hour: fifty messages in five minutes are
  // one busy quarter hour, not fifty.
  if (p.slot !== r.slot) {
    r.slot = p.slot
    r.slots += 1
    r.hours[p.weekend ? 'we' : 'wd'][p.hour] += 1
  }

  if (SENT.has(event.kind)) {
    r.kinds[event.kind] = (r.kinds[event.kind] || 0) + 1
    if (event.room) {
      const room = String(event.room)
      const bands = r.peers[room] || [0, 0, 0, 0]
      bands[bandOf(p.hour)] += 1
      r.peers[room] = bands
      if (Object.keys(r.peers).length > KEEP_PEERS) {
        r.peers = Object.fromEntries(Object.entries(r.peers).sort((a, b) => sum(b[1]) - sum(a[1])).slice(0, KEEP_PEERS))
      }
    }
    const emoji = [...emojiIn(event.text), ...emojiIn(event.emoji)]
    for (const e of emoji) r.emoji[e] = (r.emoji[e] || 0) + 1
    if (emoji.length) r.emoji = keepTop(r.emoji, KEEP_EMOJI)
    if (event.kind === 'text' && typeof event.text === 'string') {
      // How long, not what: characters, emoji counted as one.
      const n = [...event.text.trim()].length
      if (n) r.len = [...r.len, n].slice(-KEEP_LENGTH)
    }
    if (Number.isFinite(event.latency) && event.latency >= 0 && event.latency < MAX_REPLY) {
      r.reply = [...r.reply, Math.round(event.latency / 1000)].slice(-KEEP_REPLY)
    }
  }
  return r
}

/** Learning switched on or off; switching it off forgets what was learned. */
export function setLearning(stored, on) {
  return on ? { ...readable(stored), off: false } : { ...emptyRoutine(), off: true }
}

export function median(list) {
  if (!list.length) return null
  const s = [...list].sort((a, b) => a - b)
  const m = s.length >> 1
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2
}

/** Minutes after midnight, on a five-minute grid. */
const onClock = sinceStart => (Math.round((DAY_START + sinceStart) / 5) * 5) % 1440

/** "7:40" */
export function clock(minute) {
  const m = ((Math.round(minute) % 1440) + 1440) % 1440
  return `${Math.floor(m / 60)}:${String(m % 60).padStart(2, '0')}`
}

const dayOfWeek = key => new Date(`${key}T00:00:00Z`).getUTCDay()
const isWeekend = key => [0, 6].includes(dayOfWeek(key))
const daysApart = (a, b) => Math.round((Date.parse(`${b}T00:00:00Z`) - Date.parse(`${a}T00:00:00Z`)) / DAY)

/** How well the routine is known, from how many days were seen. */
export function routineConfidence(days) {
  if (days >= 14) return 'high'
  if (days >= 5) return 'medium'
  if (days >= 2) return 'low'
  return 'none'
}

/**
 * What the counts say, in the terms the memory sheet and the writing help
 * use. Nothing here is a guess beyond the counts: a part with too little
 * behind it is left out (null or empty) rather than made up.
 */
export function summarizeRoutine(stored, now = Date.now()) {
  const r = readable(stored)
  const today = localParts(now, r.tz ?? 0).day
  const recent = r.days.filter(d => daysApart(d[0], today) < RECENT_DAYS)
  // A day says when it began and ended only when it was a day of use: more
  // than a moment, and spread over hours. A few minutes on a first evening
  // are not a bedtime; and one such day is not "usually".
  const full = recent.filter(d => d[3] >= 2 && d[2] - d[1] >= MIN_DAY_SPAN)
  // Medians are taken on the day's own scale (minutes from 04:00), so a
  // bedtime either side of midnight is still one bedtime.
  const span = list => {
    if (!list.length) return null
    const first = median(list.map(d => d[1])), last = median(list.map(d => d[2]))
    return { wake: onClock(first), sleep: onClock(last), first, last, days: list.length }
  }
  const all = full.length >= 2 ? span(full) : null
  const weekday = span(full.filter(d => !isWeekend(d[0])))
  const weekend = span(full.filter(d => isWeekend(d[0])))
  // Weekdays and weekends are told apart only when both are known and differ.
  const differs = weekday && weekend && weekday.days >= 3 && weekend.days >= 3 &&
    (Math.abs(weekday.first - weekend.first) >= 45 || Math.abs(weekday.last - weekend.last) >= 45)

  const combined = r.hours.wd.map((x, h) => x + r.hours.we[h])
  const top = Math.max(...combined)
  const hours = combined.map(x => (top > 0 ? Math.round((x / top) * 100) / 100 : 0))
  // The busiest three hours, and the longest stretch with next to nothing.
  let peak = null
  if (r.slots >= 8 && top > 0) {
    let best = -1
    for (let h = 0; h < 24; h++) {
      const s = combined[h] + combined[(h + 1) % 24] + combined[(h + 2) % 24]
      if (s > best) { best = s; peak = [h, (h + 3) % 24] }
    }
  }
  let quiet = null
  if (recent.length >= 2 && top > 0) {
    const low = combined.map(x => x <= top * 0.1)
    let bestLen = 0
    for (let h = 0; h < 24; h++) {
      if (!low[h] || low[(h + 23) % 24]) continue // a run starts after a busy hour
      let n = 0
      while (n < 24 && low[(h + n) % 24]) n++
      if (n > bestLen) { bestLen = n; quiet = [h, (h + n) % 24] }
    }
    if (bestLen < 3 || bestLen >= 24) quiet = null
  }

  const reply = r.reply.length >= 5 ? median(r.reply) : null
  const length = r.len.length >= 5 ? Math.round(median(r.len)) : null
  const kindTotal = sum(Object.values(r.kinds))
  const kinds = kindTotal > 0
    ? Object.entries(r.kinds).map(([kind, w]) => ({ kind, share: Math.round((w / kindTotal) * 100) }))
      .filter(k => k.share >= 1).sort((a, b) => b.share - a.share).slice(0, 4)
    : []
  const emoji = Object.entries(r.emoji).filter(([, w]) => w >= 1).sort((a, b) => b[1] - a[1]).slice(0, 5).map(([e]) => e)
  // Who they talk to at each time of day: one conversation that holds a
  // good part of that time, not just the one that happened to come first.
  const peers = []
  for (let b = 0; b < 4; b++) {
    const entries = Object.entries(r.peers).map(([room, bands]) => [room, bands[b]])
    const total = sum(entries.map(e => e[1]))
    const [room, w] = entries.sort((x, y) => y[1] - x[1])[0] || []
    if (room && w >= 2 && w >= total * 0.35) peers.push({ band: BANDS[b], room })
  }

  return {
    learning: !r.off,
    tz: r.tz,
    days: recent.length,
    confidence: routineConfidence(recent.length),
    wake: all?.wake ?? null,
    sleep: all?.sleep ?? null,
    weekday: differs ? { wake: weekday.wake, sleep: weekday.sleep } : null,
    weekend: differs ? { wake: weekend.wake, sleep: weekend.sleep } : null,
    hours,
    peak,
    quiet,
    reply,
    length,
    kinds,
    emoji,
    peers
  }
}

/**
 * The routine as a line or two for the writing help: what time it is for the
 * writer and how their day usually goes, how they usually answer. Left out
 * until there are a couple of days behind it.
 */
export function routineText(summary, now = Date.now()) {
  if (!summary || summary.confidence === 'none' || !summary.learning) return ''
  const lines = []
  if (summary.wake !== null && summary.sleep !== null) {
    const p = localParts(now, summary.tz ?? 0)
    const usual = p.weekend && summary.weekend ? summary.weekend : !p.weekend && summary.weekday ? summary.weekday : summary
    lines.push(`It's ${clock(p.minute)} where I am${p.weekend ? ' (weekend)' : ''}; I usually wake at ${clock(usual.wake)} and sleep at ${clock(usual.sleep)}.`)
  }
  if (summary.length !== null) {
    lines.push(summary.length <= 8 ? `My replies are usually short, about ${summary.length} characters.` : `My messages are usually around ${summary.length} characters.`)
  }
  if (summary.emoji?.length) lines.push(`Emoji I often use: ${summary.emoji.slice(0, 3).join(' ')}`)
  return lines.join('\n')
}
