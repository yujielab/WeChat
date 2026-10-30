// Telegram sticker packs for the chat, through our own Worker. The bot token
// stays on the server; the browser only ever talks to us. Each pack is kept
// for a few hours and each file is fetched from Telegram once, then kept in
// R2 (animated stickers are kept as plain Lottie JSON, already unzipped), so
// later readers never wait on Telegram.
//
// Packs come from a table of names (PRESETS, plus STICKER_SETS): everyone
// starts with STICKER_SETS and adds or removes the others in the app. Only
// names in that table are ever read, so the server can't be made to fetch an
// arbitrary pack.
//
// Three kinds, as Telegram has them: static (.webp), video (.webm) and
// animated (Lottie, .tgs). Ids are Telegram's file_unique_id.

const TG = 'https://api.telegram.org'
const DEFAULT_SETS = 'HandDrawnEmoji,GameEmoji'
const SET_TTL = 6 * 3600 * 1000
const MISSING_TTL = 3600 * 1000
const MAX_FILE = 2 * 1024 * 1024
const PER_SET = 120
export const MAX_CHOSEN = 16
export const STICKER_ID = /^[A-Za-z0-9_-]{4,64}$/
export const SET_NAME = /^[A-Za-z0-9_]{1,64}$/
export const STICKER_KINDS = ['static', 'video', 'animated']

/**
 * The packs anyone can add from the app. Names are Telegram's short names
 * (t.me/addstickers/<name>); a name Telegram refuses simply never shows.
 * Titles are ours: Telegram's often carry a channel's handle.
 */
export const PRESETS = [
  { name: 'HandDrawnEmoji', title: '手绘' },
  { name: 'GameEmoji', title: '游戏' },
  { name: 'ParisOlympicEmoji', title: '巴黎奥运' },
  { name: 'UtyaDuck', title: '小黄鸭' },
  { name: 'HotCherry', title: '樱桃' },
  { name: 'AnimatedEmojies', title: '动态 Emoji' },
  { name: 'LadyCat', title: '猫小姐' },
  { name: 'MottyEmojiAnim', title: 'Motty 猫' },
  { name: 'SiameseCatLive', title: '暹罗猫' },
  { name: 'LINE_Mochi_Mochi_Peach_Cat', title: '蜜桃猫' },
  { name: 'CAT_CAT_CAT111', title: 'ㄎㄧㄤ貓' },
  { name: 'Pusheen_3', title: 'Pusheen' },
  { name: 'utya_vk', title: '小鸭 Утя' },
  { name: 'AngryDuck', title: '生气的鸭子' }
]

// Telegram's names don't care about case.
const fold = name => String(name).toLowerCase()
export const sameSet = (a, b) => fold(a) === fold(b)

export function stickersConfigured(env) {
  return Boolean(env?.TELEGRAM_BOT_TOKEN)
}

/** The packs everyone starts with: STICKER_SETS (comma or space separated), or the defaults. */
export function setNames(env) {
  return String(env?.STICKER_SETS || DEFAULT_SETS)
    .split(/[,\s]+/)
    .filter(n => SET_NAME.test(n))
    .slice(0, 8)
}

/** Every pack that may be read: STICKER_SETS, then the presets. */
export function allowedSets(env) {
  const all = []
  for (const name of [...setNames(env), ...PRESETS.map(p => p.name)]) {
    if (!all.some(n => sameSet(n, name))) all.push(name)
  }
  return all
}

/** The table's spelling of a pack name, or null when it isn't in the table. */
export function allowedName(env, name) {
  return SET_NAME.test(String(name || '')) ? allowedSets(env).find(n => sameSet(n, name)) || null : null
}

/** A person's packs: what they chose, or the starting packs. */
export function chosenSets(env, chosen) {
  const names = []
  for (const n of Array.isArray(chosen) ? chosen : setNames(env)) {
    const name = allowedName(env, n)
    if (name && !names.includes(name)) names.push(name)
  }
  return names.slice(0, MAX_CHOSEN)
}

const kindOf = s => (s.is_animated ? 'animated' : s.is_video ? 'video' : 'static')
const presetTitle = name => PRESETS.find(p => sameSet(p.name, name))?.title

