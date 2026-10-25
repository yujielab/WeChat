// Time, size and name formatting in the style of iOS (zh-CN).

const WEEK = ['星期日', '星期一', '星期二', '星期三', '星期四', '星期五', '星期六']
const pad = n => String(n).padStart(2, '0')

function startOfDay(d) {
  const x = new Date(d)
  x.setHours(0, 0, 0, 0)
  return x.getTime()
}

const hm = d => `${pad(d.getHours())}:${pad(d.getMinutes())}`

/** Chat list column: 14:05 · 昨天 · 星期二 · 10/12 · 2025/10/12 */
export function listTime(ts) {
  if (!ts) return ''
  const d = new Date(ts)
  const today = startOfDay(Date.now())
  const day = startOfDay(ts)
  const diff = Math.round((today - day) / 86400000)
  if (diff <= 0) return hm(d)
  if (diff === 1) return '昨天'
  if (diff < 7) return WEEK[d.getDay()]
  if (d.getFullYear() === new Date().getFullYear()) return `${d.getMonth() + 1}/${d.getDate()}`
  return `${d.getFullYear()}/${d.getMonth() + 1}/${d.getDate()}`
}

/** Centered thread timestamp, split so the day can be bold: [day, time]. */
export function threadTime(ts) {
  const d = new Date(ts)
  const today = startOfDay(Date.now())
  const day = startOfDay(ts)
  const diff = Math.round((today - day) / 86400000)
  let label
  if (diff <= 0) label = '今天'
  else if (diff === 1) label = '昨天'
  else if (diff < 7) label = WEEK[d.getDay()]
  else if (d.getFullYear() === new Date().getFullYear()) label = `${d.getMonth() + 1}月${d.getDate()}日`
  else label = `${d.getFullYear()}年${d.getMonth() + 1}月${d.getDate()}日`
  return [label, hm(d)]
}

export function duration(seconds) {
  const s = Math.max(0, Math.round(seconds))
  return `${Math.floor(s / 60)}:${pad(s % 60)}`
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

/** Monogram for the avatar placeholder. */
export function initials(name) {
  const s = String(name || '').trim()
  if (!s) return ''
  const cjk = s.match(/[㐀-鿿豈-﫿]/)
  if (cjk) return cjk[0]
  const words = s.split(/\s+/).filter(Boolean)
  if (words.length > 1) return (words[0][0] + words[1][0]).toUpperCase()
  return [...s][0].toUpperCase()
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
