// Worker entry: serve the static UI from ./public and forward the dynamic
// routes to the single Hub Durable Object, which owns all accounts and state.

import { Hub } from './hub.js'

export { Hub }
export { WeChatSession } from './legacy-session.js'

const DYNAMIC = ['/api/', '/auth/', '/rtc/']

function hubStub(env) {
  const id = env.HUB.idFromName('main')
  const hint = env.DO_LOCATION_HINT
  return hint ? env.HUB.get(id, { locationHint: hint }) : env.HUB.get(id)
}

/** State-changing requests and socket upgrades must come from our own pages. */
function sameOrigin(request, url) {
  return request.headers.get('origin') === url.origin
}

function withViewerPlace(request) {
  const cf = request.cf || {}
  const headers = new Headers(request.headers)
  headers.delete('x-viewer-place')
  if (Number.isFinite(Number(cf.latitude)) && Number.isFinite(Number(cf.longitude))) {
    headers.set('x-viewer-place', JSON.stringify({ lat: Number(cf.latitude), lon: Number(cf.longitude), city: String(cf.city || '') }))
  }
  return new Request(request, { headers })
}

export default {
  async fetch(request, env) {
    const url = new URL(request.url)
    if (DYNAMIC.some(p => url.pathname.startsWith(p))) {
      const upgrade = request.headers.get('upgrade') === 'websocket'
      const mutating = request.method !== 'GET' && request.method !== 'HEAD'
      if ((mutating || upgrade) && !sameOrigin(request, url)) {
        return new Response(JSON.stringify({ ok: false, error: 'forbidden' }), {
          status: 403,
          headers: { 'content-type': 'application/json' }
        })
      }
      // The smart panels' weather falls back to where the request came from
      // (Cloudflare's own estimate of the visitor's city), handed over as is.
      if (url.pathname === '/api/insights') request = withViewerPlace(request)
      return hubStub(env).fetch(request)
    }
    return env.ASSETS.fetch(request)
  }
}
