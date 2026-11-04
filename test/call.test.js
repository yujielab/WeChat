import { test } from 'node:test'
import assert from 'node:assert/strict'
import { DatabaseSync } from 'node:sqlite'
import { webcrypto } from 'node:crypto'
import { Store } from '../src/store.js'
import { CallBroker } from '../src/call.js'
import { declarativeMessage } from '../src/push/webpush.js'

globalThis.crypto ??= webcrypto

/** A broker over a real store, with a hub that records what it sends. */
function setup({ online = ['a', 'b'], subscribed = [] } = {}) {
  const db = new DatabaseSync(':memory:')
  const store = new Store((q, ...b) => db.prepare(q).all(...b).map(r => ({ ...r })))
  const mk = name => store.createUser({ username: name, display: name.toUpperCase(), salt: 's', hash: 'h' })
  const ids = { a: mk('alice').id, b: mk('bob').id }
  const room = store.getOrCreateDM(ids.a, ids.b)
  const sockets = new Set(online.map(k => ids[k]))
  const sent = []
  const pushes = []
  const hub = {
    env: {},
    store,
    isOnline: uid => sockets.has(uid),
    sendToUser: (uid, payload) => { if (sockets.has(uid)) sent.push({ to: uid, ...payload }) },
    fanoutToRoom: () => {},
    pushTo: async (uid, n) => {
      if (!subscribed.some(k => ids[k] === uid)) return 0
      pushes.push({ to: uid, ...n })
      return 1
    }
  }
  const broker = new CallBroker(hub)
  const kinds = uid => sent.filter(m => m.to === uid).map(m => m.kind)
  return { broker, store, ids, room, sockets, sent, pushes, kinds }
}
const tick = () => new Promise(r => setTimeout(r, 5))

test('a callee whose app is open is rung there and the caller hears it', async () => {
  const t = setup()
  t.broker.signal(t.ids.a, { t: 'call', kind: 'invite', room: t.room, callId: 'c1', media: 'audio' })
  assert.deepEqual(t.kinds(t.ids.b), ['invite'])
  t.broker.signal(t.ids.b, { t: 'call', kind: 'ringing', room: t.room, callId: 'c1' })
  assert.deepEqual(t.kinds(t.ids.a), ['ringing'])
  await t.broker.alert(t.room, 'c1', { wait: 0 })
  assert.equal(t.pushes.length, 0, 'no notification once the app rings')
})

test('a callee with no app open is rung by notification, and the caller hears that', async () => {
  const t = setup({ online: ['a'], subscribed: ['b'] })
  t.broker.signal(t.ids.a, { t: 'call', kind: 'invite', room: t.room, callId: 'c1', media: 'video' })
  await tick()
  assert.equal(t.pushes.length, 1)
  assert.equal(t.pushes[0].body, '邀请你视频通话')
  assert.match(t.pushes[0].link, /^\/\?chat=.+&call=c1$/)
  assert.deepEqual(t.kinds(t.ids.a), ['notified'])
})

test('a callee with no app open and no notifications is reported unreachable', async () => {
  const t = setup({ online: ['a'] })
  t.broker.signal(t.ids.a, { t: 'call', kind: 'invite', room: t.room, callId: 'c1', media: 'audio' })
  await tick()
  assert.deepEqual(t.kinds(t.ids.a), ['unreachable'])
})

test('an open app that never says it rings gets the notification a moment later', async () => {
  const t = setup({ subscribed: ['b'] })
  t.broker.signal(t.ids.a, { t: 'call', kind: 'invite', room: t.room, callId: 'c1', media: 'audio' })
  await t.broker.alert(t.room, 'c1', { wait: 0 })
  assert.equal(t.pushes.length, 1)
})

