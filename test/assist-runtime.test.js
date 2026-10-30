import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { Miniflare, convertV4MiniflareOptions } from 'miniflare'

// Workers AI as the Worker sees it (env.AI.run), standing in a worker of its
// own; it keeps every prompt it was given, to check what it was shown.
const AI_STUB = `
import { WorkerEntrypoint } from 'cloudflare:workers'
const seen = []
export class AI extends WorkerEntrypoint {
  async run(model, input) {
    const text = input.messages.map(m => m.content).join('\\n')
    seen.push(text)
    if (text.includes('挑出')) return { response: '["明天下午3点","会议室"]' }
    return { response: '下午三点见' }
  }
}
export default { async fetch() { return Response.json(seen) } }
`

test('writing help reads sent messages only, never a live typing preview; key words follow a sent message', async () => {
  const bundled = await build({
    entryPoints: [fileURLToPath(new URL('../src/index.js', import.meta.url))],
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'browser'
  })
  const persistence = await mkdtemp(join(tmpdir(), 'duo-assist-'))
  const mf = new Miniflare(convertV4MiniflareOptions({
    resourcePersistencePath: persistence,
    workers: [
      {
        name: 'duo-assist-test',
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
  const prompts = async () => (await (await mf.getWorker('ai-stub')).fetch('http://stub/')).json()

  try {
    const a = await register('assist-a')
    const b = await register('assist-b')
    const c = await register('assist-c')
    assert.equal((await request('/api/bootstrap', undefined, a.cookie)).data.assist, true, 'offered where the AI binding is')
    const room = (await request('/api/dm', { user: b.id }, a.cookie)).data.room.id

    // b is typing a secret: the preview goes to a over the socket, and nowhere else.
    const ws = (await mf.dispatchFetch(`${origin}/api/ws`, { headers: { upgrade: 'websocket', origin, cookie: b.cookie } })).webSocket
    ws.accept()
    ws.send(JSON.stringify({ t: 'typing', room, text: '还没发出去的秘密草稿' }))
    await new Promise(r => setTimeout(r, 100))

    await request('/api/messages', { room, type: 'text', text: '明天下午3点在会议室见' }, b.cookie)
    // The key words follow a moment later, kept with the message.
    let keys
    for (let i = 0; i < 40 && !keys; i++) {
      await new Promise(r => setTimeout(r, 50))
      keys = (await request(`/api/messages?room=${room}`, undefined, a.cookie)).data.messages.at(-1).meta?.keys
    }
    assert.deepEqual(keys, ['明天下午3点', '会议室'])

    const offer = await request('/api/ai/suggest', { room, draft: '好的，' }, a.cookie)
    assert.equal(offer.data.text, '下午三点见')
    const seen = (await prompts()).join('\n')
    assert.ok(seen.includes('明天下午3点在会议室见'), 'sent messages are read')
    assert.ok(seen.includes('好的，'), 'and your own draft')
    assert.ok(!seen.includes('秘密草稿'), 'never anyone\'s live typing preview')

    // Not a member, or a draft over several lines: nothing, and nothing asked.
    const before = (await prompts()).length
    assert.equal((await request('/api/ai/suggest', { room, draft: '你好' }, c.cookie)).data.text, '')
    assert.equal((await request('/api/ai/suggest', { room, draft: '第一行\n第二行' }, a.cookie)).data.text, '')
    assert.equal((await prompts()).length, before)
    ws.close()
  } finally {
    await mf.dispose()
    await rm(persistence, { recursive: true, force: true })
  }
})
