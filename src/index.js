// Worker entry: static UI from ./public, password gate, and /api/* forwarded
// to the single WeChat session Durable Object.

import { WeChatSession } from './session.js'
import { passwordMatches, issueCookie, clearCookie, verifyRequest, AUTH_MAX_AGE } from './auth.js'

export { WeChatSession }

const json = (data, status = 200, headers = {}) =>
  new Response(JSON.stringify(data), {
    status,
    headers: { 'content-type': 'application/json; charset=utf-8', 'cache-control': 'no-store', ...headers }
  })

function sessionStub(env) {
  const id = env.WX.idFromName('main')
  const hint = env.DO_LOCATION_HINT
  return hint ? env.WX.get(id, { locationHint: hint }) : env.WX.get(id)
}

/** State-changing requests and socket upgrades must come from our own pages. */
function sameOrigin(request, url) {
  const origin = request.headers.get('origin')
  return origin === url.origin
}

async function handleAuth(request, env, url) {
  if (url.pathname === '/auth/status' && request.method === 'GET') {
    return json({ configured: Boolean(env.APP_PASSWORD), authed: (await verifyRequest(env, request)) > 0 })
  }
  if (request.method !== 'POST') return json({ error: 'method not allowed' }, 405)
  if (!sameOrigin(request, url)) return json({ error: 'forbidden' }, 403)

  if (url.pathname === '/auth/login') {
    if (!env.APP_PASSWORD) return json({ ok: false, error: '尚未设置 APP_PASSWORD' }, 503)
    const ip = request.headers.get('cf-connecting-ip') || 'local'
    const stub = sessionStub(env)
    const gate = await stub.authGate(ip)
    if (!gate.allowed) {
      return json({ ok: false, error: `尝试次数过多，请 ${Math.ceil(gate.retryAfter / 60)} 分钟后再试` }, 429, {
        'retry-after': String(gate.retryAfter)
      })
    }
    let body = {}
    try {
      body = await request.json()
    } catch {
      // Treated as an empty password below.
    }
    const ok = await passwordMatches(env, body.password)
    await stub.authResult(ip, ok)
    if (!ok) return json({ ok: false, error: '密码不正确' }, 401)
    return json({ ok: true }, 200, { 'set-cookie': await issueCookie(env) })
  }
  if (url.pathname === '/auth/logout') {
    return json({ ok: true }, 200, { 'set-cookie': clearCookie() })
  }
  return json({ error: 'not found' }, 404)
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url)

    if (url.pathname.startsWith('/auth/')) return handleAuth(request, env, url)

    if (url.pathname.startsWith('/api/')) {
      if (!env.APP_PASSWORD) return json({ ok: false, error: '尚未设置 APP_PASSWORD', setup: true }, 503)
      const left = await verifyRequest(env, request)
      if (!left) return json({ ok: false, error: '未登录' }, 401)
      const upgrade = request.headers.get('upgrade') === 'websocket'
      if ((request.method !== 'GET' && request.method !== 'HEAD') || upgrade) {
        if (!sameOrigin(request, url)) return json({ ok: false, error: 'forbidden' }, 403)
      }
      const res = await sessionStub(env).fetch(request)
      // Sliding session: refresh the cookie when less than half its life remains.
      if (!upgrade && left < AUTH_MAX_AGE / 2 && res.status < 400) {
        const out = new Response(res.body, res)
        out.headers.append('set-cookie', await issueCookie(env))
        return out
      }
      return res
    }

    return env.ASSETS.fetch(request)
  }
}