test('the callee going to the background keeps the call ringing; coming back rings again', async () => {
  const t = setup({ subscribed: ['b'] })
  t.broker.signal(t.ids.a, { t: 'call', kind: 'invite', room: t.room, callId: 'c1', media: 'audio' })
  t.broker.signal(t.ids.b, { t: 'call', kind: 'ringing', room: t.room, callId: 'c1' })
  t.sockets.delete(t.ids.b)
  t.broker.onDisconnect(t.ids.b)
  await tick()
  assert.ok(!t.kinds(t.ids.a).includes('hangup'), 'the caller is not hung up on')
  assert.equal(t.pushes.length, 1, 'rung by notification instead')
  t.sockets.add(t.ids.b)
  t.broker.onConnect(t.ids.b)
  assert.deepEqual(t.kinds(t.ids.b), ['invite', 'invite'])
  t.broker.signal(t.ids.b, { t: 'call', kind: 'accept', room: t.room, callId: 'c1' })
  assert.ok(t.kinds(t.ids.a).includes('accept'))
})

test('the call survives the Durable Object being rebuilt', () => {
  const t = setup()
  t.broker.signal(t.ids.a, { t: 'call', kind: 'invite', room: t.room, callId: 'c1', media: 'audio' })
  const fresh = new CallBroker({ ...t.broker.hub })
  assert.equal(fresh.get(t.room).callId, 'c1')
})

test('the caller leaving ends it; a missed call tells those notified', async () => {
  const t = setup({ online: ['a'], subscribed: ['b'] })
  t.broker.signal(t.ids.a, { t: 'call', kind: 'invite', room: t.room, callId: 'c1', media: 'audio' })
  await tick()
  t.broker.signal(t.ids.a, { t: 'call', kind: 'cancel', room: t.room, callId: 'c1', media: 'audio', missed: true })
  await tick()
  assert.equal(t.broker.get(t.room), null)
  assert.equal(t.pushes.at(-1).body, '未接语音通话')
  assert.equal(t.store.lastMessage(t.room).body, '未接语音通话')
})

test('a decline that timed out reaches the caller as missed', () => {
  const t = setup()
  t.broker.signal(t.ids.a, { t: 'call', kind: 'invite', room: t.room, callId: 'c1', media: 'audio' })
  t.broker.signal(t.ids.b, { t: 'call', kind: 'decline', room: t.room, callId: 'c1', missed: true })
  const decline = t.sent.find(m => m.to === t.ids.a && m.kind === 'decline')
  assert.equal(decline.missed, true)
})

test('tracks published before someone joins reach them when they accept', () => {
  const t = setup()
  t.broker.signal(t.ids.a, { t: 'call', kind: 'invite', room: t.room, callId: 'c1', media: 'audio' })
  t.broker.signal(t.ids.a, { t: 'call', kind: 'tracks', room: t.room, callId: 'c1', sessionId: 'sa', tracks: ['a-audio'] })
  t.broker.signal(t.ids.b, { t: 'call', kind: 'accept', room: t.room, callId: 'c1' })
  const replay = t.sent.filter(m => m.to === t.ids.b && m.kind === 'tracks')
  assert.equal(replay.length, 2, 'once as published, once more on joining')
  assert.deepEqual({ from: replay[1].from, sessionId: replay[1].sessionId, tracks: replay[1].tracks }, { from: t.ids.a, sessionId: 'sa', tracks: ['a-audio'] })
  // Malformed announcements go nowhere.
  t.broker.signal(t.ids.a, { t: 'call', kind: 'tracks', room: t.room, callId: 'c1', sessionId: 'sa', tracks: 'a-audio' })
  assert.equal(t.sent.filter(m => m.kind === 'tracks').length, 2)
  // Someone leaving takes their publication with them.
  t.broker.signal(t.ids.a, { t: 'call', kind: 'hangup', room: t.room, callId: 'c1' })
  assert.equal(t.broker.get(t.room)?.published?.[t.ids.a], undefined)
})

