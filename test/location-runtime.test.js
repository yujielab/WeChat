import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { Miniflare, convertV4MiniflareOptions } from 'miniflare'

test('a shared place keeps its point, name and address; a bad one is refused; maps are off without a key', async () => {
  const bundled = await build({
    entryPoints: [fileURLToPath(new URL('../src/index.js', import.meta.url))],
    bundle: true, write: false, format: 'esm', platform: 'browser'
  })
  const persistence = await mkdtemp(join(tmpdir(), 'duo-location-'))
  const mf = new Miniflare(convertV4MiniflareOptions({
    name: 'duo-location-test', modules: true, compatibilityDate: '2026-10-01',
    resourcePersistencePath: persistence, script: bundled.outputFiles[0].text,
    durableObjects: { HUB: { className: 'Hub', useSQLite: true } }, r2Buckets: ['MEDIA']
  }))
  const origin = 'https://duo.test'
  const cookie = response => response.headers.get('set-cookie')?.split(';')[0]
  const request = async (path, body, session) => {
    const response = await mf.dispatchFetch(origin + path, {
      method: body !== undefined ? 'POST' : 'GET',
      redirect: 'manual',
      headers: { origin, ...(body !== undefined && { 'content-type': 'application/json' }), ...(session && { cookie: session }) },
      ...(body !== undefined && { body: JSON.stringify(body) })
    })
    const text = await response.text()
    let data = null
    try { data = JSON.parse(text) } catch {}
    return { response, data }
  }
  try {
    const a = await request('/auth/register', { username: 'place-a', password: 'hunter22' })
    const sa = cookie(a.response)
    const b = await request('/auth/register', { username: 'place-b', password: 'hunter22' })
    const room = (await request('/api/dm', { user: b.data.me.id }, sa)).data.room.id

    const text = '📍 The Bund\nHuangpu, Shanghai\nhttps://maps.apple.com/?ll=31.2304,121.4737&q=The%20Bund'
    const sent = await request('/api/messages', { room, type: 'location', text, caption: text,
      meta: { lat: 31.2304, lng: 121.4737, name: 'The Bund', address: 'Huangpu, Shanghai', extra: 'dropped' } }, sa)
    assert.equal(sent.response.status, 200, JSON.stringify(sent.data))
    assert.equal(sent.data.msg.type, 'location')
    assert.deepEqual(sent.data.msg.meta, { lat: 31.2304, lng: 121.4737, name: 'The Bund', address: 'Huangpu, Shanghai' })
    assert.equal(sent.data.msg.body, text)

    const bad = await request('/api/messages', { room, type: 'location', meta: { lat: 200, lng: 0 } }, sa)
    assert.equal(bad.response.status, 400)

    const boot = await request('/api/bootstrap', undefined, sa)
    assert.equal(boot.data.maps, false)
    const snap = await request('/api/map/snapshot?lat=31.2&lng=121.4', undefined, sa)
    assert.equal(snap.response.status, 404)
  } finally {
    await mf.dispose()
    await rm(persistence, { recursive: true, force: true })
  }
})
