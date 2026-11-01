import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { Miniflare, convertV4MiniflareOptions } from 'miniflare'

async function hub(name) {
  const bundled = await build({
    entryPoints: [fileURLToPath(new URL('../src/index.js', import.meta.url))],
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'browser'
  })
  const persistence = await mkdtemp(join(tmpdir(), `duo-${name}-`))
  const mf = new Miniflare(convertV4MiniflareOptions({
    name: `duo-${name}-test`,
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
  const dispose = async () => {
    await mf.dispose()
    await rm(persistence, { recursive: true, force: true })
  }
  return { request, register, dispose }
}

test('a reply keeps what it answers: kept with the message, shown in history, and "taken back" once the original is', async () => {
  const { request, register, dispose } = await hub('reply')
  try {
    const a = await register('reply-a')
    const b = await register('reply-b')
    const room = (await request('/api/dm', { user: b.id }, a.cookie)).data.room.id
    const other = (await request('/api/group', { name: '别处', members: [b.id] }, a.cookie)).data.room.id

    const text = await request('/api/messages', { room, type: 'text', text: '今晚吃什么？' }, a.cookie)
    const sticker = await request('/api/messages', { room, type: 'sticker', meta: { id: 'AgADstat', kind: 'static', emoji: '😀' } }, a.cookie)
    const elsewhere = await request('/api/messages', { room: other, type: 'text', text: '别的群' }, a.cookie)

    // The answer carries the original's sender, kind and a short preview.
    const reply = await request('/api/messages', { room, type: 'text', text: '火锅', replyTo: text.data.msg.id }, b.cookie)
    assert.equal(reply.response.status, 200, JSON.stringify(reply.data))
    assert.equal(reply.data.msg.replyTo, text.data.msg.id)
    assert.deepEqual(
      { sender: reply.data.msg.reply.sender, type: reply.data.msg.reply.type, body: reply.data.msg.reply.body },
      { sender: a.id, type: 'text', body: '今晚吃什么？' })

    // Stickers (and photos, drawings) can be answered too; their preview says what they are.
    const toSticker = await request('/api/messages', { room, type: 'text', text: '哈哈', replyTo: sticker.data.msg.id }, b.cookie)
    assert.equal(toSticker.data.msg.reply.type, 'sticker')
    assert.equal(toSticker.data.msg.reply.emoji, '😀')

    // A reference to another conversation, or to nothing, is dropped; the message still goes.
    for (const replyTo of [elsewhere.data.msg.id, 'nope', 42, { id: 1 }]) {
      const odd = await request('/api/messages', { room, type: 'text', text: '照发', replyTo }, b.cookie)
      assert.equal(odd.response.status, 200, JSON.stringify(replyTo))
      assert.equal(odd.data.msg.replyTo, null, JSON.stringify(replyTo))
      assert.equal(odd.data.msg.reply, undefined)
    }

    // History (a fresh read, as after reopening) carries the same reference and preview.
    const list = (await request(`/api/messages?room=${room}&limit=100`, undefined, a.cookie)).data.messages
    const kept = list.find(m => m.id === reply.data.msg.id)
    assert.equal(kept.replyTo, text.data.msg.id)
    assert.equal(kept.reply.body, '今晚吃什么？')

    // Taken back: the quote says so and no longer carries the words.
    await request('/api/revoke', { id: text.data.msg.id }, a.cookie)
    const after = (await request(`/api/messages?room=${room}&limit=100`, undefined, b.cookie)).data.messages.find(m => m.id === reply.data.msg.id)
    assert.equal(after.reply.state, 'revoked')
    assert.equal(after.reply.body, undefined)
  } finally {
    await dispose()
  }
})
