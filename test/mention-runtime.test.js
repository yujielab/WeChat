import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { Miniflare, convertV4MiniflareOptions } from 'miniflare'

test('group @mentions: only members are recorded, the list points at the first unread one, reading clears it', async () => {
  const bundled = await build({
    entryPoints: [fileURLToPath(new URL('../src/index.js', import.meta.url))],
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'browser'
  })
  const persistence = await mkdtemp(join(tmpdir(), 'duo-mention-'))
  const mf = new Miniflare(convertV4MiniflareOptions({
    name: 'duo-mention-test',
    modules: true,
    compatibilityDate: '2026-10-01',
    resourcePersistencePath: persistence,
    script: bundled.outputFiles[0].text,
    durableObjects: { HUB: { className: 'Hub', useSQLite: true } },
    r2Buckets: ['MEDIA']
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
  const row = async (who, room) => (await request('/api/rooms', undefined, who.cookie)).data.rooms.find(r => r.id === room)

  try {
    const a = await register('mention-a')
    const b = await register('mention-b')
    const c = await register('mention-c')
    const outsider = await register('mention-x')
    const room = (await request('/api/group', { name: '周末', members: [b.id, c.id] }, a.cookie)).data.room.id

    // Muted: a mention still has to get through (the push title says so; here, the list).
    await request(`/api/room/${room}/flags`, { muted: true }, b.cookie)

    await request('/api/messages', { room, type: 'text', text: '大家好' }, a.cookie)
    const sent = await request('/api/messages', {
      room, type: 'text', text: '@mention-b 你来订票',
      // Yourself, someone outside the group, junk and repeats are dropped.
      mentions: [b.id, b.id, a.id, outsider.id, 7, null]
    }, a.cookie)
    assert.equal(sent.response.status, 200, JSON.stringify(sent.data))
    assert.deepEqual(sent.data.msg.meta.mentions, [b.id])

    // A list put straight into meta by a client is not believed.
    const forged = await request('/api/messages', { room, type: 'text', text: '伪造', meta: { mentions: [c.id] } }, a.cookie)
    assert.equal(forged.data.msg.meta, null)

    // The list row points at the first unread mention, for B only.
    assert.equal((await row(b, room)).mention, sent.data.msg.id)
    assert.equal((await row(c, room)).mention, null)
    assert.equal((await row(a, room)).mention, null)

    // A later mention doesn't move it; reading clears it.
    await request('/api/messages', { room, type: 'text', text: '@mention-b 还有酒店', mentions: [b.id] }, c.cookie)
    assert.equal((await row(b, room)).mention, sent.data.msg.id)
    await request(`/api/room/${room}/read`, { ts: Date.now() + 1 }, b.cookie)
    assert.equal((await row(b, room)).mention, null)

    // Taken back, it no longer counts.
    const again = await request('/api/messages', { room, type: 'text', text: '@mention-c 看这里', mentions: [c.id] }, a.cookie)
    assert.equal((await row(c, room)).mention, again.data.msg.id)
    await request('/api/revoke', { id: again.data.msg.id }, a.cookie)
    assert.equal((await row(c, room)).mention, null)

    // Not in a one-to-one chat: there is no one to pick from.
    const dm = (await request('/api/dm', { user: b.id }, a.cookie)).data.room.id
    const plain = await request('/api/messages', { room: dm, type: 'text', text: '@mention-b', mentions: [b.id] }, a.cookie)
    assert.equal(plain.data.msg.meta, null)
  } finally {
    await mf.dispose()
    await rm(persistence, { recursive: true, force: true })
  }
})
