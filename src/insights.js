// Smart panels: what a conversation says about the other person, read by
// Workers AI from the messages already sent (as src/assist.js, never anyone's
// live typing preview) — when things they mentioned will happen, a ride they
// are in, getting home or heading out, a time and place you agreed on, how
// they seem, where their photos look to be taken, what was said lately,
// something going on for them (being ill, a period, a trip), what they like.
// Only what they said: nothing is guessed from outside the conversation.
// What is read is kept for the one who asked and shown only to them.

import { ask } from './assist.js'

export const VISION_MODEL = '@cf/llava-hf/llava-1.5-7b-hf'
export const WINDOW_MS = 7 * 24 * 3600 * 1000 // messages read: the last week
export const MAX_ROOMS = 6                     // conversations, most recent first
const MAX_LINES = 60
const MAX_PHOTOS = 3                           // of theirs, from the last three days
const PHOTO_BYTES = 1.5 * 1024 * 1024
const MIN = 60 * 1000
const HOUR = 60 * MIN
const DAY = 24 * HOUR
const WEEK = '日一二三四五六'

export const MOODS = ['开心', '兴奋', '平静', '疲惫', '低落', '焦虑', '生气', '难过']
export const RIDE_STAGES = ['等车', '在车上', '已下车']
export const HOME_STATES = ['到家', '出门', '在路上']

/** The conversations panels are made for: one-to-one, active this week. */
export function insightRooms(rooms, now = Date.now()) {
  return rooms
    .filter(r => r.kind === 'dm' && r.peer && r.last && now - r.ts < WINDOW_MS)
    .sort((a, b) => b.ts - a.ts)
    .slice(0, MAX_ROOMS)
}

/** A time as the viewer's clock shows it ("YYYY-MM-DD HH:mm"); tzOffset as Date#getTimezoneOffset. */
export function localTime(ts, tzOffset = 0) {
  return new Date(ts - tzOffset * MIN).toISOString().slice(0, 16).replace('T', ' ')
}
/** Back from the viewer's clock ("YYYY-MM-DD[ HH:mm]") to a time; null if it isn't one. */
export function fromLocal(text, tzOffset = 0) {
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:[ T](\d{2}):(\d{2}))?$/.exec(String(text ?? '').trim())
  if (!m) return null
  const t = Date.UTC(+m[1], +m[2] - 1, +m[3], +(m[4] ?? 0), +(m[5] ?? 0)) + tzOffset * MIN
  return Number.isFinite(t) && +m[2] >= 1 && +m[2] <= 12 && +m[3] >= 1 && +m[3] <= 31 ? t : null
}
const weekday = (ts, tzOffset) => `周${WEEK[new Date(ts - tzOffset * MIN).getUTCDay()]}`

/**
 * The conversation as the model reads it: numbered lines, oldest first —
 * "[3] 10-30 14:05 周四 对方：…". photos: descriptions of photos, by message.
 * refs[n - 1] is the message of line [n].
 */
export function transcript(messages, { me, tzOffset = 0, photos = new Map() }) {
  const lines = []
  const refs = []
  const shown = messages.filter(m => m.state !== 'revoked' && m.type !== 'system').slice(-MAX_LINES)
  for (const m of shown) {
    const body = m.type === 'text' ? m.body
      : m.type === 'sticker' ? `[表情 ${m.meta?.emoji || ''}]`
        : m.type === 'image' ? (photos.get(m.id) ? `[照片：${photos.get(m.id)}]` : '[照片]')
          : m.type === 'drawing' ? '[手绘]'
            : m.type === 'voice' ? '[语音]'
              : m.type === 'video' ? '[视频]'
                : m.type === 'file' ? `[文件 ${m.meta?.name || ''}]`
                  : m.type === 'call' ? '[通话]' : ''
    if (!body) continue
    refs.push(m)
    lines.push(`[${refs.length}] ${localTime(m.ts, tzOffset).slice(5)} ${weekday(m.ts, tzOffset)} ${m.sender === me ? '我' : '对方'}：${String(body).replace(/\s+/g, ' ').slice(0, 200)}`)
  }
  return { text: lines.join('\n'), refs }
}