/** Runs the media proxy against a stand-in for the Realtime API. */
async function proxy(path, { method = 'POST', body, env = {}, answer = { status: 201, json: { sessionId: 's1' } } } = {}) {
  const t = setup()
  t.broker.env.REALTIME_APP_ID = 'app-1'
  t.broker.env.REALTIME_APP_SECRET = 'secret-1\n'
  Object.assign(t.broker.env, env)
  const calls = []
  const real = globalThis.fetch
  globalThis.fetch = async (url, init) => {
    calls.push({ url, ...init })
    if (answer.offline) throw new TypeError('fetch failed')
    return new Response(JSON.stringify(answer.json), { status: answer.status })
  }
  try {
    const request = new Request(`https://duo.test${path}`, { method, body: body === undefined ? undefined : JSON.stringify(body) })
    const res = await t.broker.http(request, new URL(request.url), {})
    return { calls, status: res.status, data: await res.json() }
  } finally {
    globalThis.fetch = real
  }
}

test('a session is created with no body, as the SFU requires', async () => {
  const r = await proxy('/rtc/sessions/new', { body: {} })
  assert.equal(r.status, 201)
  assert.equal(r.data.sessionId, 's1')
  assert.equal(r.calls.length, 1)
  assert.equal(r.calls[0].url, 'https://rtc.live.cloudflare.com/v1/apps/app-1/sessions/new')
  assert.equal(r.calls[0].body, undefined)
  assert.equal(r.calls[0].headers.Authorization, 'Bearer secret-1')
})

test('a refusal from the SFU keeps its status and public code, and says which side to look at', async () => {
  const r = await proxy('/rtc/sessions/s1/tracks/new', {
    body: { tracks: [{ location: 'remote', sessionId: 's0', trackName: 'a-audio' }] },
    answer: { status: 400, json: { errorCode: 'invalid_params', errorDescription: 'v=0 o=- secret sdp' } }
  })
  assert.equal(r.status, 400)
  assert.equal(r.data.code, 'invalid_params')
  assert.equal(r.data.reason, 'RTC_NEGOTIATION')
  assert.equal(r.data.error, '通话连接没能建立，请重新拨打')
  assert.ok(!JSON.stringify(r.data).includes('sdp'), 'the service\'s own description stays on the server')
})

test('each kind of refusal gets its own reason and plain words', async () => {
  const cases = [
    ['/rtc/sessions/new', { status: 401, json: { errorCode: 'unauthorized' } }, 401, 'RTC_AUTH', '通话服务配置有误，暂时无法通话'],
    ['/rtc/sessions/new', { status: 404, json: {} }, 404, 'RTC_APP', '通话服务配置有误，暂时无法通话'],
    ['/rtc/sessions/s1/renegotiate', { status: 404, json: {} }, 404, 'RTC_GONE', '这次通话已失效，请重新拨打'],
    ['/rtc/sessions/new', { status: 429, json: {} }, 429, 'RTC_BUSY', '通话请求太频繁，请稍后再试'],
    ['/rtc/sessions/s1/renegotiate', { status: 200, json: { errorCode: 'session_error', errorDescription: 'x' } }, 502, 'RTC_MEDIA', '对方的声音或画面还没准备好，请重新拨打'],
    ['/rtc/sessions/new', { status: 500, json: {} }, 500, 'RTC_SERVICE', '通话服务暂时不可用，请稍后再试']
  ]
  for (const [path, answer, status, reason, error] of cases) {
    const r = await proxy(path, { method: path.endsWith('renegotiate') ? 'PUT' : 'POST', body: path.endsWith('renegotiate') ? { sessionDescription: { type: 'answer', sdp: 'v=0' } } : undefined, answer })
    assert.deepEqual([r.status, r.data.reason, r.data.error], [status, reason, error], `${path} ${answer.status}`)
  }
  const offline = await proxy('/rtc/sessions/new', { answer: { offline: true } })
  assert.equal(offline.status, 504)
})

test('secrets that are only spaces count as not set', () => {
  const t = setup()
  t.broker.env.REALTIME_APP_ID = '  '
  t.broker.env.REALTIME_APP_SECRET = 'secret\n'
  assert.equal(t.broker.configured().enabled, false)
  t.broker.env.REALTIME_APP_ID = ' app-1\n'
  assert.equal(t.broker.configured().enabled, true)
})

