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

test('declarative push message format', () => {
  const m = declarativeMessage({ title: '小禾', body: '你好', navigate: 'https://duo.example/?chat=r1', tag: 'r1', badge: 3 })
  assert.equal(m.web_push, 8030)
  assert.deepEqual(m.notification, { title: '小禾', body: '你好', navigate: 'https://duo.example/?chat=r1', lang: 'zh-CN', dir: 'ltr', silent: false, tag: 'r1', app_badge: '3' })
  assert.equal('app_badge' in declarativeMessage({ title: 't', navigate: 'https://x.example/' }).notification, false)
})
