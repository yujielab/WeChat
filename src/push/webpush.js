// Web Push for home-screen web apps (iOS 16.4+): VAPID (RFC 8292) and
// aes128gcm payload encryption (RFC 8291), using only WebCrypto.

const enc = new TextEncoder()

/**
 * A fresh VAPID key pair: the public key as the raw point, base64url (what
 * browsers take as applicationServerKey), the private key as its JWK `d`.
 */
export async function generateVapid() {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
  const publicKey = b64urlEncode(new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey)))
  const { d } = await crypto.subtle.exportKey('jwk', pair.privateKey)
  return { publicKey, privateKey: d }
}

export function b64urlEncode(bytes) {
  let s = ''
  for (const b of new Uint8Array(bytes)) s += String.fromCharCode(b)
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

export function b64urlDecode(s) {
  const bin = atob(String(s).replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4))
  return Uint8Array.from(bin, c => c.charCodeAt(0))
}

function concat(...parts) {
  const out = new Uint8Array(parts.reduce((n, p) => n + p.length, 0))
  let o = 0
  for (const p of parts) {
    out.set(p, o)
    o += p.length
  }
  return out
}

async function hkdf(salt, ikm, info, length) {
  const key = await crypto.subtle.importKey('raw', ikm, 'HKDF', false, ['deriveBits'])
  const bits = await crypto.subtle.deriveBits({ name: 'HKDF', hash: 'SHA-256', salt, info }, key, length * 8)
  return new Uint8Array(bits)
}

function p256Jwk(publicRaw, d) {
  const jwk = {
    kty: 'EC',
    crv: 'P-256',
    x: b64urlEncode(publicRaw.slice(1, 33)),
    y: b64urlEncode(publicRaw.slice(33, 65)),
    ext: true
  }
  if (d) jwk.d = typeof d === 'string' ? d : b64urlEncode(d)
  return jwk
}

/**
 * RFC 8291 §3–4. `opts.salt` and `opts.serverKeys` exist only so the RFC's
 * test vector can be reproduced; normal calls generate fresh ones.
 */
export async function encryptPayload(plaintext, uaPublic, authSecret, opts = {}) {
  const salt = opts.salt || crypto.getRandomValues(new Uint8Array(16))
  let asPublic
  let asPrivateKey
  if (opts.serverKeys) {
    asPublic = opts.serverKeys.publicRaw
    asPrivateKey = await crypto.subtle.importKey(
      'jwk', p256Jwk(asPublic, opts.serverKeys.d), { name: 'ECDH', namedCurve: 'P-256' }, false, ['deriveBits']
    )
  } else {
    const pair = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits'])
    asPublic = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey))
    asPrivateKey = pair.privateKey
  }
  const uaKey = await crypto.subtle.importKey('raw', uaPublic, { name: 'ECDH', namedCurve: 'P-256' }, false, [])
  const ecdhSecret = new Uint8Array(await crypto.subtle.deriveBits({ name: 'ECDH', public: uaKey }, asPrivateKey, 256))

  const keyInfo = concat(enc.encode('WebPush: info\0'), uaPublic, asPublic)
  const ikm = await hkdf(authSecret, ecdhSecret, keyInfo, 32)
  const cek = await hkdf(salt, ikm, enc.encode('Content-Encoding: aes128gcm\0'), 16)
  const nonce = await hkdf(salt, ikm, enc.encode('Content-Encoding: nonce\0'), 12)

  // Single record: plaintext followed by the 0x02 "last record" delimiter.
  const record = concat(plaintext, new Uint8Array([2]))
  const aesKey = await crypto.subtle.importKey('raw', cek, 'AES-GCM', false, ['encrypt'])
  const cipher = new Uint8Array(await crypto.subtle.encrypt({ name: 'AES-GCM', iv: nonce }, aesKey, record))

  const rs = 4096
  const header = concat(salt, new Uint8Array([rs >>> 24, (rs >>> 16) & 255, (rs >>> 8) & 255, rs & 255, asPublic.length]), asPublic)
  return concat(header, cipher)
}

/** vapid: { publicKey, privateKey, subject } — subject a mailto: or https: URL (RFC 8292). */
export async function vapidAuthorization(vapid, endpoint) {
  const publicRaw = b64urlDecode(vapid.publicKey)
  const key = await crypto.subtle.importKey(
    'jwk', p256Jwk(publicRaw, vapid.privateKey), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign']
  )
  const header = b64urlEncode(enc.encode(JSON.stringify({ typ: 'JWT', alg: 'ES256' })))
  const claims = b64urlEncode(enc.encode(JSON.stringify({
    aud: new URL(endpoint).origin,
    exp: Math.floor(Date.now() / 1000) + 12 * 3600,
    sub: vapid.subject || 'mailto:push@cuven.invalid'
  })))
  const sig = await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, enc.encode(`${header}.${claims}`))
  return `vapid t=${header}.${claims}.${b64urlEncode(sig)}, k=${vapid.publicKey}`
}

/**
 * A Declarative Web Push message (web_push 8030). Browsers that support it
 * (Safari 18.4 and later, iOS Home Screen apps included) show the
 * notification themselves, with no script running, so it arrives even when
 * the app was closed long ago; the rest hand the same JSON to the service
 * worker's push event, which shows it the same way (public/sw.js).
 * `navigate` must be an absolute URL: activating the notification opens it.
 */
export function declarativeMessage({ title, body = '', navigate, tag, badge, silent = false }) {
  const notification = { title: String(title || 'Cuven'), body: String(body), navigate: String(navigate), lang: 'zh-CN', dir: 'ltr', silent: Boolean(silent) }
  if (tag) notification.tag = String(tag)
  if (Number.isInteger(badge) && badge >= 0) notification.app_badge = String(badge)
  return { web_push: 8030, notification }
}

async function topicFor(tag) {
  const digest = await crypto.subtle.digest('SHA-256', enc.encode(String(tag)))
  return b64urlEncode(new Uint8Array(digest).slice(0, 24))
}

/**
 * Sends one notification. Returns the push service response. A `topic`
 * replaces any undelivered message with the same topic (a newer preview of
 * the same chat, or a call that has since ended).
 */
export async function sendWebPush(vapid, subscription, payload, { ttl = 86400, topic = null } = {}) {
  const body = await encryptPayload(
    enc.encode(JSON.stringify(payload)),
    b64urlDecode(subscription.keys.p256dh),
    b64urlDecode(subscription.keys.auth)
  )
  const headers = {
    'Content-Encoding': 'aes128gcm',
    'Content-Type': 'application/octet-stream',
    TTL: String(ttl),
    Urgency: 'high',
    Authorization: await vapidAuthorization(vapid, subscription.endpoint)
  }
  if (topic) headers.Topic = await topicFor(topic)
  return fetch(subscription.endpoint, { method: 'POST', headers, body, signal: AbortSignal.timeout(15000) })
}
