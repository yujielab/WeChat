import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { Miniflare, convertV4MiniflareOptions } from 'miniflare'

test('names, bios, avatars and bodies from clients are bounded and validated; retries are not duplicated', async () => {
  const bundled = await build({
    entryPoints: [fileURLToPath(new URL('../src/index.js', import.meta.url))],
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'browser'
  })
  const persistence = await mkdtemp(join(tmpdir(), 'duo-input-'))
  const mf = new Miniflare(convertV4MiniflareOptions({
    name: 'duo-input-test',
    modules: true,
    compatibilityDate: '2026-10-01',
    resourcePersistencePath: persistence,
    script: bundled.outputFiles[0].text,
    durableObjects: { HUB: { className: 'Hub', useSQLite: true } },
    r2Buckets: ['MEDIA']
  }))
  const origin = 'https://duo.test'
  const cookie = response => response.headers.get('set-cookie')?.split(';')[0]
  const request = async (path, body, session, raw) => {
    const response = await mf.dispatchFetch(origin + path, {
      method: body !== undefined ? 'POST' : 'GET',
      headers: {
        origin,
        ...(body !== undefined && { 'content-type': 'application/json' }),
        ...(session && { cookie: session })
      },
      ...(body !== undefined && { body: raw ? body : JSON.stringify(body) })
    })
    return { response, data: await response.json() }
  }

  try {
    // A display name is one line of at most 40 characters (emoji count as one).
    const long = `${'名'.repeat(30)}\n\u0000${'🙂'.repeat(30)}`
    const a = await request('/auth/register', { username: 'input-a', password: 'hunter22', display: long })
    assert.equal(a.response.status, 200, JSON.stringify(a.data))
    assert.equal(Array.from(a.data.me.display).length, 40)
    assert.doesNotMatch(a.data.me.display, /[\u0000-\u001f]/)
    const session = cookie(a.response)

    // Blank or non-text names fall back to the username.
    const b = await request('/auth/register', { username: 'input-b', password: 'hunter22', display: { toString: 1 } })
    assert.equal(b.data.me.display, 'input-b')
    const blank = await request('/api/profile', { display: '   ' }, session)
    assert.equal(blank.data.me.display, 'input-a')

    // Bios are bounded; fields left out keep their value.
    const bio = await request('/api/profile', { bio: 'x'.repeat(500) }, session)
    assert.equal(bio.data.me.bio.length, 120)
    assert.equal(bio.data.me.display, 'input-a')

    // Avatars are this account's own uploads, nothing else.
    const me = a.data.me.id
    for (const avatar of ['https://tracker.example/p.png', `/api/media/avatar/${b.data.me.id}/abc`, `/api/media/avatar/${me}/../x`, 42]) {
      const bad = await request('/api/profile', { avatar }, session)
      assert.equal(bad.response.status, 400, String(avatar))
    }
    const good = await request('/api/profile', { avatar: `/api/media/avatar/${me}/0123abcd` }, session)
    assert.equal(good.data.me.avatar, `/api/media/avatar/${me}/0123abcd`)
    const cleared = await request('/api/profile', { avatar: '' }, session)
    assert.equal(cleared.data.me.avatar, '')

    // A body that isn't an object is treated as empty, not a server error.
    for (const raw of ['null', '[1,2]', '"text"', '{']) {
      const odd = await request('/api/profile', raw, session, true)
      assert.equal(odd.response.status, 200, raw)
    }

    // Group names are bounded too; members must be real accounts.
    const group = await request('/api/group', { name: 'G'.repeat(200), members: [b.data.me.id, 7, null, 'nobody'] }, session)
    assert.equal(group.response.status, 200, JSON.stringify(group.data))
    assert.equal(group.data.room.name.length, 40)
    const info = await request(`/api/room/${group.data.room.id}`, undefined, session)
    assert.deepEqual(info.data.members.map(m => m.id).sort(), [me, b.data.me.id].sort())

    // A retry with the same localId (its first answer lost) gets the message
    // that landed, not a copy.
    const room = group.data.room.id
    const first = await request('/api/messages', { room, type: 'text', text: '只发一次', localId: 'retry-1' }, session)
    const again = await request('/api/messages', { room, type: 'text', text: '只发一次', localId: 'retry-1' }, session)
    assert.equal(again.data.msg.id, first.data.msg.id)
    const other = await request('/api/messages', { room, type: 'text', text: '只发一次', localId: 'retry-2' }, session)
    assert.notEqual(other.data.msg.id, first.data.msg.id)
    const history = await request(`/api/messages?room=${room}&limit=100`, undefined, session)
    assert.equal(history.data.messages.filter(m => m.body === '只发一次').length, 2)
  } finally {
    await mf.dispose()
    await rm(persistence, { recursive: true, force: true })
  }
})
