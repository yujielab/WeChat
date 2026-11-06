// Moments on the real Worker (src/hub.js, src/store.js, src/media.js): for everyone, or only for friends — your
// contacts and the people you've written with one to one (both of you: opening a chat isn't enough); photos and a
// video of your own; on a moment for friends, likes and comments each viewer sees only from their own friends, on
// one for everyone, all of them; and media only those who may see the moment can load.
import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { Miniflare, convertV4MiniflareOptions } from 'miniflare'

test('moments: friends see them all, anyone else what is for everyone; likes and comments as each viewer may see them', async () => {
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
    // Friends: a has written with b and with c one to one; b and c don't know each other; d knows nobody.
    const talk = async (x, y) => {
      const room = (await request('/api/dm', { user: y.id }, x.cookie)).data.room.id
      await request('/api/messages', { room, type: 'text', text: 'hi' }, x.cookie)
      await request('/api/messages', { room, type: 'text', text: 'hey' }, y.cookie)
      return room
    }
    await talk(a, b)
    await talk(a, c)

    // Photos of your own: a moment upload takes pictures and videos, nothing else.
    const photo = (await upload(a)).data.url
    assert.match(photo, new RegExp(`^/api/media/moment/${a.id}/`))
    assert.equal((await upload(a, 'video/mp4', new Uint8Array(4096))).response.status, 200, 'a video too')
    assert.equal((await upload(a, 'text/html', new TextEncoder().encode('<b>x</b>'))).response.status, 400)

    // Posting: words, photos, or both; only your own uploads; up to nine photos or one video; for friends or everyone.
    const posted = await request('/api/moments', { text: '  周末去爬山\n\n\n\n山顶很美  ', media: [{ url: photo, type: 'image', w: 1200, h: 900 }], audience: 'friends' }, a.cookie)
    assert.equal(posted.response.status, 200)
    const m1 = posted.data.moment
    assert.equal(m1.text, '周末去爬山\n\n山顶很美', 'trimmed, at most one blank line kept')
    assert.deepEqual(m1.media, [{ url: photo, type: 'image', w: 1200, h: 900 }])
    assert.equal(m1.mine, true)
    assert.equal(m1.audience, 'friends')
    assert.equal((await request('/api/moments', { text: '' }, a.cookie)).response.status, 400, 'nothing to share')
    assert.equal((await request('/api/moments', { media: [{ url: `/api/media/moment/${b.id}/x`, type: 'image' }] }, a.cookie)).response.status, 400, "not someone else's photo")
    assert.equal((await request('/api/moments', { media: [{ url: 'https://elsewhere.example/p.jpg', type: 'image' }] }, a.cookie)).response.status, 400)
    const ten = Array.from({ length: 10 }, () => ({ url: photo, type: 'image' }))
    assert.equal((await request('/api/moments', { media: ten }, a.cookie)).response.status, 400, 'nine at most')
    assert.equal((await request('/api/moments', { media: [{ url: photo, type: 'video' }, { url: photo, type: 'image' }] }, a.cookie)).response.status, 400, 'a video goes alone')
    const m2 = (await request('/api/moments', { text: 'Just words' }, a.cookie)).data.moment
    assert.equal(m2.audience, 'everyone', 'for everyone unless you say')
    const open = (await upload(a)).data.url
    const m3 = (await request('/api/moments', { text: 'Out in the open', media: [{ url: open, type: 'image' }], audience: 'anything else' }, a.cookie)).data.moment
    assert.equal(m3.audience, 'everyone')

    // Who sees them: a and a's friends, everything; anyone else, only what's for everyone.
    const feedOf = async who => (await request('/api/moments', undefined, who.cookie)).data.moments.map(m => m.id)
    assert.deepEqual(await feedOf(a), [m3.id, m2.id, m1.id], 'newest first')
    assert.deepEqual(await feedOf(b), [m3.id, m2.id, m1.id], 'a friend sees them all')
    assert.deepEqual(await feedOf(d), [m3.id, m2.id], "a stranger, only what's for everyone")
    const asStranger = (await request(`/api/moments/user/${a.id}`, undefined, d.cookie)).data
    assert.equal(asStranger.visible, false); assert.equal(asStranger.friend, false); assert.equal(asStranger.user.username, 'mo-a')
    assert.deepEqual(asStranger.moments.map(m => m.id), [m3.id, m2.id]); assert.equal(asStranger.count, 2)
    assert.equal(asStranger.moments[0].user.friend, false, 'the card knows to offer a Message')
    const asFriend = (await request(`/api/moments/user/${a.id}`, undefined, b.cookie)).data
    assert.equal(asFriend.friend, true); assert.equal(asFriend.count, 3); assert.equal(asFriend.moments[0].user.friend, true)
    const own = (await request(`/api/moments/user/${a.id}`, undefined, a.cookie)).data
    assert.equal(own.count, 3); assert.equal(own.friends, 2); assert.ok(own.user.joined > 0); assert.equal(own.friend, false)
    assert.equal((await request(`/api/moments/${m1.id}`, undefined, d.cookie)).response.status, 404, 'one by one, neither')
    assert.equal((await request(`/api/moments/${m2.id}`, undefined, d.cookie)).response.status, 200, "but one that's for everyone, yes")

    // Opening a chat is not friendship: d writes to a, a doesn't answer — d still sees only what's for everyone.
    const dRoom = (await request('/api/dm', { user: a.id }, d.cookie)).data.room.id
    await request('/api/messages', { room: dRoom, type: 'text', text: 'Hi! Loved your photo' }, d.cookie)
    assert.deepEqual(await feedOf(d), [m3.id, m2.id])
    assert.equal((await request(`/api/moments/user/${a.id}`, undefined, d.cookie)).data.visible, false)

    // Media: friends can load a moment for friends, a stranger can't; a moment for everyone, anyone can.
    assert.equal((await request(photo, undefined, b.cookie)).response.status, 200)
    assert.equal((await request(photo, undefined, d.cookie)).response.status, 403)
    assert.equal((await request(open, undefined, d.cookie)).response.status, 200, 'for everyone')
    const part = await request(photo, undefined, b.cookie, { headers: { range: 'bytes=0-3' } })
    assert.equal(part.response.status, 206, 'played a range at a time'); assert.equal(part.response.headers.get('content-range'), `bytes 0-3/${jpeg.length}`)

    // On a moment for friends, likes and comments: b and c each see a's and their own, and not each other's.
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
    assert.equal((await request(`/api/moments/${m1.id}/like`, { on: true }, d.cookie)).response.status, 404, 'a stranger cannot like what they cannot see')

    // On a moment for everyone, everyone sees every like and comment, a stranger's too.
    await request(`/api/moments/${m2.id}/comments`, { text: 'Nice' }, b.cookie)
    await request(`/api/moments/${m2.id}/like`, { on: true }, d.cookie)
    const publicByC = (await request(`/api/moments/${m2.id}`, undefined, c.cookie)).data.moment
    assert.deepEqual(publicByC.comments.map(x => x.user.username), ['mo-b']); assert.deepEqual(publicByC.likes.map(l => l.username), ['mo-d'])

    // Deleting: a comment by its writer or the moment's author; a moment by its author only, its media with it.
    const comment = byA.comments[0].id
    assert.equal((await request(`/api/moments/${m1.id}/comments/${comment}`, undefined, c.cookie, { method: 'DELETE' })).response.status, 403)
    assert.equal((await request(`/api/moments/${m1.id}/comments/${comment}`, undefined, a.cookie, { method: 'DELETE' })).data.moment.comments.length, 0)
    assert.equal((await request(`/api/moments/${m1.id}`, undefined, b.cookie, { method: 'DELETE' })).response.status, 403)
    assert.equal((await request(`/api/moments/${m1.id}`, undefined, a.cookie, { method: 'DELETE' })).response.status, 200)
    assert.deepEqual(await feedOf(b), [m3.id, m2.id])
    assert.equal((await request(photo, undefined, a.cookie)).response.status, 404, 'its photo is gone too')

    // A contact request is not friendship either.
    await request('/api/contacts/add', { user: d.id }, a.cookie)
    assert.equal((await request(`/api/moments/user/${a.id}`, undefined, d.cookie)).data.visible, false, 'a request is not friendship')
  } finally {
    await mf.dispose()
    await rm(persistence, { recursive: true, force: true })
  }
})