export function prompt(text, { now, tzOffset = 0 }) {
  return [
    { role: 'system', content: '你帮我整理聊天里关于“对方”的提醒。只根据聊天记录里明确说过的内容，不要猜测或编造；没有的就留空。只输出 JSON。' },
    {
      role: 'user',
      content: `现在是 ${localTime(now, tzOffset)} ${weekday(now, tzOffset)}（我的当地时间）。
聊天记录（[编号] 时间 说话人：内容）：
${text || '（无）'}

按下面的格式输出 JSON。时间一律写成我的当地时间 "YYYY-MM-DD HH:mm"，“明天”“二十分钟后”之类按那条消息的时间推算；ref 是相关消息的编号。
{
"city": "对方现在所在的城市，没提到就空",
"upcoming": [{"what": "对方说的、将要发生的事（12字内）", "at": "YYYY-MM-DD HH:mm", "ref": 0}],
"ride": {"stage": "等车|在车上|已下车", "plate": "车牌", "car": "车型或颜色", "pickup": "预计上车时间", "dropoff": "预计或实际下车时间", "to": "目的地", "ref": 0},
"home": {"state": "到家|出门|在路上", "at": "YYYY-MM-DD HH:mm", "ref": 0},
"meetup": {"place": "我们约定见面的地点", "at": "YYYY-MM-DD HH:mm", "ref": 0},
"mood": {"label": "${MOODS.join('|')}", "note": "依据，一句话（20字内）", "ref": 0},
"photos": [{"ref": 0, "place": "对方发的照片大致在什么地方", "reading": "一句解读（20字内）"}],
"summary": "最近聊了什么，一两句话（40字内）",
"ongoing": [{"what": "对方持续中的事，如经期、生病、出差、考试（8字内）", "since": "YYYY-MM-DD", "until": "YYYY-MM-DD 或空", "note": "一句（16字内）", "ref": 0}],
"likes": ["对方喜欢的"], "dislikes": ["对方不喜欢的"], "hobbies": ["对方的爱好"]
}
没有的写 null 或 []。 /no_think`
    }
  ]
}

const str = (v, n) => (typeof v === 'string' ? [...v.replace(/\s+/g, ' ').trim()].slice(0, n).join('') : '')
const words = (v, n = 6) => (Array.isArray(v) ? [...new Set(v.map(x => str(x, 12)).filter(Boolean))].slice(0, n) : [])

/**
 * What the model answered, checked: only known values, short texts, times
 * that make sense for what they are (a ride within hours, a plan within a
 * month, getting home in the last day), references to real messages.
 * refs: the transcript's messages.
 */
export function readInsight(raw, { now = Date.now(), tzOffset = 0, refs = [] } = {}) {
  let o = {}
  try {
    o = JSON.parse(String(raw ?? '').match(/\{[\s\S]*\}/)?.[0] ?? '{}')
  } catch {}
  if (!o || typeof o !== 'object') o = {}
  const msg = v => {
    const i = Number(v)
    return Number.isInteger(i) && i >= 1 && i <= refs.length ? refs[i - 1] : null
  }
  const ref = v => msg(v)?.id || null
  const time = (v, past, future) => {
    const t = fromLocal(v, tzOffset)
    return t !== null && t >= now - past && t <= now + future ? t : null
  }

  const upcoming = (Array.isArray(o.upcoming) ? o.upcoming : [])
    .map(u => ({ what: str(u?.what, 24), at: time(u?.at, 30 * MIN, 30 * DAY), ref: ref(u?.ref) }))
    .filter(u => u.what && u.at)
    .slice(0, 4)

  let ride = null
  if (o.ride && RIDE_STAGES.includes(o.ride.stage)) {
    ride = {
      stage: o.ride.stage,
      plate: str(o.ride.plate, 12),
      car: str(o.ride.car, 16),
      pickup: time(o.ride.pickup, 6 * HOUR, 6 * HOUR),
      dropoff: time(o.ride.dropoff, 6 * HOUR, 6 * HOUR),
      to: str(o.ride.to, 20),
      ref: ref(o.ride.ref)
    }
    if (!ride.plate && !ride.pickup && !ride.dropoff && !ride.to) ride = null
  }

  let home = null
  if (o.home && HOME_STATES.includes(o.home.state)) {
    const at = time(o.home.at, DAY, 10 * MIN)
    if (at) home = { state: o.home.state, at, ref: ref(o.home.ref) }
  }

  let meetup = null
  if (o.meetup) {
    const place = str(o.meetup.place, 24)
    const at = time(o.meetup.at, HOUR, 30 * DAY)
    if (place && at) meetup = { place, at, ref: ref(o.meetup.ref) }
  }

  const mood = o.mood && MOODS.includes(o.mood.label) ? { label: o.mood.label, note: str(o.mood.note, 30), ref: ref(o.mood.ref) } : null

  // Only photos they sent.
  const photos = (Array.isArray(o.photos) ? o.photos : [])
    .map(p => ({ m: msg(p?.ref), place: str(p?.place, 20), reading: str(p?.reading, 30) }))
    .filter(p => p.m && p.m.type === 'image' && p.m.meta?.url && (p.place || p.reading))
    .filter((p, i, all) => all.findIndex(q => q.m.id === p.m.id) === i)
    .slice(0, MAX_PHOTOS)
    .map(p => ({ ref: p.m.id, url: p.m.meta.url, at: p.m.ts, place: p.place, reading: p.reading }))

  const ongoing = (Array.isArray(o.ongoing) ? o.ongoing : [])
    .map(e => {
      const since = time(e?.since, 60 * DAY, DAY)
      const end = fromLocal(e?.until, tzOffset)
      return { what: str(e?.what, 12), since, until: end === null ? null : end + DAY - 1, note: str(e?.note, 24), ref: ref(e?.ref) }
    })
    .filter(e => e.what && (e.until === null || e.until >= now))
    .slice(0, 3)

  return {
    city: str(o.city, 20),
    upcoming,
    ride,
    home,
    meetup,
    mood,
    photos,
    summary: str(o.summary, 80),
    ongoing,
    likes: words(o.likes),
    dislikes: words(o.dislikes),
    hobbies: words(o.hobbies)
  }
}