async function telegram(env, method, params) {
  const res = await fetch(`${TG}/bot${env.TELEGRAM_BOT_TOKEN}/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(params),
    signal: AbortSignal.timeout(15000)
  })
  const data = await res.json().catch(() => null)
  if (data?.ok) return data.result
  const err = new Error(`telegram ${method}: ${data?.description || res.status}`)
  // The pack doesn't exist (as opposed to Telegram being unreachable).
  err.missing = /STICKERSET_INVALID/i.test(data?.description || '')
  throw err
}

const inflightSets = new Map()

/**
 * One pack as Telegram has it (file ids included), from R2 while fresh. A
 * pack Telegram says doesn't exist is remembered for an hour; while Telegram
 * can't be reached the last copy is served. Null when there is nothing.
 */
export async function readSet(env, bucket, name, { now = Date.now() } = {}) {
  const key = `stickers/sets/${fold(name)}.json`
  const kept = await bucket.get(key)
  const old = kept ? await kept.json().catch(() => null) : null
  if (old && now - old.at < (old.missing ? MISSING_TTL : SET_TTL)) return old.missing ? null : old
  // Readers asking at once share one trip to Telegram.
  if (!inflightSets.has(key)) {
    inflightSets.set(key, fetchSet(env, bucket, key, name, now, old).finally(() => inflightSets.delete(key)))
  }
  return inflightSets.get(key)
}

async function fetchSet(env, bucket, key, name, now, old) {
  try {
    const set = await telegram(env, 'getStickerSet', { name })
    const next = {
      at: now,
      name,
      title: String(set.title || name).slice(0, 64),
      stickers: (set.stickers || []).slice(0, PER_SET).filter(s => STICKER_ID.test(s.file_unique_id || '')).map(s => ({
        id: s.file_unique_id,
        emoji: String(s.emoji || '').slice(0, 16),
        kind: kindOf(s),
        file: s.file_id,
        thumb: s.thumbnail?.file_id || null
      }))
    }
    await bucket.put(key, JSON.stringify(next), { httpMetadata: { contentType: 'application/json' } })
    return next
  } catch (err) {
    console.warn('stickers', name, err.message)
    if (err.missing) {
      await bucket.put(key, JSON.stringify({ at: now, name, missing: true }), { httpMetadata: { contentType: 'application/json' } })
      return null
    }
    return old && !old.missing ? old : null
  }
}

/** Several packs, in order; a pack that can't be read is left out. */
export async function readSets(env, bucket, names, opts) {
  return (await Promise.all(names.map(n => readSet(env, bucket, n, opts)))).filter(s => s?.stickers?.length)
}

const publicSticker = ({ id, emoji, kind, thumb }) => ({ id, emoji, kind, nt: kind !== 'static' && !thumb })

/** What the browser gets of a pack: no file ids, and whether a still picture exists. */
export function publicSet(s) {
  return { name: s.name, title: presetTitle(s.name) || s.title, stickers: s.stickers.map(publicSticker) }
}

/** The add list: every pack in the table that can be read, its first sticker as its cover. */
export async function catalog(env, bucket, chosen) {
  return (await readSets(env, bucket, allowedSets(env))).map(s => ({
    name: s.name,
    title: presetTitle(s.name) || s.title,
    count: s.stickers.length,
    cover: publicSticker(s.stickers[0]),
    added: chosen.some(n => sameSet(n, s.name))
  }))
}

function findSticker(sets, id) {
  for (const s of sets) for (const st of s.stickers) if (st.id === id) return st
  return null
}

const TYPES = { webp: 'image/webp', webm: 'video/webm', json: 'application/json', jpg: 'image/jpeg', png: 'image/png' }
const inflight = new Map()

/**
 * One sticker's file from R2, fetching it from Telegram the first time.
 * set: its pack (else it is looked for in the starting packs); thumb: its
 * still picture (animated and video stickers show it until they play); anim:
 * an animated sticker's Lottie JSON; range: the request's headers, for a part
 * of the file (Safari asks for video in parts). Returns an R2 object, or null
 * when there is no such sticker or file.
 */
export async function stickerFile(env, bucket, id, { set = null, thumb = false, anim = false, range = null } = {}) {
  if (!STICKER_ID.test(id || '')) return null
  const opts = range?.has('range') ? { range } : undefined
  // A kept file first: no pack to read, and a sticker stays readable in old
  // messages after its pack is dropped. Each key belongs to one kind only
  // (.webp static, .webm video, .thumb a still picture, .json Lottie).
  for (const ext of anim ? ['json'] : thumb ? ['thumb', 'webp'] : ['webp', 'webm', 'thumb']) {
    const kept = await bucket.get(`stickers/${id}.${ext}`, opts)
    if (kept) return kept
  }
  const pack = set && allowedName(env, set)
  const st = findSticker(await readSets(env, bucket, pack ? [pack] : setNames(env)), id)
  if (!st) return null
  let key, fileId
  if (anim) {
    if (st.kind !== 'animated') return null
    key = `stickers/${id}.json`
    fileId = st.file
  } else if (thumb || st.kind === 'animated') {
    if (!st.thumb) {
      if (st.kind !== 'static') return null
      key = `stickers/${id}.webp`
      fileId = st.file
    } else {
      key = `stickers/${id}.thumb`
      fileId = st.thumb
    }
  } else {
    key = `stickers/${id}.${st.kind === 'video' ? 'webm' : 'webp'}`
    fileId = st.file
  }
  if (!inflight.has(key)) {
    inflight.set(key, fetchInto(env, bucket, key, fileId, anim).finally(() => inflight.delete(key)))
  }
  await inflight.get(key)
  return bucket.get(key, opts)
}

/** The Content-Range of a part of a file, or null for the whole of it. */
export function contentRange(obj) {
  const r = obj?.range
  if (!r || !Number.isFinite(obj.size)) return null
  const start = r.suffix != null ? Math.max(0, obj.size - r.suffix) : r.offset || 0
  const end = r.suffix != null || r.length == null ? obj.size - 1 : Math.min(obj.size, start + r.length) - 1
  if (start === 0 && end === obj.size - 1) return null
  return `bytes ${start}-${end}/${obj.size}`
}

async function fetchInto(env, bucket, key, fileId, anim) {
  const file = await telegram(env, 'getFile', { file_id: fileId })
  const res = await fetch(`${TG}/file/bot${env.TELEGRAM_BOT_TOKEN}/${file.file_path}`, { signal: AbortSignal.timeout(20000) })
  if (!res.ok) throw new Error(`telegram file ${res.status}`)
  let bytes = new Uint8Array(await res.arrayBuffer())
  if (bytes.length > MAX_FILE) throw new Error('sticker too large')
  let ext = String(file.file_path).split('.').pop().toLowerCase()
  if (anim || ext === 'tgs') {
    // .tgs is gzipped Lottie JSON.
    bytes = new Uint8Array(await new Response(new Blob([bytes]).stream().pipeThrough(new DecompressionStream('gzip'))).arrayBuffer())
    if (bytes.length > 4 * MAX_FILE) throw new Error('sticker too large')
    ext = 'json'
  }
  const type = TYPES[ext]
  if (!type) throw new Error(`unexpected sticker file .${ext}`)
  await bucket.put(key, bytes, { httpMetadata: { contentType: type } })
}
