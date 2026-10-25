// Access control for this personal deployment: one password (APP_PASSWORD
// secret) exchanged for a signed, HttpOnly session cookie.

const COOKIE = 'wxg_auth'
const MAX_AGE = 30 * 24 * 3600
const enc = new TextEncoder()

function b64url(buf) {
  let s = ''
  for (const b of new Uint8Array(buf)) s += String.fromCharCode(b)
  return btoa(s).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')
}

function fromB64url(s) {
  const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4))
  return Uint8Array.from(bin, c => c.charCodeAt(0))
}

async function hmacKey(env) {
  // Derived from the password, so changing APP_PASSWORD signs everyone out.
  const material = await crypto.subtle.digest('SHA-256', enc.encode(`wechat-glass/v1/${env.APP_PASSWORD}`))
  return crypto.subtle.importKey('raw', material, { name: 'HMAC', hash: 'SHA-256' }, false, ['sign', 'verify'])
}

export async function passwordMatches(env, input) {
  if (!env.APP_PASSWORD || typeof input !== 'string') return false
  const [a, b] = await Promise.all([
    crypto.subtle.digest('SHA-256', enc.encode(input)),
    crypto.subtle.digest('SHA-256', enc.encode(env.APP_PASSWORD))
  ])
  if (crypto.subtle.timingSafeEqual) return crypto.subtle.timingSafeEqual(a, b)
  const x = new Uint8Array(a)
  const y = new Uint8Array(b)
  let diff = 0
  for (let i = 0; i < x.length; i++) diff |= x[i] ^ y[i]
  return diff === 0
}

export async function issueCookie(env) {
  const exp = Math.floor(Date.now() / 1000) + MAX_AGE
  const body = `v1.${exp}`
  const sig = await crypto.subtle.sign('HMAC', await hmacKey(env), enc.encode(body))
  return `${COOKIE}=${body}.${b64url(sig)}; Path=/; Max-Age=${MAX_AGE}; HttpOnly; Secure; SameSite=Strict`
}

export function clearCookie() {
  return `${COOKIE}=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict`
}

/** Returns seconds until expiry, or 0 when the request is not signed in. */
export async function verifyRequest(env, request) {
  if (!env.APP_PASSWORD) return 0
  const header = request.headers.get('cookie') || ''
  const m = new RegExp(`(?:^|;\\s*)${COOKIE}=v1\\.(\\d+)\\.([A-Za-z0-9_-]+)`).exec(header)
  if (!m) return 0
  const exp = Number(m[1])
  const left = exp - Math.floor(Date.now() / 1000)
  if (left <= 0) return 0
  let sig
  try {
    sig = fromB64url(m[2])
  } catch {
    return 0
  }
  const ok = await crypto.subtle.verify('HMAC', await hmacKey(env), sig, enc.encode(`v1.${exp}`))
  return ok ? left : 0
}

export const AUTH_MAX_AGE = MAX_AGE
