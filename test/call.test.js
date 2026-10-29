import { test } from 'node:test'
import assert from 'node:assert/strict'
import { CallBroker } from '../src/call.js'

const env = {
  REALTIME_APP_ID: 'app-id', REALTIME_APP_SECRET: 'app-secret',
  REALTIME_TURN_KEY_ID: 'turn-id', REALTIME_TURN_KEY_TOKEN: 'turn-secret'
}
const broker = extra => new CallBroker({ env: { ...env, ...extra } })
const json = (data, status = 200) => new Response(JSON.stringify(data), { status })
const stun = { urls: 'stun:stun.cloudflare.com:3478' }
const turn = { urls: ['turn:turn.cloudflare.com:3478?transport=udp', 'turns:turn.cloudflare.com:443?transport=tcp'], username: 'temporary-user', credential: 'temporary-password' }

test('TURN requests the ICE-server endpoint and returns a flat browser-compatible list', async t => {
  t.mock.method(globalThis, 'fetch', async (url, init) => {
    assert.equal(url, 'https://rtc.live.cloudflare.com/v1/turn/keys/turn-id/credentials/generate-ice-servers')
    assert.equal(init.headers.Authorization, 'Bearer turn-secret')
    assert.deepEqual(JSON.parse(init.body), { ttl: 86400 })
    return json({ iceServers: [stun, turn] }, 201)
  })
  const res = await broker().turn()
  assert.equal(res.status, 200)
  assert.deepEqual(await res.json(), { ok: true, iceServers: [stun, turn] })
})

test('TURN accepts the single-object credential response without changing its shape', async t => {
  t.mock.method(globalThis, 'fetch', async () => json({ iceServers: turn }))
  assert.deepEqual(await (await broker().turn()).json(), { ok: true, iceServers: [turn] })
})

test('optional TURN absence keeps the public STUN fallback without an upstream request', async t => {
  t.mock.method(globalThis, 'fetch', () => { throw new Error('unexpected fetch') })
  assert.deepEqual(await (await broker({ REALTIME_TURN_KEY_TOKEN: '' }).turn()).json(), { ok: true, iceServers: [stun] })
})

test('configured TURN credential rejection stays visible and does not leak upstream content', async t => {
  t.mock.method(globalThis, 'fetch', async () => json({ errorCode: 'unauthorized', errorDescription: env.REALTIME_TURN_KEY_TOKEN }, 401))
  const res = await broker().turn(), data = await res.json()
  assert.equal(res.status, 502)
  assert.equal(data.code, 'TURN_AUTH')
  assert.equal(data.upstreamStatus, 401)
  assert.match(data.error, /REALTIME_TURN_KEY_TOKEN/)
  assert.ok(!JSON.stringify(data).includes('turn-secret'))
  assert.equal(data.iceServers, undefined)
})

test('malformed TURN data is rejected instead of creating an invalid peer connection', async t => {
  for (const value of [{}, { iceServers: [] }, { iceServers: [[turn]] }, { iceServers: [{ urls: null }] }, { iceServers: [{ urls: 'https://example.com' }] }]) {
    t.mock.method(globalThis, 'fetch', async () => json(value))
    const res = await broker().turn()
    assert.equal(res.status, 502)
    assert.equal((await res.json()).code, 'TURN_RESPONSE')
  }
})

test('SFU success preserves the session and SDP response and trims pasted credential whitespace', async t => {
  const offer = { type: 'offer', sdp: 'v=0\r\n' }, data = { sessionId: 'session', sessionDescription: { type: 'answer', sdp: 'answer' } }
  t.mock.method(globalThis, 'fetch', async (url, init) => {
    assert.equal(url, 'https://rtc.live.cloudflare.com/v1/apps/app-id/sessions/new')
    assert.equal(init.headers.Authorization, 'Bearer app-secret')
    assert.deepEqual(JSON.parse(init.body), { sessionDescription: offer })
    return json(data, 201)
  })
  const res = await broker({ REALTIME_APP_ID: ' app-id\n', REALTIME_APP_SECRET: ' app-secret\n' }).rtc('POST', '/sessions/new', { sessionDescription: offer })
  assert.equal(res.status, 201)
  assert.deepEqual(await res.json(), data)
  assert.equal(res.headers.get('cache-control'), 'no-store')
})

