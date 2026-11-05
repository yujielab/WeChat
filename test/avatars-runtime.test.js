// Photos used before (the avatar editor's 最近使用): a replaced avatar is kept
// to go back to, newest first, only the account's own, not the one in use.
import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { Miniflare, convertV4MiniflareOptions } from 'miniflare'

test('recent avatars: the one replaced is kept, newest first, a handful, each account its own', async () => {
  const bundled = await build({
    entryPoints: [fileURLToPath(new URL('../src/index.js', import.meta.url))],
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'browser'
  })
  const persistence = await mkdtemp(join(tmpdir(), 'duo-avatars-'))
  const mf = new Miniflare(convertV4MiniflareOptions({
    resourcePersistencePath: persistence,
    workers: [{
      name: 'duo-avatars-test',
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
    return { response, data }
  }
  const register = async username => {
    const r = await request('/auth/register', { username, password: 'hunter22' })
    return { cookie: r.response.headers.get('set-cookie').split(';')[0], id: r.data.me.id }
  }
  const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 16, 74, 70, 73, 70])
  const upload = async who => (await request('/api/media/upload?kind=avatar', undefined, who.cookie, { type: 'image/jpeg', raw: jpeg })).data.url
  const recent = async who => (await request('/api/profile/avatars', undefined, who.cookie)).data.recent

  try {
    const a = await register('av-a')
    const b = await register('av-b')
    assert.deepEqual(await recent(a), [], 'nothing yet')
    assert.equal((await request('/api/profile/avatars')).response.status, 401, 'signed in only')

    const first = await upload(a)
    await request('/api/profile', { avatar: first }, a.cookie)
    assert.deepEqual(await recent(a), [], 'the first replaced nothing')

    const second = await upload(a)
    await request('/api/profile', { avatar: second }, a.cookie)
    assert.deepEqual(await recent(a), [first], 'the one replaced')

    // Back to the first: the second is now the one to go back to, and the
    // one in use is never offered.
    await request('/api/profile', { avatar: first }, a.cookie)
    assert.deepEqual(await recent(a), [second])

    // Taken away: what was in use is kept too.
    await request('/api/profile', { avatar: '' }, a.cookie)
    assert.deepEqual(await recent(a), [first, second])

    // Only a handful, newest first.
    let last = ''
    for (let i = 0; i < 10; i++) { last = await upload(a); await request('/api/profile', { avatar: last }, a.cookie) }
    const kept = await recent(a)
    assert.equal(kept.length, 8, 'the last eight it replaced')
    assert.ok(!kept.includes(last))
    assert.ok(kept.every(u => u.startsWith(`/api/media/avatar/${a.id}/`)))

    // Someone else's photo can't be taken; each list is its own; a refused
    // change remembers nothing.
    assert.deepEqual(await recent(b), [])
    assert.equal((await request('/api/profile', { avatar: kept[0] }, b.cookie)).response.status, 400)
    assert.deepEqual(await recent(b), [])
    assert.equal((await request('/api/profile', { avatar: 'https://elsewhere.example/x.jpg' }, a.cookie)).response.status, 400)
    assert.deepEqual(await recent(a), kept, 'unchanged by a refused change')
  } finally {
    await mf.dispose()
    await rm(persistence, { recursive: true, force: true })
  }
})
