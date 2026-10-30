// Telegram sticker packs for the chat, through our own Worker. The bot token
// stays on the server; the browser only ever talks to us. Each pack's list is
// kept for a few hours and each file is fetched from Telegram once, then kept
// in R2 (animated stickers are kept as plain Lottie JSON, already unzipped),
// so later readers never wait on Telegram.
//
// Three kinds, as Telegram has them: static (.webp), video (.webm) and
// animated (Lottie, .tgs). Ids are Telegram's file_unique_id.

const TG = 'https://api.telegram.org'
const DEFAULT_SETS = 'HandDrawnEmoji,GameEmoji'
const MANIFEST_KEY = 'stickers/manifest.json'
const MANIFEST_TTL = 6 * 3600 * 1000
const MAX_FILE = 2 * 1024 * 1024
const PER_SET = 120
export const STICKER_ID = /^[A-Za-z0-9_-]{4,64}$/
export const STICKER_KINDS = ['static', 'video', 'animated']

export function stickersConfigured(env) {
  return Boolean(env?.TELEGRAM_BOT_TOKEN)
}

/** Pack names from STICKER_SETS (comma or space separated), or the defaults. */
export function setNames(env) {
  return String(env?.STICKER_SETS || DEFAULT_SETS)
    .split(/[,\s]+/)
    .filter(n => /^[A-Za-z0-9_]{1,64}$/.test(n))
    .slice(0, 8)
}

const kindOf = s => (s.is_animated ? 'animated' : s.is_video ? 'video' : 'static')

async function telegram(env, method, params) {
  const res = await fetch(`${TG}/bot${env.TELEGRAM_BOT_TOKEN}/${method}`, {
    method: 'POST',
    headers: { 'content-type': 'application/json' },
    body: JSON.stringify(params),
    signal: AbortSignal.timeout(15000)
  })
  const data = await res.json().catch(() => null)
  if (!data?.ok) throw new Error(`telegram ${method}: ${data?.description || res.status}`)
  return data.result
}

/**
 * The packs as Telegram has them (file ids included), from R2 while fresh.
 * A pack that can't be read is left out rather than failing the rest.
 */
export async function manifest(env, bucket, { now = Date.now() } = {}) {
  const names = setNames(env).join(',')
  const kept = await bucket.get(MANIFEST_KEY)
  const old = kept ? await kept.json().catch(() => null) : null
  if (old && old.names === names && now - old.at < MANIFEST_TTL) return old
  const sets = []
  for (const name of setNames(env)) {
    try {
      const set = await telegram(env, 'getStickerSet', { name })
      sets.push({
        name,
        title: String(set.title || name).slice(0, 64),
        stickers: (set.stickers || []).slice(0, PER_SET).filter(s => STICKER_ID.test(s.file_unique_id || '')).map(s => ({
          id: s.file_unique_id,
          emoji: String(s.emoji || '').slice(0, 16),
          kind: kindOf(s),
          file: s.file_id,
          thumb: s.thumbnail?.file_id || null
        }))
      })
    } catch (err) {
      console.warn('stickers', name, err.message)
    }
  }
  // Telegram unreachable for every pack: keep serving what we had.
  if (!sets.length && old?.sets?.length) return old
  const next = { at: now, names, sets }
  if (sets.length) await bucket.put(MANIFEST_KEY, JSON.stringify(next), { httpMetadata: { contentType: 'application/json' } })
  return next
}

/** What the browser gets: no file ids, and whether a still picture exists. */
export function publicManifest(m) {
  return {
    sets: (m.sets || []).map(s => ({
      name: s.name,
      title: s.title,
      stickers: s.stickers.map(({ id, emoji, kind, thumb }) => ({ id, emoji, kind, nt: kind !== 'static' && !thumb }))
    }))
  }
}

export function findSticker(m, id) {
  for (const s of m.sets || []) for (const st of s.stickers) if (st.id === id) return st
  return null
}

const TYPES = { webp: 'image/webp', webm: 'video/webm', json: 'application/json', jpg: 'image/jpeg', png: 'image/png' }
const inflight = new Map()

/**
 * One sticker's file from R2, fetching it from Telegram the first time.
 * thumb: its still picture (animated and video stickers show it until they
 * play); anim: an animated sticker's Lottie JSON; range: the request's
 * headers, for a part of the file (Safari asks for video in parts). Returns
 * an R2 object, or null when there is no such sticker or file.
 */
export async function stickerFile(env, bucket, id, { thumb = false, anim = false, range = null } = {}) {
  if (!STICKER_ID.test(id || '')) return null
  const opts = range?.has('range') ? { range } : undefined
  // A kept file first: no list to read, and a sticker stays readable in old
  // messages after its pack is dropped. Each key belongs to one kind only
  // (.webp static, .webm video, .thumb a still picture, .json Lottie).
  for (const ext of anim ? ['json'] : thumb ? ['thumb', 'webp'] : ['webp', 'webm', 'thumb']) {
    const kept = await bucket.get(`stickers/${id}.${ext}`, opts)
    if (kept) return kept
  }
  const st = findSticker(await manifest(env, bucket), id)
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
  // Readers asking at once share one trip to Telegram.
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