/** Read a conversation: its messages (oldest first), whose they are from (me), photo descriptions. */
export async function analyze(env, { messages, me, tzOffset = 0, now = Date.now(), photos }) {
  const recent = messages.filter(m => now - m.ts < WINDOW_MS)
  const { text, refs } = transcript(recent, { me, tzOffset, photos })
  if (!refs.length) return readInsight('{}', { now, tzOffset, refs })
  const raw = await ask(env, prompt(text, { now, tzOffset }), 900, { timeout: 20000 })
  return readInsight(raw, { now, tzOffset, refs })
}

/** Their photos worth describing: the newest few from the last three days. */
export function photosToRead(messages, me, now = Date.now()) {
  return messages
    .filter(m => m.type === 'image' && m.sender !== me && m.state !== 'revoked' && now - m.ts < 3 * DAY && /^\/api\/media\/image\/[\w-]+\/[\w-]+$/.test(m.meta?.url || ''))
    .slice(-MAX_PHOTOS)
}

/**
 * What a photo shows and where it looks to be taken, in a sentence, from
 * the vision model (AI_VISION_MODEL: an image-to-text model such as LLaVA,
 * or a chat model that reads images). '' when it can't be read.
 */
export async function describePhoto(env, bucket, m) {
  const key = String(m.meta?.url || '').replace(/^\/api\/media\//, '')
  const obj = await bucket.get(key)
  if (!obj || obj.size > PHOTO_BYTES) return ''
  const bytes = new Uint8Array(await obj.arrayBuffer())
  const model = String(env.AI_VISION_MODEL || VISION_MODEL).trim()
  const question = 'In one sentence: what kind of place does this photo seem to be taken in (any well-known landmark), and what is happening?'
  const input = /llava|uform/i.test(model)
    ? { image: [...bytes], prompt: question, max_tokens: 80 }
    : { messages: [{ role: 'user', content: [{ type: 'text', text: question }, { type: 'image_url', image_url: { url: `data:${obj.httpMetadata?.contentType || 'image/jpeg'};base64,${base64(bytes)}` } }] }], max_tokens: 80 }
  let timer
  const late = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('vision timeout')), 10000) })
  try {
    const out = await Promise.race([env.AI.run(model, input), late])
    return String(out?.description ?? out?.response ?? out?.choices?.[0]?.message?.content ?? '').replace(/\s+/g, ' ').trim().slice(0, 300)
  } finally {
    clearTimeout(timer)
  }
}

function base64(bytes) {
  let s = ''
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(s)
}

const lastRead = new Map() // uid:room -> when
const reads = new Map()    // uid -> when, this past hour
/** A conversation is read again at most once a minute, and each person's at most 30 times an hour. */
export function allowRefresh(uid, room, now = Date.now()) {
  const key = `${uid}:${room}`
  if (lastRead.has(key) && now - lastRead.get(key) < MIN) return false
  const times = (reads.get(uid) || []).filter(t => now - t < HOUR)
  if (times.length >= 30) return false
  times.push(now)
  reads.set(uid, times)
  lastRead.set(key, now)
  if (lastRead.size > 2000) lastRead.delete(lastRead.keys().next().value)
  if (reads.size > 1000) reads.delete(reads.keys().next().value)
  return true
}
