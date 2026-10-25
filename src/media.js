// Media storage on R2. Uploads are validated (membership, size) then streamed
// into the bucket; downloads stream back with a hardened, sandboxed response so
// a malicious file can never run as script on our origin.

import { rid } from './store.js'

const MAX_BYTES = 30 * 1024 * 1024 // 30 MB
const KINDS = new Set(['image', 'voice', 'video', 'file', 'avatar'])

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
    return download(rest, user, hub)
  }
  return j({ ok: false, error: 'not found' }, 404)
}

async function upload(request, url, user, hub) {
  const kind = url.searchParams.get('kind')
  if (!KINDS.has(kind)) return j({ ok: false, error: '未知的媒体类型' }, 400)
  const room = url.searchParams.get('room') || ''
  if (kind !== 'avatar') {
    if (!room || !hub.store.isMember(room, user.id)) return j({ ok: false, error: '无权上传到该会话' }, 403)
  }
  const size = Number(request.headers.get('content-length') || 0)
  if (size > MAX_BYTES) return j({ ok: false, error: '文件过大（上限 30MB）' }, 413)
  if (!request.body) return j({ ok: false, error: '没有内容' }, 400)

  const contentType = request.headers.get('content-type') || 'application/octet-stream'
  const scope = kind === 'avatar' ? user.id : room
  const key = `${kind}/${scope}/${rid()}`

  await hub.env.MEDIA.put(key, request.body, {
    httpMetadata: { contentType },
    customMetadata: { by: user.id }
  })

  // Display metadata is supplied by the client (dimensions, duration, name).
  const meta = {
    type: contentType,
    size,
    name: safeName(url.searchParams.get('name')),
    w: numOr(url.searchParams.get('w')),
    h: numOr(url.searchParams.get('h')),
    dur: numOr(url.searchParams.get('dur'))
  }
  return j({ ok: true, key, url: `/api/media/${key}`, meta })
}

async function download(key, user, hub) {
  // Room-scoped media requires membership; avatars are visible to any account.
  const [kind, scope] = key.split('/')
  if (!kind || !scope) return j({ ok: false, error: 'not found' }, 404)
  if (kind !== 'avatar' && !hub.store.isMember(scope, user.id)) {
    return j({ ok: false, error: '无权访问' }, 403)
  }
  const obj = await hub.env.MEDIA.get(key)
  if (!obj) return j({ ok: false, error: 'not found' }, 404)
  const headers = new Headers(DOWNLOAD_HEADERS)
  headers.set('content-type', obj.httpMetadata?.contentType || 'application/octet-stream')
  headers.set('content-length', String(obj.size))
  if (obj.httpEtag) headers.set('etag', obj.httpEtag)
  return new Response(obj.body, { headers })
}

const j = (data, status = 200) =>
  new Response(JSON.stringify(data), { status, headers: { 'content-type': 'application/json', 'cache-control': 'no-store' } })

const numOr = v => { const n = Number(v); return Number.isFinite(n) && n > 0 ? n : undefined }
const safeName = v => (v ? String(v).replace(/[^\w.\-一-鿿 ]/g, '').slice(0, 80) : undefined)
