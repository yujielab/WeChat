// Read receipts with their time (src/hub.js markRead, src/store.js, src/prefs.js):
// reading a direct chat tells the friend how far and when ("Read 10:28"); reading
// it again doesn't move the time; turned off in Settings, the friend is told
// neither — not live, not in the chat list, not by replying.
import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { Miniflare, convertV4MiniflareOptions } from 'miniflare'

test('a read receipt carries when it was read, and turned off tells the friend nothing', async () => {
  const bundled = await build({
    entryPoints: [fileURLToPath(new URL('../src/index.js', import.meta.url))],
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'browser'
  })
  const persistence = await mkdtemp(join(tmpdir(), 'duo-receipts-'))
  const mf = new Miniflare(convertV4MiniflareOptions({
    resourcePersistencePath: persistence,
    workers: [{
      name: 'duo-receipts-test',
      modules: true,
      compatibilityDate: '2026-10-01',
      script: bundled.outputFiles[0].text,
      durableObjects: { HUB: { className: 'Hub', useSQLite: true } },
      r2Buckets: ['MEDIA']
    }]
  }))
  const origin = 'https://duo.test'
  const request = async (path, body, session) => {
    const response = await mf.dispatchFetch(origin + path, {
      method: body !== undefined ? 'POST' : 'GET',
      headers: { origin, ...(body !== undefined && { 'content-type': 'application/json' }), ...(session && { cookie: session }) },
      ...(body !== undefined && { body: JSON.stringify(body) })
    })
    return { response, data: await response.json() }
  }
  const register = async username => {
    const r = await request('/auth/register', { username, password: 'hunter22' })
    return { cookie: r.response.headers.get('set-cookie').split(';')[0], id: r.data.me.id }
  }
  const sleep = ms => new Promise(r => setTimeout(r, ms))
  const until = async (check, what) => {
    for (let i = 0; i < 60; i++) {
      const v = await check()
      if (v) return v
      await sleep(50)
    }
    assert.fail(what)
  }

  try {
    const a = await register('rc-a')
    const b = await register('rc-b')
    const room = (await request('/api/dm', { user: b.id }, a.cookie)).data.room.id
    const ws = (await mf.dispatchFetch(`${origin}/api/ws`, { headers: { upgrade: 'websocket', origin, cookie: a.cookie } })).webSocket
    const got = []
    ws.accept()
    ws.addEventListener('message', e => got.push(JSON.parse(e.data)))
    const row = async () => (await request('/api/rooms', undefined, a.cookie)).data.rooms.find(r => r.id === room)
    const reads = () => got.filter(m => m.t === 'read')

    // On by default: B reads, A learns how far and when.
    const one = (await request('/api/messages', { room, type: 'text', text: 'Are you there?' }, a.cookie)).data.msg
    assert.equal((await request('/api/bootstrap', undefined, b.cookie)).data.prefs.receipts, true, 'receipts are on by default')
    const before = Date.now()
    await request(`/api/room/${room}/read`, { ts: one.ts }, b.cookie)
    const event = await until(() => reads()[0], 'A is told it was read')
    assert.equal(event.ts, one.ts)
    assert.ok(event.at >= before && event.at <= Date.now(), 'with the time it was read')
    let r = await row()
    assert.deepEqual([r.peerRead, r.peerReadAt], [one.ts, event.at], 'and the chat list says the same')

    // Reading the same again: the time it was read stays.
    await sleep(20)
    await request(`/api/room/${room}/read`, { ts: one.ts }, b.cookie)
    await until(() => reads().length === 2, 'told again')
    assert.equal(reads()[1].at, event.at, 'the read time did not move')

    // Turned off: nothing more is told, and the list shows nothing read.
    assert.equal((await request('/api/prefs', { receipts: 'no' }, b.cookie)).response.status, 400, 'only true or false')
    const off = await request('/api/prefs', { receipts: false }, b.cookie)
    assert.equal(off.data.prefs.receipts, false)
    const two = (await request('/api/messages', { room, type: 'text', text: 'Hello?' }, a.cookie)).data.msg
    const told = reads().length
    await request(`/api/room/${room}/read`, { ts: two.ts }, b.cookie)
    await request('/api/messages', { room, type: 'text', text: 'Busy, later' }, b.cookie) // sending is reading, too
    await sleep(300)
    assert.equal(reads().length, told, 'no read receipt while it is off')
    r = await row()
    assert.deepEqual([r.peerRead, r.peerReadAt], [0, 0], 'the list shows neither how far nor when')

    // On again: from now on, as before.
    await request('/api/prefs', { receipts: true }, b.cookie)
    r = await row()
    assert.ok(r.peerRead >= two.ts && r.peerReadAt > 0, 'shown again once turned back on')
    ws.close()
  } finally {
    await mf.dispose()
    await rm(persistence, { recursive: true, force: true })
  }
})
