// Account crypto: password hashing (PBKDF2-HMAC-SHA256) and signed session
// tokens. Pure functions used by the Hub Durable Object — the signing secret
// lives only inside the DO, so the Worker never needs it.

const enc = new TextEncoder()
const PBKDF2_ITERS = 310000
const TOKEN_MAX_AGE = 30 * 24 * 3600 // seconds

export function b64url(buf) {
  let s = ''
  for (const b of new Uint8Array(buf)) s += String.fromCharCode(b)
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

export function fromB64url(s) {
  const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4))
  return Uint8Array.from(bin, c => c.charCodeAt(0))
}

function timingEqual(a, b) {
  const x = new Uint8Array(a)
  const y = new Uint8Array(b)
  if (x.length !== y.length) return false
  if (crypto.subtle.timingSafeEqual) return crypto.subtle.timingSafeEqual(x, y)
  let diff = 0
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i]
  return diff === 0
}

// ---------------------------------------------------------------- passwords

/** Returns { salt, hash } as base64url strings. */
export async function hashPassword(password) {
  const salt = crypto.getRandomValues(new Uint8Array(16))
  const hash = await pbkdf2(password, salt)
  return { salt: b64url(salt), hash: b64url(hash) }
}

export async function verifyPassword(password, saltB64, hashB64) {
  if (typeof password !== 'string' || !saltB64 || !hashB64) return false
  let salt, expected
  try {
    salt = fromB64url(saltB64)
    expected = fromB64url(hashB64)
  } catch {
    return false
  }
  const actual = await pbkdf2(password, salt)
  return timingEqual(actual, expected)
}

async function pbkdf2(password, salt) {
  const key = await crypto.subtle.importKey('raw', enc.encode(password), 'PBKDF2', false, ['deriveBits'])
  return crypto.subtle.deriveBits(
    { name: 'PBKDF2', salt, iterations: PBKDF2_ITERS, hash: 'SHA-256' },
    key,
    256
  )
}

// ---------------------------------------------------------------- session tokens

async function hmacKey(secret) {
  return crypto.subtle.importKey('raw', secret, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify'])
}

/**
 * A stateless session token: base64url(JSON{uid,epoch,exp}).sig. `epoch` is the
 * user's token epoch, so bumping it (log out everywhere) invalidates old tokens
 * even though they still verify cryptographically.
 */
export async function mintToken(secret, { uid, epoch = 0, maxAge = TOKEN_MAX_AGE }) {
  const exp = Math.floor(Date.now() / 1000) + maxAge
  const body = b64url(enc.encode(JSON.stringify({ uid, epoch, exp })))
  const sig = await crypto.subtle.sign('HMAC', await hmacKey(secret), enc.encode(body))
  return `${body}.${b64url(sig)}`
}

/** Returns { uid, epoch, exp } when valid (signature + not expired), else null. */
export async function readToken(secret, token) {
  if (typeof token !== 'string') return null
  const dot = token.lastIndexOf('.')
  if (dot <= 0) return null
  const body = token.slice(0, dot)
  let sig, claims
  try {
    sig = fromB64url(token.slice(dot + 1))
    claims = JSON.parse(new TextDecoder().decode(fromB64url(body)))
  } catch {
    return null
  }
  const ok = await crypto.subtle.verify('HMAC', await hmacKey(secret), sig, enc.encode(body))
  if (!ok) return null
  if (!claims || typeof claims.uid !== 'string') return null
  if (!claims.exp || claims.exp <= Math.floor(Date.now() / 1000)) return null
  return claims
}

export const COOKIE = 'cfm_session'

export function cookieHeader(token, maxAge = TOKEN_MAX_AGE) {
  return `${COOKIE}=${token}; Path=/; Max-Age=${maxAge}; HttpOnly; Secure; SameSite=Strict`
}

export function clearCookieHeader() {
  return `${COOKIE}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict`
}

export function readCookie(request) {
  const header = request.headers.get('cookie') || ''
  const m = new RegExp(`(?:^|;\\s*)${COOKIE}=([^;]+)`).exec(header)
  return m ? m[1] : null
}

export const AUTH_MAX_AGE = TOKEN_MAX_AGE