test('TURN comes from the current endpoint as a checked list, and falls back to STUN', async () => {
  const env = { REALTIME_TURN_KEY_ID: 'key-1\n', REALTIME_TURN_KEY_TOKEN: ' token-1 ' }
  const servers = [
    { urls: ['stun:stun.cloudflare.com:3478', 'stun:stun.cloudflare.com:53'] },
    { urls: ['turn:turn.cloudflare.com:3478?transport=udp', 'turn:turn.cloudflare.com:53?transport=udp', 'turns:turn.cloudflare.com:443?transport=tcp'], username: 'u', credential: 'c' },
    { urls: ['https://not-ice.example'] }
  ]
  const ok = await proxy('/rtc/turn', { env, answer: { status: 201, json: { iceServers: servers } } })
  assert.equal(ok.calls[0].url, 'https://rtc.live.cloudflare.com/v1/turn/keys/key-1/credentials/generate-ice-servers')
  assert.equal(ok.calls[0].headers.Authorization, 'Bearer token-1')
  assert.deepEqual(ok.data.iceServers, [
    { urls: ['stun:stun.cloudflare.com:3478'] },
    { urls: ['turn:turn.cloudflare.com:3478?transport=udp', 'turns:turn.cloudflare.com:443?transport=tcp'], username: 'u', credential: 'c' }
  ], 'a flat list, port 53 and non-ICE addresses left out')

  const older = await proxy('/rtc/turn', { env, answer: { status: 201, json: { iceServers: { urls: ['turn:turn.cloudflare.com:3478'], username: 'u', credential: 'c' } } } })
  assert.equal(older.data.iceServers.length, 1, 'the older single-server shape still reads')

  const stun = [{ urls: 'stun:stun.cloudflare.com:3478' }]
  for (const answer of [{ status: 401, json: { errors: [{ message: 'bad token' }] } }, { status: 201, json: { iceServers: [{ urls: 'nope' }] } }, { offline: true }]) {
    const r = await proxy('/rtc/turn', { env, answer })
    assert.deepEqual([r.status, r.data.iceServers], [200, stun], JSON.stringify(answer))
  }
  assert.deepEqual((await proxy('/rtc/turn')).data.iceServers, stun, 'none configured')
})

test('track batches the SFU would refuse never leave the server', async () => {
  for (const tracks of [undefined, [], [{ location: 'local', trackName: 'x' }], [{ location: 'local', mid: '0', trackName: 'x' }, { location: 'remote', sessionId: 's', trackName: 'y' }]]) {
    const r = await proxy('/rtc/sessions/s1/tracks/new', { body: { tracks } })
    assert.equal(r.status, 400, JSON.stringify(tracks))
    assert.equal(r.calls.length, 0)
  }
  const ok = await proxy('/rtc/sessions/s1/tracks/new', {
    body: { sessionDescription: { type: 'offer', sdp: 'v=0' }, tracks: [{ location: 'local', mid: '0', trackName: 'a-audio' }] },
    answer: { status: 200, json: { sessionDescription: { type: 'answer', sdp: 'v=0' }, tracks: [{ mid: '0', trackName: 'a-audio' }] } }
  })
  assert.equal(ok.status, 200)
  assert.equal(JSON.parse(ok.calls[0].body).tracks[0].mid, '0')
})

test('declarative push message format', () => {
  const m = declarativeMessage({ title: '小禾', body: '你好', navigate: 'https://duo.example/?chat=r1', tag: 'r1', badge: 3 })
  assert.equal(m.web_push, 8030)
  assert.deepEqual(m.notification, { title: '小禾', body: '你好', navigate: 'https://duo.example/?chat=r1', lang: 'zh-CN', dir: 'ltr', silent: false, tag: 'r1', app_badge: '3' })
  assert.equal('app_badge' in declarativeMessage({ title: 't', navigate: 'https://x.example/' }).notification, false)
})

