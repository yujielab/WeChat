import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { Miniflare, convertV4MiniflareOptions } from 'miniflare'

test('backdrops: a cover anyone sees, backdrops only their owner sees, the same on each device; marked unread', async () => {
  const bundled = await build({
    entryPoints: [fileURLToPath(new URL('../src/index.js', import.meta.url))],
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'browser'
  })
  const persistence = await mkdtemp(join(tmpdir(), 'duo-backdrops-'))
  const mf = new Miniflare(convertV4MiniflareOptions({
    resourcePersistencePath: persistence,
    workers: [{
      name: 'duo-backdrops-test',
      modules: true,
      compatibilityDate: '2026-10-01',
      script: bundled.outputFiles[0].text,
      durableObjects: { HUB: { className: 'Hub', useSQLite: true } },
      r2Buckets: ['MEDIA']
    }]
  }))
  const origin = 'https://duo.test'
  const request = async (path, body, session, { type = 'application/json', raw } = {}) => {
    const response = await mf.dispatchFetch(origin + path, {
      method: body !== undefined || raw ? 'POST' : 'GET',
      headers: { origin, ...((body !== undefined || raw) && { 'content-type': type }), ...(session && { cookie: session }) },
      ...(body !== undefined && { body: JSON.stringify(body) }),
      ...(raw && { body: raw })
    })
    const text = await response.text()
    let data = null
    try { data = JSON.parse(text) } catch {}
    return { response, data, text }
  }
  const register = async username => {
    const r = await request('/auth/register', { username, password: 'hunter22' })
    return { cookie: r.response.headers.get('set-cookie').split(';')[0], id: r.data.me.id }
  }
  const png = new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10])

  try {
    const a = await register('bg-a')
    const b = await register('bg-b')
    const room = (await request('/api/dm', { user: b.id }, a.cookie)).data.room.id

    // A cover: a preset, or a photo uploaded as one; visible to the other side.
    assert.equal((await request('/api/profile', { cover: 'preset:dawn' }, a.cookie)).data.me.cover, 'preset:dawn')
    const cover = (await request('/api/media/upload?kind=cover', undefined, a.cookie, { type: 'image/png', raw: png })).data.url
    assert.match(cover, new RegExp(`^/api/media/cover/${a.id}/`))
    assert.equal((await request('/api/profile', { cover }, a.cookie)).data.me.cover, cover)
    assert.equal((await request(cover, undefined, b.cookie)).response.status, 200, 'anyone may see a cover')
    assert.equal((await request(`/api/room/${room}`, undefined, b.cookie)).data.room.peer.cover, cover)
    assert.equal((await request('/api/profile', { cover: 'https://elsewhere.example/c.jpg' }, a.cookie)).response.status, 400)
    assert.equal((await request('/api/profile', { cover: `/api/media/cover/${b.id}/x` }, a.cookie)).response.status, 400, 'not someone else\'s')
    assert.equal((await request('/api/media/upload?kind=cover', undefined, a.cookie, { type: 'text/html', raw: '<b>x</b>' })).response.status, 400, 'pictures only')

    // A backdrop photo: only its owner can load it.
    const photo = (await request('/api/media/upload?kind=bg', undefined, a.cookie, { type: 'image/png', raw: png })).data.url
    assert.equal((await request(photo, undefined, a.cookie)).response.status, 200)
    assert.equal((await request(photo, undefined, b.cookie)).response.status, 403)

    // Chosen once, the same on every device: in the bootstrap and sent to the others.
    const ws = (await mf.dispatchFetch(`${origin}/api/ws`, { headers: { upgrade: 'websocket', origin, cookie: a.cookie } })).webSocket
    const got = []
    ws.accept()
    ws.addEventListener('message', e => got.push(JSON.parse(e.data)))
    const set = await request('/api/prefs', { chat: 'preset:mint', call: photo, rooms: { [room]: 'preset:night' } }, a.cookie)
    assert.deepEqual(set.data.prefs, { chat: 'preset:mint', call: photo, rooms: { [room]: 'preset:night' } })
    assert.deepEqual((await request('/api/bootstrap', undefined, a.cookie)).data.prefs, set.data.prefs)
    assert.deepEqual((await request('/api/bootstrap', undefined, b.cookie)).data.prefs, { chat: '', call: '', rooms: {} }, 'each their own')
    for (let i = 0; i < 20 && !got.some(m => m.t === 'prefs'); i++) await new Promise(r => setTimeout(r, 25))
    assert.deepEqual(got.find(m => m.t === 'prefs')?.prefs, set.data.prefs)
    assert.equal((await request('/api/prefs', { chat: `/api/media/bg/${b.id}/x` }, a.cookie)).response.status, 400)
    assert.equal((await request('/api/prefs', { rooms: { nope: 'preset:mint' } }, a.cookie)).response.status, 400)
    assert.deepEqual((await request('/api/prefs', { rooms: { [room]: '' } }, a.cookie)).data.prefs.rooms, {})

    // Marked unread: counted until read.
    await request(`/api/room/${room}/flags`, { unread: 1 }, a.cookie)
    let mine = (await request('/api/rooms', undefined, a.cookie)).data.rooms[0]
    assert.equal(mine.unread, 1)
    assert.equal(mine.marked, true)
    await request(`/api/room/${room}/read`, { ts: Date.now() }, a.cookie)
    mine = (await request('/api/rooms', undefined, a.cookie)).data.rooms[0]
    assert.equal(mine.unread, 0)
    ws.close()
  } finally {
    await mf.dispose()
    await rm(persistence, { recursive: true, force: true })
  }
})
