// Moments on the real Worker (src/hub.js, src/store.js, src/media.js): shared with friends — the people you
// talk to one to one and your contacts — and nobody else; photos and a video of your own; likes and comments
// that each viewer sees only from their own friends; and media only friends can load.
import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { Miniflare, convertV4MiniflareOptions } from 'miniflare'

test('moments: friends see them, strangers do not; likes and comments as each viewer may see them', async () => {
  const bundled = await build({ entryPoints: [fileURLToPath(new URL('../src/index.js', import.meta.url))], bundle: true, write: false, format: 'esm', platform: 'browser' })
  const persistence = await mkdtemp(join(tmpdir(), 'duo-moments-'))
  const mf = new Miniflare(convertV4MiniflareOptions({
    resourcePersistencePath: persistence,
    workers: [{ name: 'duo-moments-test', modules: true, compatibilityDate: '2026-10-01', script: bundled.outputFiles[0].text, durableObjects: { HUB: { className: 'Hub', useSQLite: true } }, r2Buckets: ['MEDIA'] }]
  }))
  const origin = 'https://duo.test'
  const request = async (path, body, session, { method, type = 'application/json', raw, headers = {} } = {}) => {
    const response = await mf.dispatchFetch(origin + path, {
      method: method || (body !== undefined || raw ? 'POST' : 'GET'),
      headers: { origin, ...((body !== undefined || raw) && { 'content-type': type }), ...(session && { cookie: session }), ...headers },
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
  const jpeg = new Uint8Array([0xff, 0xd8, 0xff, 0xe0, 0, 16, 74, 70, 73, 70, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10])
  const upload = async (who, type = 'image/jpeg', raw = jpeg) => request('/api/media/upload?kind=moment', undefined, who.cookie, { type, raw })

  try {
    const a = await register('mo-a'), b = await register('mo-b'), c = await register('mo-c'), d = await register('mo-d')
    // a talks with b and c one to one; b and c don't know each other; d knows nobody.
    await request('/api/dm', { user: b.id }, a.cookie)
    await request('/api/dm', { user: c.id }, a.cookie)

    // Photos of your own: a moment upload takes pictures and videos, nothing else.
    const photo = (await upload(a)).data.url
    assert.match(photo, new RegExp(`^/api/media/moment/${a.id}/`))
    assert.equal((await upload(a, 'video/mp4', new Uint8Array(4096))).response.status, 200, 'a video too')
    assert.equal((await upload(a, 'text/html', new TextEncoder().encode('<b>x</b>'))).response.status, 400)

    // Posting: words, photos, or both; only your own uploads; up to nine photos or one video.
    const posted = await request('/api/moments', { text: '  周末去爬山\n\n\n\n山顶很美  ', media: [{ url: photo, type: 'image', w: 1200, h: 900 }] }, a.cookie)
    assert.equal(posted.response.status, 200)
    const m1 = posted.data.moment
    assert.equal(m1.text, '周末去爬山\n\n山顶很美', 'trimmed, at most one blank line kept')
    assert.deepEqual(m1.media, [{ url: photo, type: 'image', w: 1200, h: 900 }])
    assert.equal(m1.mine, true)
    assert.equal((await request('/api/moments', { text: '' }, a.cookie)).response.status, 400, 'nothing to share')
    assert.equal((await request('/api/moments', { media: [{ url: `/api/media/moment/${b.id}/x`, type: 'image' }] }, a.cookie)).response.status, 400, "not someone else's photo")
    assert.equal((await request('/api/moments', { media: [{ url: 'https://elsewhere.example/p.jpg', type: 'image' }] }, a.cookie)).response.status, 400)
    const ten = Array.from({ length: 10 }, () => ({ url: photo, type: 'image' }))
    assert.equal((await request('/api/moments', { media: ten }, a.cookie)).response.status, 400, 'nine at most')
    assert.equal((await request('/api/moments', { media: [{ url: photo, type: 'video' }, { url: photo, type: 'image' }] }, a.cookie)).response.status, 400, 'a video goes alone')
    const m2 = (await request('/api/moments', { text: 'Just words' }, a.cookie)).data.moment

    // Who sees them: a, and a's friends; not a stranger.
    const feedOf = async who => (await request('/api/moments', undefined, who.cookie)).data.moments.map(m => m.id)
    assert.deepEqual(await feedOf(a), [m2.id, m1.id], 'newest first')
    assert.deepEqual(await feedOf(b), [m2.id, m1.id], 'a friend sees them')
    assert.deepEqual(await feedOf(d), [], 'a stranger does not')
    const profile = await request(`/api/moments/user/${a.id}`, undefined, d.cookie)
    assert.equal(profile.data.visible, false); assert.deepEqual(profile.data.moments, []); assert.equal(profile.data.user.username, 'mo-a', 'the profile itself is there')
    const own = (await request(`/api/moments/user/${a.id}`, undefined, a.cookie)).data
    assert.equal(own.count, 2); assert.equal(own.friends, 2); assert.ok(own.user.joined > 0)
    assert.equal((await request(`/api/moments/${m1.id}`, undefined, d.cookie)).response.status, 404, 'one by one, neither')

    // Media: friends can load it, a stranger can't.
    assert.equal((await request(photo, undefined, b.cookie)).response.status, 200)
    assert.equal((await request(photo, undefined, d.cookie)).response.status, 403)
    const part = await request(photo, undefined, b.cookie, { headers: { range: 'bytes=0-3' } })
    assert.equal(part.response.status, 206, 'played a range at a time'); assert.equal(part.response.headers.get('content-range'), `bytes 0-3/${jpeg.length}`)

    // Likes and comments: b and c each see a's and their own, and not each other's (they aren't friends).
    await request(`/api/moments/${m1.id}/like`, { on: true }, b.cookie)
    await request(`/api/moments/${m1.id}/comments`, { text: '好美！' }, b.cookie)
    await request(`/api/moments/${m1.id}/like`, { on: true }, c.cookie)
    const byA = (await request(`/api/moments/${m1.id}`, undefined, a.cookie)).data.moment
    assert.deepEqual(byA.likes.map(l => l.username).sort(), ['mo-b', 'mo-c'], 'the author sees every friend')
    assert.deepEqual(byA.comments.map(x => x.text), ['好美！'])
    const byC = (await request(`/api/moments/${m1.id}`, undefined, c.cookie)).data.moment
    assert.deepEqual(byC.likes.map(l => l.username), ['mo-c'], 'c does not see b, a stranger to them')
    assert.deepEqual(byC.comments, [])
    assert.equal(byC.liked, true)
    await request(`/api/moments/${m1.id}/like`, { on: false }, c.cookie)
    assert.equal((await request(`/api/moments/${m1.id}`, undefined, c.cookie)).data.moment.liked, false, 'unliked')
    assert.equal((await request(`/api/moments/${m1.id}/comments`, { text: '   ' }, c.cookie)).response.status, 400)

    // Deleting: a comment by its writer or the moment's author; a moment by its author only, its media with it.
    const comment = byA.comments[0].id
    assert.equal((await request(`/api/moments/${m1.id}/comments/${comment}`, undefined, c.cookie, { method: 'DELETE' })).response.status, 403)
    assert.equal((await request(`/api/moments/${m1.id}/comments/${comment}`, undefined, a.cookie, { method: 'DELETE' })).data.moment.comments.length, 0)
    assert.equal((await request(`/api/moments/${m1.id}`, undefined, b.cookie, { method: 'DELETE' })).response.status, 403)
    assert.equal((await request(`/api/moments/${m1.id}`, undefined, a.cookie, { method: 'DELETE' })).response.status, 200)
    assert.deepEqual(await feedOf(b), [m2.id])
    assert.equal((await request(photo, undefined, a.cookie)).response.status, 404, 'its photo is gone too')

    // Blocking ends it.
    await request('/api/contacts/add', { user: d.id }, a.cookie)
    assert.deepEqual(await feedOf(d), [], 'a request is not friendship')
  } finally {
    await mf.dispose()
    await rm(persistence, { recursive: true, force: true })
  }
})