/** A fake clock and storage alarm: advance() fires the alarm once it's due. */
function fakeClock() {
  let now = 1000
  const c = {
    alarm: null,
    armed: [],
    broker: null,
    opts: {
      graceMs: 15000,
      now: () => now,
      setAlarm: at => { c.alarm = at; c.armed.push(at) },
      deleteAlarm: () => { c.alarm = null }
    },
    advance(ms) {
      now += ms
      while (c.alarm !== null && c.alarm <= now) { c.alarm = null; c.broker.settle() }
    },
    pending: () => c.alarm !== null
  }
  return c
}
function inCall(clock, setupOpts) {
  const t = setup(setupOpts)
  t.broker = clock.broker = new CallBroker(t.broker.hub, clock.opts)
  t.broker.signal(t.ids.a, { t: 'call', kind: 'invite', room: t.room, callId: 'c1', media: 'audio' })
  t.broker.signal(t.ids.b, { t: 'call', kind: 'accept', room: t.room, callId: 'c1' })
  t.sent.length = 0
  return t
}

test('a participant who drops off is not hung up on at once; the other hears the line is shaky', () => {
  const clock = fakeClock()
  const t = inCall(clock)
  t.sockets.delete(t.ids.a)
  t.broker.onDisconnect(t.ids.a)
  assert.deepEqual(t.kinds(t.ids.b), ['unstable'])
  assert.equal(clock.alarm, 1000 + 15000, 'the alarm is set for the deadline')
  clock.advance(14000)
  assert.ok(!t.kinds(t.ids.b).includes('hangup'))
  assert.deepEqual(t.broker.get(t.room).participants, [t.ids.a, t.ids.b])
})

test('coming back within the grace period keeps the call, clears the alarm, and the other hears so', () => {
  const clock = fakeClock()
  const t = inCall(clock)
  t.sockets.delete(t.ids.a)
  t.broker.onDisconnect(t.ids.a)
  clock.advance(3000)
  t.sockets.add(t.ids.a)
  t.broker.onConnect(t.ids.a)
  assert.equal(clock.pending(), false)
  t.broker.signal(t.ids.a, { t: 'call', kind: 'check', room: t.room, callId: 'c1' })
  assert.deepEqual(t.kinds(t.ids.a), ['alive'])
  clock.advance(20000)
  assert.deepEqual(t.kinds(t.ids.b), ['unstable', 'back'])
  assert.ok(t.broker.get(t.room).participants.includes(t.ids.a))
})

test('the alarm going off hangs up, and a late check hears the call is gone', () => {
  const clock = fakeClock()
  const t = inCall(clock)
  t.sockets.delete(t.ids.a)
  t.broker.onDisconnect(t.ids.a)
  clock.advance(15000)
  assert.deepEqual(t.kinds(t.ids.b), ['unstable', 'hangup'])
  assert.equal(t.sent.find(m => m.kind === 'hangup').reason, 'lost', 'the other hears it was the network')
  assert.equal(t.broker.get(t.room), null, 'alone in it, the call is over')
  assert.equal(clock.pending(), false)
  t.sockets.add(t.ids.a)
  t.broker.onConnect(t.ids.a)
  t.broker.signal(t.ids.a, { t: 'call', kind: 'check', room: t.room, callId: 'c1' })
  assert.deepEqual(t.kinds(t.ids.a), ['gone'])
})

test('with several deadlines the alarm settles the earliest and re-arms for the next', () => {
  const clock = fakeClock()
  const t = inCall(clock)
  const c = t.store.createUser({ username: 'carol', display: 'C', salt: 's', hash: 'h' }).id
  // A second call in another room, dropping later.
  const room2 = t.store.getOrCreateDM(t.ids.b, c)
  t.sockets.add(c)
  t.broker.signal(c, { t: 'call', kind: 'invite', room: room2, callId: 'c2', media: 'audio' })
  t.broker.signal(t.ids.b, { t: 'call', kind: 'accept', room: room2, callId: 'c2' })
  t.sockets.delete(t.ids.a)
  t.broker.onDisconnect(t.ids.a)
  clock.advance(5000)
  t.sockets.delete(c)
  t.broker.onDisconnect(c)
  assert.equal(clock.alarm, 16000, 'earliest deadline first')
  clock.advance(10000)
  assert.equal(t.broker.get(t.room), null)
  assert.equal(clock.alarm, 21000, 're-armed for the next')
  assert.ok(t.broker.get(room2).participants.includes(c))
  clock.advance(5000)
  assert.equal(t.broker.get(room2), null)
  assert.equal(clock.pending(), false)
})

