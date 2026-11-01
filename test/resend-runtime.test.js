import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { Miniflare, convertV4MiniflareOptions } from 'miniflare'

// A hub that can be stopped and started again on the same storage, the way a
// Durable Object is evicted and comes back while a phone is reconnecting.
async function hub(name) {
  const bundled = await build({
    entryPoints: [fileURLToPath(new URL('../src/index.js', import.meta.url))],
    bundle: true, write: false, format: 'esm', platform: 'browser'
  })
  const persistence = await mkdtemp(join(tmpdir(), `duo-${name}-`))
  const start = () => new Miniflare(convertV4MiniflareOptions({
    name: `duo-${name}-test`,
    modules: true,
    compatibilityDate: '2026-10-01',
    resourcePersistencePath: persistence,
    script: bundled.outputFiles[0].text,
    durableObjects: { HUB: { className: 'Hub', useSQLite: true } },
    r2Buckets: ['MEDIA']
  }))
  let mf = start()
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
  const upload = async (query, bytes, session) => {
    const response = await mf.dispatchFetch(`${origin}/api/media/upload?${new URLSearchParams(query)}`, {
      method: 'POST', body: bytes,
      headers: { origin, cookie: session, 'content-type': 'image/png', 'content-length': String(bytes.length) }
    })
    return { response, data: await response.json() }
  }
  const media = async (path, session) => {
    const response = await mf.dispatchFetch(origin + path, { headers: { origin, cookie: session } })
    return { status: response.status, bytes: new Uint8Array(await response.arrayBuffer()) }
  }
  const restart = async () => { await mf.dispose(); mf = start() }
  const dispose = async () => { await mf.dispose(); await rm(persistence, { recursive: true, force: true }) }
  return { request, register, upload, media, restart, dispose }
}

test('a send replayed with the same localId lands once, even across a hub restart; each sender has its own ids', async () => {
  const { request, register, restart, dispose } = await hub('resend')
  try {
    const a = await register('resend-a')
    const b = await register('resend-b')
    const room = (await request('/api/dm', { user: b.id }, a.cookie)).data.room.id
    const first = await request('/api/messages', { room, type: 'text', text: '到了吗', localId: 'L1' }, a.cookie)
    assert.equal(first.response.status, 200)
    // The answer was lost: the client sends it again.
    const again = await request('/api/messages', { room, type: 'text', text: '到了吗', localId: 'L1' }, a.cookie)
    assert.equal(again.data.msg.id, first.data.msg.id)
    assert.equal(again.data.repeat, true)
    // The hub went away meanwhile: it still remembers.
    await restart()
    const later = await request('/api/messages', { room, type: 'text', text: '到了吗', localId: 'L1' }, a.cookie)
    assert.equal(later.data.msg.id, first.data.msg.id)
    // The same localId from someone else, or in another room, is a message of its own.
    const fromB = await request('/api/messages', { room, type: 'text', text: '到了', localId: 'L1' }, b.cookie)
    assert.notEqual(fromB.data.msg.id, first.data.msg.id)
    const group = (await request('/api/group', { name: '别处', members: [b.id] }, a.cookie)).data.room.id
    const elsewhere = await request('/api/messages', { room: group, type: 'text', text: '到了吗', localId: 'L1' }, a.cookie)
    assert.notEqual(elsewhere.data.msg.id, first.data.msg.id)
    // No localId: every send is new.
    const x = await request('/api/messages', { room, type: 'text', text: '嗯' }, a.cookie)
    const y = await request('/api/messages', { room, type: 'text', text: '嗯' }, a.cookie)
    assert.notEqual(x.data.msg.id, y.data.msg.id)
    const list = (await request(`/api/messages?room=${room}&limit=50`, undefined, a.cookie)).data.messages
    assert.equal(list.filter(m => m.body === '到了吗' || m.text === '到了吗').length, 1, JSON.stringify(list.map(m => m.text ?? m.body)))
    // The client's key isn't part of what anyone reads back.
    assert.ok(list.every(m => !('localKey' in m) && !('local_key' in m)))
  } finally { await dispose() }
})

