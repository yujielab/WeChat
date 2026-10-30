import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { Miniflare, convertV4MiniflareOptions } from 'miniflare'

// Workers AI standing in: key words are whatever in the message reads like a time.
const AI_STUB = `
import { WorkerEntrypoint } from 'cloudflare:workers'
export class AI extends WorkerEntrypoint {
  async run(model, input) {
    const text = input.messages.map(m => m.content).join('\\n')
    const said = text.match(/消息：「([\\s\\S]*?)」/)?.[1] || ''
    return { response: JSON.stringify(said.match(/[明后]天[一二三四五六七八九十0-9]+点/g) || []) }
  }
}
export default { async fetch() { return new Response('') } }
`

test('a sent message rewritten: in place for everyone, nothing new to read, its key words follow the new wording', async () => {
  const bundled = await build({
    entryPoints: [fileURLToPath(new URL('../src/index.js', import.meta.url))],
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'browser'
  })
  const persistence = await mkdtemp(join(tmpdir(), 'duo-edit-'))
  const mf = new Miniflare(convertV4MiniflareOptions({
    resourcePersistencePath: persistence,
    workers: [
      {
        name: 'duo-edit-test',
        modules: true,
        compatibilityDate: '2026-10-01',
        script: bundled.outputFiles[0].text,
        durableObjects: { HUB: { className: 'Hub', useSQLite: true } },
        r2Buckets: ['MEDIA'],
        serviceBindings: { AI: { name: 'ai-stub', entrypoint: 'AI' } }
      },
      { name: 'ai-stub', modules: true, compatibilityDate: '2026-10-01', script: AI_STUB }
    ]
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
  const until = async (check, what) => {
    for (let i = 0; i < 60; i++) {
      const v = await check()
      if (v) return v
      await new Promise(r => setTimeout(r, 50))
    }
    assert.fail(what)
  }

  try {
    const a = await register('edit-a')
    const b = await register('edit-b')
    const room = (await request('/api/dm', { user: b.id }, a.cookie)).data.room.id
    const sent = (await request('/api/messages', { room, type: 'text', text: '明天三点在门口见' }, a.cookie)).data.msg
    const last = async who => (await request(`/api/messages?room=${room}`, undefined, who.cookie)).data.messages.at(-1)
    await until(async () => (await last(b)).meta?.keys?.length, 'key words of the first wording')

    const ws = (await mf.dispatchFetch(`${origin}/api/ws`, { headers: { upgrade: 'websocket', origin, cookie: b.cookie } })).webSocket
    const got = []
    ws.accept()
    ws.addEventListener('message', e => got.push(JSON.parse(e.data)))

    assert.equal((await request('/api/edit', { id: sent.id, text: '改成别的' }, b.cookie)).response.status, 400, 'only its sender')
    assert.equal((await request('/api/edit', { id: sent.id, text: '  ' }, a.cookie)).response.status, 400, 'not into nothing')

    const edited = await request('/api/edit', { id: sent.id, text: '后天四点在门口见' }, a.cookie)
    assert.equal(edited.data.msg.body, '后天四点在门口见')
    assert.equal(edited.data.msg.edited, 1)
    assert.deepEqual(edited.data.msg.meta.history.map(h => h.text), ['明天三点在门口见'])

    const event = await until(() => got.find(m => m.t === 'edit'), 'the other side is told')
    assert.equal(event.msg.id, sent.id)
    assert.equal(event.msg.body, '后天四点在门口见')
    assert.ok(!got.some(m => m.t === 'msg'), 'not a new message')
    const keys = await until(async () => (await last(b)).meta?.keys?.[0], 'key words of the new wording')
    assert.equal(keys, '后天四点')
    assert.equal((await request('/api/rooms', undefined, b.cookie)).data.rooms[0].unread, 1, 'still the one message to read')

    // Up to five times.
    for (let i = 2; i <= 5; i++) assert.equal((await request('/api/edit', { id: sent.id, text: `第${i}版` }, a.cookie)).data.msg.edited, i)
    const sixth = await request('/api/edit', { id: sent.id, text: '第6版' }, a.cookie)
    assert.equal(sixth.response.status, 400)
    assert.match(sixth.data.error, /最多编辑 5 次/)
    // Taken back: no more editing.
    const other = (await request('/api/messages', { room, type: 'text', text: '这条要撤回' }, a.cookie)).data.msg
    await request('/api/revoke', { id: other.id }, a.cookie)
    assert.equal((await request('/api/edit', { id: other.id, text: '改' }, a.cookie)).response.status, 400)
    ws.close()
  } finally {
    await mf.dispose()
    await rm(persistence, { recursive: true, force: true })
  }
})