test('SFU HTTP credential rejection returns an actionable message without raw response data', async t => {
  t.mock.method(globalThis, 'fetch', async () => json({ errorCode: 'unauthorized', errorDescription: env.REALTIME_APP_SECRET }, 403))
  const res = await broker().rtc('POST', '/sessions/new', {})
  const data = await res.json()
  assert.equal(res.status, 502)
  assert.equal(data.code, 'RTC_AUTH')
  assert.equal(data.upstreamStatus, 403)
  assert.match(data.error, /Serverless SFU/)
  assert.ok(!JSON.stringify(data).includes('app-secret'))
})

test('SFU reports an app that does not exist separately from a service outage', async t => {
  t.mock.method(globalThis, 'fetch', async () => json({ errorCode: 'not_found' }, 404))
  const res = await broker().rtc('POST', '/sessions/new', {})
  assert.equal(res.status, 502)
  assert.equal((await res.json()).code, 'RTC_APP_NOT_FOUND')
})

test('SFU missing sessions and media do not blame the configured App ID', async t => {
  for (const path of ['/sessions/id/tracks/new', '/sessions/id/renegotiate', '/sessions/id/tracks/close']) {
    for (const status of [200, 404]) {
      t.mock.method(globalThis, 'fetch', async () => json({ errorCode: 'not_found' }, status))
      const res = await broker().rtc(path.endsWith('/new') ? 'POST' : 'PUT', path, {})
      const data = await res.json()
      assert.equal(res.status, 502)
      assert.equal(data.code, 'RTC_MEDIA')
      assert.match(data.error, /会话或媒体已失效/)
      assert.ok(!data.error.includes('REALTIME_APP_ID'))
    }
  }
})

test('SFU errors inside HTTP 200 are not reported as a successful call', async t => {
  for (const payload of [{ errorCode: 'unauthorized' }, { error: 'private upstream error' }, { success: false, errors: [{ code: 1000, message: 'private' }] }, { tracks: [{ errorCode: 'invalid_session_description' }] }, { tracks: [{ errorCode: 'not_found_track_error' }] }]) {
    t.mock.method(globalThis, 'fetch', async () => json(payload))
    const res = await broker().rtc('POST', '/sessions/id/tracks/new', {})
    assert.equal(res.status, 502)
    assert.equal((await res.json()).ok, false)
  }
})

test('SFU empty successful cleanup responses remain valid HTTP 204', async t => {
  t.mock.method(globalThis, 'fetch', async () => new Response(null, { status: 204 }))
  const res = await broker().rtc('PUT', '/sessions/id/tracks/close', { tracks: [{ mid: '0' }] })
  assert.equal(res.status, 204)
  assert.equal(await res.text(), '')
  assert.equal(res.headers.get('cache-control'), 'no-store')
})

test('SFU malformed successful payloads return a diagnostic instead of an empty session', async t => {
  t.mock.method(globalThis, 'fetch', async () => new Response('private invalid response', { status: 200 }))
  const res = await broker().rtc('POST', '/sessions/new', {})
  assert.equal(res.status, 502)
  const data = await res.json()
  assert.equal(data.code, 'RTC_RESPONSE')
  assert.ok(!JSON.stringify(data).includes('private invalid response'))
})

test('SFU non-JSON errors and network failures yield public service diagnostics', async t => {
  t.mock.method(globalThis, 'fetch', async () => new Response('<html>upstream private dump</html>', { status: 502 }))
  let res = await broker().rtc('POST', '/sessions/new', {})
  assert.equal(res.status, 503)
  assert.equal((await res.json()).code, 'RTC_SERVICE')
  t.mock.method(globalThis, 'fetch', async () => { throw new Error('app-secret') })
  res = await broker().rtc('POST', '/sessions/new', {})
  assert.equal(res.status, 503)
  assert.ok(!(await res.text()).includes('app-secret'))
})

test('TURN network failures and HTTP rate limits are not silently downgraded to STUN', async t => {
  t.mock.method(globalThis, 'fetch', async () => { throw new Error('network') })
  let res = await broker().turn()
  assert.equal((await res.json()).code, 'TURN_SERVICE')
  t.mock.method(globalThis, 'fetch', async () => json({}, 429))
  res = await broker().turn()
  assert.equal(res.status, 503)
  assert.equal((await res.json()).code, 'TURN_RATE_LIMIT')
})

test('unconfigured SFU is disabled and returns the config diagnostic before proxying', async () => {
  const service = broker({ REALTIME_APP_ID: '  ' })
  assert.deepEqual(service.configured(), { enabled: false })
  const request = new Request('https://example.test/rtc/sessions/new', { method: 'POST' })
  const res = await service.http(request, new URL(request.url), {})
  assert.equal(res.status, 503)
  assert.equal((await res.json()).code, 'RTC_CONFIG')
})