test('a deadline whose alarm was missed is settled on the next connect', () => {
  const clock = fakeClock()
  const t = inCall(clock)
  t.sockets.delete(t.ids.a)
  t.broker.onDisconnect(t.ids.a)
  clock.alarm = null // the alarm never ran
  clock.advance(16000)
  t.broker.onConnect(t.ids.b)
  assert.ok(t.kinds(t.ids.b).includes('hangup'))
})

test('hanging up on purpose still ends the call at once', () => {
  const clock = fakeClock()
  const t = inCall(clock)
  t.broker.signal(t.ids.a, { t: 'call', kind: 'hangup', room: t.room, callId: 'c1', media: 'audio', duration: 5 })
  assert.deepEqual(t.kinds(t.ids.b), ['hangup'])
  assert.equal(clock.pending(), false)
})

test('the other hanging up during the grace period ends the call at once, recorded once; the one back hears it is gone', () => {
  const clock = fakeClock()
  const t = inCall(clock)
  t.broker.signal(t.ids.a, { t: 'call', kind: 'accept', room: t.room, callId: 'c1' }) // no-op for the caller
  t.sockets.delete(t.ids.a)
  t.broker.onDisconnect(t.ids.a)
  clock.advance(4000)
  t.broker.signal(t.ids.b, { t: 'call', kind: 'hangup', room: t.room, callId: 'c1', media: 'audio', duration: 7 })
  assert.equal(t.broker.get(t.room), null, 'dropped, not left waiting for A')
  assert.equal(clock.pending(), false, 'alarm cleared')
  const rec = t.store.lastMessage(t.room)
  assert.equal(rec.type, 'call')
  assert.equal(rec.meta.duration, 7)
  t.sockets.add(t.ids.a)
  t.broker.onConnect(t.ids.a)
  t.broker.signal(t.ids.a, { t: 'call', kind: 'check', room: t.room, callId: 'c1' })
  assert.deepEqual(t.kinds(t.ids.a), ['gone'])
  t.broker.signal(t.ids.a, { t: 'call', kind: 'hangup', room: t.room, callId: 'c1', media: 'audio', duration: 3 })
  assert.equal(t.store.lastMessage(t.room).id, rec.id, 'the late hang-up is not recorded again')
})

test('the grace period running out writes the call record, and the hang-up the other sends after is not recorded twice', () => {
  const clock = fakeClock()
  const t = inCall(clock)
  t.sockets.delete(t.ids.a)
  t.broker.onDisconnect(t.ids.a)
  clock.advance(15000)
  const rec = t.store.lastMessage(t.room)
  assert.equal(rec?.type, 'call')
  assert.equal(rec.meta.media, 'audio')
  assert.equal(rec.meta.duration, 15)
  t.broker.signal(t.ids.b, { t: 'call', kind: 'hangup', room: t.room, callId: 'c1', media: 'audio', duration: 15 })
  assert.equal(t.store.lastMessage(t.room).id, rec.id)
})

