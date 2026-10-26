import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { Miniflare, convertV4MiniflareOptions } from 'miniflare'

test('workerd supports registration, login and password changes', async () => {
  // Node WebCrypto accepts iteration counts that Cloudflare rejects. Exercise
  // the real Worker and SQLite Hub instead of testing the crypto helpers alone.
  const bundled = await build({
    entryPoints: [fileURLToPath(new URL('../src/index.js', import.meta.url))],
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'browser'
  })
  const persistence = await mkdtemp(join(tmpdir(), 'duo-auth-'))
  const mf = new Miniflare(convertV4MiniflareOptions({
    name: 'duo-auth-test',
    modules: true,
    compatibilityDate: '2026-10-01',
    resourcePersistencePath: persistence,
    script: bundled.outputFiles[0].text,
    durableObjects: { HUB: { className: 'Hub', useSQLite: true } },
    r2Buckets: ['MEDIA']
  }))
  const origin = 'https://duo.test'
  const password = 'initial test password'
  const nextPassword = 'replacement test password'
  const username = 'runtime-user'
  const cookie = response => response.headers.get('set-cookie')?.split(';')[0]
  const request = async (path, body, session) => {
    const response = await mf.dispatchFetch(origin + path, {
      method: body ? 'POST' : 'GET',
      headers: {
        origin,
        ...(body && { 'content-type': 'application/json' }),
        ...(session && { cookie: session })
      },
      ...(body && { body: JSON.stringify(body) })
    })
    return { response, data: await response.json() }
  }

  try {
    const registered = await request('/auth/register', { username, password, display: 'Runtime User' })
    assert.equal(registered.response.status, 200, JSON.stringify(registered.data))
    assert.equal(registered.data.ok, true)
    const registeredCookie = cookie(registered.response)
    assert.match(registeredCookie, /^cfm_session=.+/)
    const status = await request('/auth/status', null, registeredCookie)
    assert.equal(status.data.authed, true)
    assert.equal(status.data.me.username, username)

    const logout = await request('/auth/logout', {}, registeredCookie)
    assert.equal(logout.response.status, 200)
    assert.match(logout.response.headers.get('set-cookie'), /Max-Age=0/)
    assert.equal((await request('/auth/status')).data.authed, false)
    assert.equal((await request('/auth/login', { username, password: 'wrong password' })).response.status, 401)

    const login = await request('/auth/login', { username, password })
    assert.equal(login.response.status, 200, JSON.stringify(login.data))
    assert.equal(login.data.me.id, registered.data.me.id)
    const oldCookie = cookie(login.response)
    const changed = await request('/api/password', { current: password, next: nextPassword }, oldCookie)
    assert.equal(changed.response.status, 200, JSON.stringify(changed.data))
    assert.equal((await request('/auth/status', null, cookie(changed.response))).data.authed, true)
    assert.equal((await request('/auth/status', null, oldCookie)).data.authed, false)
    assert.equal((await request('/auth/login', { username, password })).response.status, 401)
    const newLogin = await request('/auth/login', { username, password: nextPassword })
    assert.equal(newLogin.response.status, 200, JSON.stringify(newLogin.data))
    assert.equal(newLogin.data.me.id, registered.data.me.id)
  } finally {
    await mf.dispose()
    await rm(persistence, { recursive: true, force: true })
  }
})
