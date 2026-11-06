// Media storage on R2. Uploads are validated (membership, size) then streamed
// into the bucket; downloads stream back with a hardened, sandboxed response so
// a malicious file can never run as script on our origin.

import { rid } from './store.js'

const MAX_BYTES = 30 * 1024 * 1024 // 30 MB
const KINDS = new Set(['image', 'voice', 'video', 'file', 'avatar', 'cover', 'bg', 'moment'])
// Pictures that belong to an account rather than a conversation: its avatar
// and cover (seen by anyone), the backdrops it chose (seen only by it), and
// the photos and videos of its moments (seen by it and its friends).
const OWN = new Set(['avatar', 'cover', 'bg', 'moment'])
const PUBLIC = new Set(['avatar', 'cover'])
/** What each of an account's own kinds takes: pictures, and for a moment a video too. */
const OWN_TYPES = { moment: /^(image|video)\// }
const LOCAL_ID = /^[A-Za-z0-9_-]{1,64}$/

const DOWNLOAD_HEADERS = {
  'cache-control': 'private, max-age=31536000, immutable',
  'content-security-policy': "default-src 'none'; sandbox; frame-ancestors 'none'",
  'x-content-type-options': 'nosniff'
}

export async function handleMedia(request, url, user, hub) {
  const rest = url.pathname.replace(/^\/api\/media\/?/, '')

  if (rest === 'upload' && request.method === 'POST') {
    return upload(request, url, user, hub)
  }
  if (request.method === 'GET' && rest) {
    return download(rest, user, hub, request)
  }
  return j({ ok: false, error: 'not found' }, 404)
}

async function upload(request, url, user, hub) {
  const kind = url.searchParams.get('kind')
  if (!KINDS.has(kind)) return j({ ok: false, error: 'Unknown media type' }, 400)
  const room = url.searchParams.get('room') || ''
  if (!OWN.has(kind)) {
    if (!room || !hub.store.isMember(room, user.id)) return j({ ok: false, error: 'Not allowed to upload to this chat' }, 403)
  } else if (!(OWN_TYPES[kind] || /^image\//).test(request.headers.get('content-type') || '')) {
    return j({ ok: false, error: kind === 'moment' ? 'Please choose a photo or a video' : 'Please choose an image' }, 400)
  }
  const size = Number(request.headers.get('content-length') || 0)
  if (size > MAX_BYTES) return j({ ok: false, error: 'File too large (max 30MB)' }, 413)
  if (!request.body) return j({ ok: false, error: 'No content' }, 400)

  const contentType = request.headers.get('content-type') || 'application/octet-stream'
  const scope = OWN.has(kind) ? user.id : room
  // A picture from the outbox carries its message's localId: the same upload
  // repeated (its answer lost, a reload in between) is the same object, not
  // another copy. Keyed by the uploader too, so nobody else's id can reach it.
  const localId = OWN.has(kind) ? '' : String(url.searchParams.get('localId') || '')
  const key = LOCAL_ID.test(localId) ? `${kind}/${scope}/l${user.id}-${localId}` : `${kind}/${scope}/${rid()}`

  const existing = LOCAL_ID.test(localId) ? await hub.env.MEDIA.head(key) : null
  if (existing) {
    await request.body.cancel?.().catch(() => {})
  } else {
    await hub.env.MEDIA.put(key, request.body, {
      httpMetadata: { contentType },
      customMetadata: { by: user.id }
    })
  }

  // Display metadata is supplied by the client (dimensions, duration, name).
  const meta = {
    type: contentType,
    size: existing ? existing.size : size,
    name: safeName(url.searchParams.get('name')),
    w: numOr(url.searchParams.get('w')),
    h: numOr(url.searchParams.get('h')),
    dur: numOr(url.searchParams.get('dur'))
  }
  return j({ ok: true, key, url: `/api/media/${key}`, meta, ...(existing && { repeat: true }) })
}

async function download(key, user, hub, request) {
  // Room-scoped media requires membership; avatars and covers are visible to
  // any account, a backdrop only to whoever chose it, a moment's photos and
  // videos to the author's friends, and to anyone when the moment is for everyone.
  const [kind, scope] = key.split('/')
  if (!kind || !scope) return j({ ok: false, error: 'not found' }, 404)
  const allowed = PUBLIC.has(kind)
    || (kind === 'bg' ? scope === user.id
      : kind === 'moment' ? hub.store.canSeeMoments(scope, user.id) || (!hub.store.blockedWith(user.id).has(scope) && hub.store.isPublicMomentMedia(scope, `/api/media/${key}`))
        : hub.store.isMember(scope, user.id))
  if (!allowed) return j({ ok: false, error: 'No access' }, 403)
  // A video is played a range at a time (Safari asks for byte ranges, and
  // won't play one served whole).
  const range = request?.headers.get('range') ? request.headers : undefined
  const obj = await hub.env.MEDIA.get(key, range ? { range } : undefined)
  if (!obj) return j({ ok: false, error: 'not found' }, 404)
  const headers = new Headers(DOWNLOAD_HEADERS)
  headers.set('content-type', obj.httpMetadata?.contentType || 'application/octet-stream')
  headers.set('accept-ranges', 'bytes')
  if (obj.httpEtag) headers.set('etag', obj.httpEtag)
  const part = byteRange(obj)
  if (part) {
    headers.set('content-range', `bytes ${part.start}-${part.end}/${obj.size}`)
    headers.set('content-length', String(part.end - part.start + 1))
    return new Response(obj.body, { status: 206, headers })
  }
  headers.set('content-length', String(obj.size))
  return new Response(obj.body, { headers })
}

/** The bytes an R2 object read with a range holds ({ start, end }), or null when it is the whole. */
export function byteRange(obj) {
  const r = obj?.range
  if (!r || !Number.isFinite(obj.size)) return null
  const start = r.suffix != null ? Math.max(0, obj.size - r.suffix) : r.offset || 0
  const end = r.suffix != null || r.length == null ? obj.size - 1 : Math.min(obj.size, start + r.length) - 1
  if (start === 0 && end === obj.size - 1) return null
  return { start, end }
}

const j = (data, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } })

const numOr = v => { const n = Number(v); return Number.isFinite(n) && n > 0 ? n : undefined }
const safeName = v => (v ? String(v).replace(/[^\w.\-一-鿿 ]/g, '').slice(0, 80) : undefined)