test('in a group, a check is alive while one other is still really in the call', () => {
  const clock = fakeClock()
  const t = inCall(clock)
  const c = t.store.createUser({ username: 'carol', display: 'C', salt: 's', hash: 'h' }).id
  t.sockets.add(c)
  const call = t.broker.get(t.room)
  call.participants.push(c) // a third already in it
  t.broker.put(t.room, call)
  t.sockets.delete(t.ids.a)
  t.broker.onDisconnect(t.ids.a)
  t.sockets.delete(c)
  t.broker.onDisconnect(c)
  clock.advance(3000)
  t.sockets.add(t.ids.a)
  t.broker.signal(t.ids.a, { t: 'call', kind: 'check', room: t.room, callId: 'c1' })
  assert.deepEqual(t.kinds(t.ids.a), ['alive', 'unstable'], 'B is still there; C is still away')
  // B leaving now leaves only C, who is away: over.
  t.broker.signal(t.ids.b, { t: 'call', kind: 'hangup', room: t.room, callId: 'c1', media: 'audio', duration: 4 })
  assert.deepEqual(t.broker.get(t.room).participants, [t.ids.a, c], 'A is present, so it goes on')
  t.broker.signal(t.ids.a, { t: 'call', kind: 'hangup', room: t.room, callId: 'c1', media: 'audio', duration: 5 })
  assert.equal(t.broker.get(t.room), null, 'only away people left: dropped')
  assert.equal(clock.pending(), false)
})

test('someone dropping while another is still being rung: the hang-up says the call goes on', () => {
  const clock = fakeClock()
  const t = inCall(clock)
  const c = t.store.createUser({ username: 'carol', display: 'C', salt: 's', hash: 'h' }).id
  t.sockets.add(c)
  const call = t.broker.get(t.room)
  call.ringing.push(c) // a third still being rung
  t.broker.put(t.room, call)
  t.sockets.delete(t.ids.b)
  t.broker.onDisconnect(t.ids.b)
  clock.advance(15000)
  const lost = t.sent.filter(m => m.kind === 'hangup' && m.reason === 'lost')
  assert.ok(lost.length >= 1)
  assert.ok(lost.every(m => m.ongoing === true), 'A and C hear it goes on')
  assert.ok(t.broker.get(t.room), 'C still rings: not over')
  // The caller (A) hanging up too.
  t.broker.signal(t.ids.a, { t: 'call', kind: 'hangup', room: t.room, callId: 'c1', media: 'audio', duration: 5 })
  assert.equal(t.broker.get(t.room), null, 'the caller gone with nobody else in it: over, the ring stops with it')
})

test('alone in a call when the other drops: the hang-up says it is over', () => {
  const clock = fakeClock()
  const t = inCall(clock)
  t.sockets.delete(t.ids.a)
  t.broker.onDisconnect(t.ids.a)
  clock.advance(15000)
  assert.equal(t.sent.find(m => m.kind === 'hangup').ongoing, false)
})

test('the caller hanging up on one person while another still rings ends it, recorded once', () => {
  const clock = fakeClock()
  const t = inCall(clock)
  const c = t.store.createUser({ username: 'carol', display: 'C', salt: 's', hash: 'h' }).id
  t.sockets.add(c)
  const call = t.broker.get(t.room)
  call.ringing.push(c)
  t.broker.put(t.room, call)
  t.broker.signal(t.ids.a, { t: 'call', kind: 'hangup', room: t.room, callId: 'c1', media: 'audio', duration: 6 })
  assert.equal(t.broker.get(t.room), null, 'B is not left alone in it')
  assert.equal(t.sent.filter(m => m.kind === 'hangup' && m.to === t.ids.b).at(-1).ongoing, false)
  const records = () => t.store.listMessages(t.room, { limit: 50 }).filter(m => m.type === 'call').length
  const n = records()
  assert.equal(n, 1, 'one record')
  t.broker.signal(t.ids.b, { t: 'call', kind: 'hangup', room: t.room, callId: 'c1', media: 'audio', duration: 6 })
  assert.equal(records(), n, 'B hanging up afterwards is not recorded again')
})