test('messages keep the order the hub took them in: strictly increasing times, pages never split a tie', async () => {
  const { request, register, dispose } = await hub('order')
  try {
    const a = await register('order-a')
    const b = await register('order-b')
    const room = (await request('/api/dm', { user: b.id }, a.cookie)).data.room.id
    // A burst, from both sides at once, within the same milliseconds.
    const sends = []
    for (let i = 0; i < 12; i++) sends.push(request('/api/messages', { room, type: 'text', text: `m${i}`, localId: `o${i}` }, i % 2 ? b.cookie : a.cookie))
    const sent = (await Promise.all(sends)).map(r => r.data.msg)
    const ts = sent.map(m => m.ts)
    assert.equal(new Set(ts).size, ts.length, 'no two messages share a time')
    // History reads back in the same order, whichever way it's paged.
    const all = (await request(`/api/messages?room=${room}&limit=50`, undefined, a.cookie)).data.messages
    const order = all.map(m => m.id)
    const sortedByTs = [...sent].sort((x, y) => x.ts - y.ts).map(m => m.id)
    assert.deepEqual(order.filter(id => sortedByTs.includes(id)), sortedByTs)
    const paged = []
    let before = Infinity
    for (;;) {
      const page = (await request(`/api/messages?room=${room}&limit=5${before !== Infinity ? `&before=${before}` : ''}`, undefined, a.cookie)).data.messages
      if (!page.length) break
      paged.unshift(...page.map(m => m.id))
      before = page[0].ts
    }
    assert.deepEqual(paged, order)
    // Sequential sends from one person always go up.
    let last = 0
    for (let i = 0; i < 5; i++) {
      const m = (await request('/api/messages', { room, type: 'text', text: `s${i}` }, a.cookie)).data.msg
      assert.ok(m.ts > last); last = m.ts
    }
  } finally { await dispose() }
})

test('a picture from the outbox, uploaded and sent again with its localId, is one object and one message', async () => {
  const { request, register, upload, media, restart, dispose } = await hub('picture')
  try {
    const a = await register('pic-a')
    const b = await register('pic-b')
    const room = (await request('/api/dm', { user: b.id }, a.cookie)).data.room.id
    const png = new Uint8Array([137, 80, 78, 71, 1, 2, 3, 4])
    const q = { kind: 'image', room, name: 'drawing.png', w: '2', h: '2', localId: 'P1' }
    const first = await upload(q, png, a.cookie)
    assert.equal(first.response.status, 200)
    // The answer was lost; after a hub restart the same upload comes again.
    await restart()
    const again = await upload(q, new Uint8Array([9, 9, 9]), a.cookie)
    assert.equal(again.data.url, first.data.url, 'same object, not a second copy')
    assert.equal(again.data.repeat, true)
    assert.deepEqual([...(await media(first.data.url, b.cookie)).bytes], [...png], 'what landed first is what stays')
    // The same localId from someone else is their own object.
    const other = await upload(q, png, b.cookie)
    assert.notEqual(other.data.url, first.data.url)
    // Without a localId (avatars, older clients) every upload is new.
    const x = await upload({ kind: 'image', room }, png, a.cookie)
    const y = await upload({ kind: 'image', room }, png, a.cookie)
    assert.notEqual(x.data.url, y.data.url)
    // An odd localId isn't used in the key.
    const odd = await upload({ kind: 'image', room, localId: '../x' }, png, a.cookie)
    assert.ok(!odd.data.key.includes('..'))
    // The message, sent twice with the same localId (a reply, as a drawing): one.
    const quoted = (await request('/api/messages', { room, type: 'text', text: '画一个', localId: 'T0' }, b.cookie)).data.msg.id
    const body = { room, type: 'drawing', meta: { ...first.data.meta, url: first.data.url }, localId: 'P1', replyTo: quoted }
    const m1 = await request('/api/messages', body, a.cookie)
    const m2 = await request('/api/messages', body, a.cookie)
    assert.equal(m2.data.msg.id, m1.data.msg.id)
    assert.equal(m2.data.repeat, true)
    const list = (await request(`/api/messages?room=${room}&limit=50`, undefined, a.cookie)).data.messages
    const drawings = list.filter(m => m.type === 'drawing')
    assert.equal(drawings.length, 1)
    assert.equal(drawings[0].replyTo, quoted, 'the reply is kept')
  } finally { await dispose() }
})
