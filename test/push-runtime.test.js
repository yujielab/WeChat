import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { Miniflare, convertV4MiniflareOptions } from 'miniflare'

// Push needs no setup: with no VAPID secrets the hub makes a key pair the
// first time and keeps it (across requests and restarts); secrets, when set,
// win.
test('the server serves a VAPID key with no setup, keeps it, and defers to secrets', async () => {
  const bundled = await build({
    entryPoints: [fileURLToPath(new URL('../src/index.js', import.meta.url))],
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'browser'
  })
  const persistence = await mkdtemp(join(tmpdir(), 'duo-push-'))
  const start = bindings => new Miniflare(convertV4MiniflareOptions({
    name: 'duo-push-test',
    modules: true,
    compatibilityDate: '2026-10-01',
    resourcePersistencePath: persistence,
    script: bundled.outputFiles[0].text,
    durableObjects: { HUB: { className: 'Hub', useSQLite: true } },
    r2Buckets: ['MEDIA'],
    bindings
  }))
  const origin = 'https://duo.test'
  const keyOf = async (mf, cookie) => {
    const r = await mf.dispatchFetch(origin + '/api/bootstrap', { headers: { origin, cookie } })
    return (await r.json()).vapid
  }

  let mf = start({})
  try {
    const reg = await mf.dispatchFetch(origin + '/auth/register', {
      method: 'POST',
      headers: { origin, 'content-type': 'application/json' },
      body: JSON.stringify({ username: 'push-a', password: 'hunter22' })
    })
    const cookie = reg.headers.get('set-cookie').split(';')[0]
    const first = await keyOf(mf, cookie)
    assert.match(first, /^[\w-]{87}$/, 'a P-256 public key, base64url')
    assert.equal(Buffer.from(first, 'base64url')[0], 4, 'an uncompressed point')
    assert.equal(await keyOf(mf, cookie), first, 'the same key every time')
    await mf.dispose()

    mf = start({})
    assert.equal(await keyOf(mf, cookie), first, 'kept across restarts')
    await mf.dispose()

    const set = 'BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8'
    mf = start({ VAPID_PUBLIC_KEY: set, VAPID_PRIVATE_KEY: 'yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw' })
    assert.equal(await keyOf(mf, cookie), set, 'secrets win')
  } finally {
    await mf.dispose()
    await rm(persistence, { recursive: true, force: true })
  }
})