test('a group call down to one person after a hang-up is over, recorded once', () => {
  const t = setup()
  const c = t.store.createUser({ username: 'carol', display: 'C', salt: 's', hash: 'h' }).id
  t.sockets.add(c)
  const g = t.store.createGroup({ name: 'G', creator: t.ids.a, members: [t.ids.b, c] })
  const room = g.id ?? g
  t.broker.signal(t.ids.a, { t: 'call', kind: 'invite', room, callId: 'g1', media: 'audio' })
  t.broker.signal(t.ids.b, { t: 'call', kind: 'accept', room, callId: 'g1' })
  t.broker.signal(c, { t: 'call', kind: 'accept', room, callId: 'g1' })
  t.broker.signal(t.ids.a, { t: 'call', kind: 'hangup', room, callId: 'g1', media: 'audio', duration: 3 })
  assert.ok(t.broker.get(room), 'B and C go on')
  t.sent.length = 0
  t.broker.signal(t.ids.b, { t: 'call', kind: 'hangup', room, callId: 'g1', media: 'audio', duration: 4 })
  assert.equal(t.broker.get(room), null, 'C alone: over')
  assert.equal(t.sent.find(m => m.kind === 'hangup' && m.to === c).ongoing, false)
  t.broker.signal(c, { t: 'call', kind: 'hangup', room, callId: 'g1', media: 'audio', duration: 4 })
  assert.equal(t.store.listMessages(room, { limit: 50 }).filter(m => m.type === 'call').length, 1)
})

function groupCall(clock) {
  const t = setup()
  t.broker = clock.broker = new CallBroker(t.broker.hub, clock.opts)
  const c = t.store.createUser({ username: 'carol', display: 'C', salt: 's', hash: 'h' }).id
  t.sockets.add(c)
  const g = t.store.createGroup({ name: 'G', creator: t.ids.a, members: [t.ids.b, c] })
  const room = g.id ?? g
  t.broker.signal(t.ids.a, { t: 'call', kind: 'invite', room, callId: 'g1', media: 'audio' })
  t.broker.signal(t.ids.b, { t: 'call', kind: 'accept', room, callId: 'g1' })
  t.broker.signal(c, { t: 'call', kind: 'accept', room, callId: 'g1' })
  t.sent.length = 0
  return { t, c, room }
}

test('a group call is not over while the second-to-last person is only reconnecting; it is once they time out', () => {
  const clock = fakeClock()
  const { t, c, room } = groupCall(clock)
  t.sockets.delete(t.ids.b)
  t.broker.onDisconnect(t.ids.b)
  t.broker.signal(c, { t: 'call', kind: 'hangup', room, callId: 'g1', media: 'audio', duration: 3 })
  assert.ok(t.broker.get(room), 'B is in the grace period: A and B go on')
  assert.equal(t.sent.find(m => m.kind === 'hangup' && m.to === t.ids.a).ongoing, true)
  clock.advance(15000)
  assert.equal(t.broker.get(room), null, 'B never came back: A alone, over')
  assert.equal(t.sent.filter(m => m.kind === 'hangup' && m.to === t.ids.a).at(-1).ongoing, false)
  assert.equal(t.store.listMessages(room, { limit: 50 }).filter(m => m.type === 'call').length, 1)
})

test('the caller hanging up while another still rings does not end it if someone is only reconnecting', () => {
  const clock = fakeClock()
  const t = inCall(clock)
  const c = t.store.createUser({ username: 'carol', display: 'C', salt: 's', hash: 'h' }).id
  const d = t.store.createUser({ username: 'dave', display: 'D', salt: 's', hash: 'h' }).id
  t.sockets.add(c)
  t.sockets.add(d)
  const call = t.broker.get(t.room)
  call.participants.push(c)
  call.ringing.push(d)
  t.broker.put(t.room, call)
  t.sockets.delete(c)
  t.broker.onDisconnect(c)
  t.broker.signal(t.ids.a, { t: 'call', kind: 'hangup', room: t.room, callId: 'c1', media: 'audio', duration: 6 })
  assert.ok(t.broker.get(t.room), 'C is reconnecting: B is not alone')
  clock.advance(15000)
  assert.equal(t.broker.get(t.room), null, 'C timed out: B alone with the caller gone, over')
  assert.equal(t.sent.filter(m => m.kind === 'hangup' && m.to === t.ids.b).at(-1).ongoing, false)
})
