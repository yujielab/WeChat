// Notes and people on the real Worker (src/hub.js, src/store.js): a note — one line, for a day — that only friends
// see; who to chat with (contacts with no chat yet) and who to add (friends of friends, most in common first, then
// people sharing moments for everyone, then those who joined lately), never anyone already known, asked or set aside.
import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { Miniflare, convertV4MiniflareOptions } from 'miniflare'

test('notes for friends for a day; people to chat with and to add', async () => {
  const bundled = await build({ entryPoints: [fileURLToPath(new URL('../src/index.js', import.meta.url))], bundle: true, write: false, format: 'esm', platform: 'browser' })
  const persistence = await mkdtemp(join(tmpdir(), 'duo-people-'))
  const mf = new Miniflare(convertV4MiniflareOptions({
    resourcePersistencePath: persistence,
    workers: [{ name: 'duo-people-test', modules: true, compatibilityDate: '2026-10-01', script: bundled.outputFiles[0].text, durableObjects: { HUB: { className: 'Hub', useSQLite: true } }, r2Buckets: ['MEDIA'] }]
  }))
  const origin = 'https://duo.test'
  const request = async (path, body, session, { method } = {}) => {
    const response = await mf.dispatchFetch(origin + path, {
      method: method || (body !== undefined ? 'POST' : 'GET'),
      headers: { origin, ...(body !== undefined && { 'content-type': 'application/json' }), ...(session && { cookie: session }) },
      ...(body !== undefined && { body: JSON.stringify(body) })
    })
    return { response, data: await response.json().catch(() => null) }
  }
  const register = async username => {
    const r = await request('/auth/register', { username, password: 'hunter22' })
    return { cookie: r.response.headers.get('set-cookie').split(';')[0], id: r.data.me.id }
  }
  const talk = async (x, y) => {
    const room = (await request('/api/dm', { user: y.id }, x.cookie)).data.room.id
    await request('/api/messages', { room, type: 'text', text: 'hi' }, x.cookie)
    await request('/api/messages', { room, type: 'text', text: 'hey' }, y.cookie)
  }

  try {
    const a = await register('pe-a'), b = await register('pe-b'), c = await register('pe-c'), d = await register('pe-d'), e = await register('pe-e'), f = await register('pe-f')
    // a talks with b; b with c and d; c with d and e. So c and d are friends of a's friend b; d and e of c.
    await talk(a, b)
    await talk(b, c)
    await talk(b, d)
    await talk(c, d)
    await talk(c, e)
    // f is a's contact, with no chat yet.
    await request('/api/contacts/add', { user: f.id }, a.cookie)
    await request('/api/contacts/accept', { user: a.id }, f.cookie)

    // ---------------------------------------------------------------- notes
    const set = await request('/api/note', { text: '  Off to   the\nmountains   🏔️  ' }, b.cookie)
    assert.equal(set.response.status, 200)
    assert.equal(set.data.mine.text, 'Off to the mountains 🏔️', 'one line, spaces folded')
    assert.ok(set.data.mine.expires - set.data.mine.created === 24 * 60 * 60 * 1000, 'for a day')
    assert.equal((await request('/api/note', { text: 'x'.repeat(80) }, c.cookie)).data.mine.text.length, 60, 'sixty characters at most')
    const seenByA = (await request('/api/notes', undefined, a.cookie)).data
    assert.equal(seenByA.mine, null)
    assert.deepEqual(seenByA.notes.map(n => [n.user.username, n.text]), [['pe-b', 'Off to the mountains 🏔️']], "a friend's, not a stranger's")
    assert.deepEqual((await request('/api/notes', undefined, e.cookie)).data.notes.map(n => n.user.username), ['pe-c'])
    assert.deepEqual((await request('/api/notes', undefined, b.cookie)).data.mine.text, 'Off to the mountains 🏔️', 'your own')
    // An empty note, or DELETE, takes it down.
    assert.equal((await request('/api/note', { text: '   ' }, c.cookie)).data.mine, null)
    assert.deepEqual((await request('/api/notes', undefined, e.cookie)).data.notes, [])
    await request('/api/note', undefined, b.cookie, { method: 'DELETE' })
    assert.deepEqual((await request('/api/notes', undefined, a.cookie)).data.notes, [])

    // ---------------------------------------------------------------- people
    const peopleOf = async who => (await request('/api/people', undefined, who.cookie)).data
    const pa = await peopleOf(a)
    assert.deepEqual(pa.suggested.map(u => [u.username, u.reason]), [['pe-f', 'Tap to chat']], 'a contact with no chat yet')
    const names = pa.discover.map(u => u.username)
    assert.deepEqual(names.slice(0, 2).sort(), ['pe-c', 'pe-d'], "friends of a's friend first")
    assert.equal(pa.discover[0].reason, '1 mutual friend'); assert.equal(pa.discover[0].mutual, 1)
    assert.ok(!names.includes('pe-a') && !names.includes('pe-b') && !names.includes('pe-f'), 'never yourself, a friend, or a contact')
    assert.ok(names.includes('pe-e'), 'then whoever joined lately')
    assert.equal(pa.discover.find(u => u.username === 'pe-e').reason, 'New on Cuven')
    // Sharing a moment for everyone comes before simply being new.
    await request('/api/moments', { text: 'Hello world' }, e.cookie)
    assert.equal((await peopleOf(a)).discover.find(u => u.username === 'pe-e').reason, 'Shares moments')
    // Two friends in common rank higher: once a talks with c too, d is a friend of two of a's friends (b and c).
    await talk(a, c)
    const after = (await peopleOf(a)).discover
    assert.equal(after.find(u => u.username === 'pe-d').reason, '2 mutual friends', 'd: friends with b and with c')
    assert.equal(after[0].username, 'pe-d', 'most in common first')
    assert.ok(!after.some(u => u.username === 'pe-c'), 'c is a friend now')

    // Asked already: not to discover.
    await request('/api/contacts/add', { user: d.id }, a.cookie)
    assert.ok(!(await peopleOf(a)).discover.some(u => u.username === 'pe-d'), 'a request sent')
    // Set aside: not again.
    assert.equal((await request('/api/people/dismiss', { user: e.id }, a.cookie)).response.status, 200)
    assert.ok(!(await peopleOf(a)).discover.some(u => u.username === 'pe-e'), 'dismissed')
    assert.equal((await request('/api/people/dismiss', { user: 'nobody' }, a.cookie)).response.status, 404)
    // Once a chats with f, f is no longer someone to start a chat with.
    await request('/api/dm', { user: f.id }, a.cookie)
    assert.deepEqual((await peopleOf(a)).suggested, [])
  } finally {
    await mf.dispose()
    await rm(persistence, { recursive: true, force: true })
  }
})
