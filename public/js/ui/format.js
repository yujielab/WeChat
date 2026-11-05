// Time, size and name formatting in the style of iOS (en).

const WEEK = ['Sunday', 'Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday']
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']
const pad = n => String(n).padStart(2, '0')

function startOfDay(d) {
  const x = new Date(d)
  x.setHours(0, 0, 0, 0)
  return x.getTime()
}

const hm = d => `${pad(d.getHours())}:${pad(d.getMinutes())}`

/** Chat list column: 14:05 · Yesterday · Tuesday · 10/12 · 10/12/2025 */
export function listTime(ts) {
  if (!ts) return ''
  const d = new Date(ts)
  const today = startOfDay(Date.now())
  const day = startOfDay(ts)
  const diff = Math.round((today - day) / 86400000)
  if (diff <= 0) return hm(d)
  if (diff === 1) return 'Yesterday'
  if (diff < 7) return WEEK[d.getDay()]
  if (d.getFullYear() === new Date().getFullYear()) return `${d.getMonth() + 1}/${d.getDate()}`
  return `${d.getMonth() + 1}/${d.getDate()}/${d.getFullYear()}`
}

/** Centered thread timestamp, split so the day can be bold: [day, time]. */
export function threadTime(ts) {
  const d = new Date(ts)
  const today = startOfDay(Date.now())
  const day = startOfDay(ts)
  const diff = Math.round((today - day) / 86400000)
  let label
  if (diff <= 0) label = 'Today'
  else if (diff === 1) label = 'Yesterday'
  else if (diff < 7) label = WEEK[d.getDay()]
  else if (d.getFullYear() === new Date().getFullYear()) label = `${MONTHS[d.getMonth()]} ${d.getDate()}`
  else label = `${MONTHS[d.getMonth()]} ${d.getDate()}, ${d.getFullYear()}`
  return [label, hm(d)]
}

export function duration(seconds) {
  const s = Math.max(0, Math.round(seconds))
  return `${Math.floor(s / 60)}:${pad(s % 60)}`
}

/** A call's running clock: 00:42 · 12:05 · 1:02:09. */
export function callClock(ms) {
  const s = Math.max(0, Math.floor(ms / 1000))
  const hours = Math.floor(s / 3600)
  return hours ? `${hours}:${pad(Math.floor((s % 3600) / 60))}:${pad(s % 60)}` : `${pad(Math.floor(s / 60))}:${pad(s % 60)}`
}

export function fileSize(bytes) {
  if (!bytes) return ''
  const units = ['B', 'KB', 'MB', 'GB']
  let n = bytes
  let i = 0
  while (n >= 1024 && i < units.length - 1) {
    n /= 1024
    i++
  }
  return `${n >= 10 || i === 0 ? Math.round(n) : n.toFixed(1)} ${units[i]}`
}

// Whole user-perceived characters, so a family or flag emoji stays one.
const segmenter = typeof Intl !== 'undefined' && Intl.Segmenter ? new Intl.Segmenter(undefined, { granularity: 'grapheme' }) : null
const firstGrapheme = s => (segmenter ? segmenter.segment(s)[Symbol.iterator]().next().value?.segment : [...s][0]) || ''

/** Monogram for the avatar placeholder. */
export function initials(name) {
  const s = String(name || '').trim()
  if (!s) return ''
  const cjk = s.match(/[㐀-鿿豈-﫿]/)
  if (cjk) return cjk[0]
  const words = s.split(/\s+/).filter(Boolean)
  // Two letters only from two words that start with letters ("Ada Lovelace" → AL).
  if (words.length > 1 && /^\p{L}/u.test(words[0]) && /^\p{L}/u.test(words[1])) return (firstGrapheme(words[0]) + firstGrapheme(words[1])).toUpperCase()
  return firstGrapheme(s).toUpperCase()
}

/** Stable pleasant gradient for a placeholder avatar. */
export function avatarHue(id) {
  let h = 0
  for (const ch of String(id)) h = (h * 31 + ch.codePointAt(0)) >>> 0
  return h % 360
}

export function emojiOnly(text) {
  const t = String(text || '').trim()
  if (!t || [...t].length > 6) return false
  return /^(?:\p{Extended_Pictographic}|\p{Emoji_Component}|‍|️|\s)+$/u.test(t) && /\p{Extended_Pictographic}/u.test(t)
}

/**
 * What a call record says from this side of it. `mine`: this account placed
 * the call. The caller hears how it went (No answer, Cancelled, Declined,
 * Busy); the person called learns of a call they missed (Missed call, in
 * red) — one that came while they were on another call, too.
 */
export function callSummary(call = {}, mine) {
  const media = call.media === 'video' ? 'Video' : 'Voice'
  const result = call.result || (call.missed ? 'missed' : 'completed')
  let text
  let missed = false
  if (result === 'completed') text = call.duration >= 1 ? `Duration ${duration(call.duration)}` : 'Call ended'
  else if (result === 'failed') text = 'Connection failed'
  else if (result === 'declined') text = mine ? 'Declined' : 'You declined'
  else if (result === 'busy' && mine) text = 'Busy'
  else if (mine) text = result === 'cancelled' ? 'Cancelled' : 'No answer'
  else {
    text = 'Missed call'
    missed = true
  }
  return { media, text, missed, label: `${media} call · ${text}` }
}

/**
 * Where an outgoing message stands, as the bubble's corner shows it: a
 * clock while it is queued or going (every queued one, not just the last),
 * one tick once the hub has it, two once it reached the peer, two in the
 * read colour once read (DMs only), a mark when it failed. The label is
 * what a screen reader hears. Incoming messages have no state.
 */
export function sendState(m, read = false, dm = true) {
  if (!m?.out) return null
  if (m.status === 'failed') return { state: 'failed', label: 'Not sent' }
  if (m.status === 'sending' || String(m.id).startsWith('local:')) return { state: 'sending', label: 'Sending' }
  // Group chats never show the read colour, whatever the server marks.
  if (dm && (read || m.status === 'read')) return { state: 'read', label: 'Read' }
  if (m.status === 'delivered') return { state: 'delivered', label: 'Delivered' }
  return { state: 'sent', label: 'Sent' }
}

// For a folded group (photo stack, call run): the state that most needs
// noticing. A failure wins, then anything still going, then the least
// advanced tick, so the group never claims more than its weakest message.
const RANK = { failed: 0, sending: 1, sent: 2, delivered: 3, read: 4 }
export function groupState(states) {
  const known = states.filter(Boolean)
  return known.length ? known.reduce((a, b) => (RANK[b.state] < RANK[a.state] ? b : a)) : null
}
