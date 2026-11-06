import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { Miniflare, convertV4MiniflareOptions } from 'miniflare'

// Workers AI standing in: it answers with whatever it was last told, and it
// keeps every prompt it was given, so the test can see what was read.
const AI_STUB = `
import { WorkerEntrypoint } from 'cloudflare:workers'
const seen = []
let answer = ''
export class AI extends WorkerEntrypoint {
  async run(model, input) {
    const text = input.messages.map(m => typeof m.content === 'string' ? m.content : '').join('\\n')
    seen.push({ model, text })
    return { response: answer }
  }
}
export default {
  async fetch(request) {
    if (request.method === 'POST') { answer = await request.text(); return new Response('ok') }
    return Response.json(seen)
  }
}
`

test('the writing help remembers: the conversation, its digest and how the writer writes', async () => {
  const bundled = await build({ entryPoints: [fileURLToPath(new URL('../src/index.js', import.meta.url))], bundle: true, write: false, format: 'esm', platform: 'browser' })
  const persistence = await mkdtemp(join(tmpdir(), 'duo-memory-'))
  const mf = new Miniflare(convertV4MiniflareOptions({
    resourcePersistencePath: persistence,
    workers: [
      {
        name: 'duo-memory-test',
        modules: true,
        compatibilityDate: '2026-10-01',
        script: bundled.outputFiles[0].text,
        durableObjects: { HUB: { className: 'Hub', useSQLite: true } },
        r2Buckets: ['MEDIA'],
        serviceBindings: { AI: { name: 'ai-stub', entrypoint: 'AI' } },
        outboundService: async () => new Response('{}')
      },
      { name: 'ai-stub', modules: true, compatibilityDate: '2026-10-01', script: AI_STUB }
    ]
  }))
  const origin = 'https://duo.test'
  const request = async (path, body, session, extra = {}) => {
    const response = await mf.dispatchFetch(origin + path, {
      method: extra.method || (body !== undefined ? 'POST' : 'GET'),
      headers: { origin, ...(body !== undefined && { 'content-type': 'application/json' }), ...(session && { cookie: session }) },
      ...(body !== undefined && { body: JSON.stringify(body) }),
      ...extra
    })
    return { response, data: await response.json() }
  }
  const register = async username => {
    const r = await request('/auth/register', { username, password: 'hunter22' })
    return { cookie: r.response.headers.get('set-cookie').split(';')[0], id: r.data.me.id }
  }
  const stub = async () => mf.getWorker('ai-stub')
  const say = async answer => (await stub()).fetch('http://stub/', { method: 'POST', body: JSON.stringify(answer) })
  const seen = async () => (await (await stub()).fetch('http://stub/')).json()

  try {
    const a = await register('mem-a')
    const b = await register('mem-b')
    const room = (await request('/api/dm', { user: b.id }, a.cookie)).data.room.id

    // A conversation with a history: what it was about, and how a writes.
    await request('/api/messages', { room, type: 'text', text: '我到杭州了，明天下午三点星巴克见？' }, b.cookie)
    await request('/api/messages', { room, type: 'text', text: '好，明天见' }, a.cookie)
    await request('/api/messages', { room, type: 'text', text: '我把材料准备好了' }, a.cookie)
    await request('/api/messages', { room, type: 'text', text: '会议室在哪？' }, b.cookie)
    await request('/api/messages', { room, type: 'text', text: '我把材料准备好了' }, a.cookie)
    await request('/api/messages', { room, type: 'text', text: '材料我放桌上了' }, a.cookie)

    // The suggestion reads the conversation, and the writer's own habit.
    await say('明天下午三点')
    const suggestion = await request('/api/ai/suggest', { room, draft: '明天下午' }, a.cookie)
    // The draft is not repeated: what is offered is what comes after it.
    assert.equal(suggestion.data.text, '三点')
    const prompts = await seen()
    const asked = prompts.at(-1).text
    assert.match(asked, /Conversation:/, 'the conversation is read')
    assert.match(asked, /我把材料准备好了/, 'what was said is read')
    assert.match(asked, /Words I often use/, 'how the writer writes is read')
    assert.match(asked, /材料/, 'the word the writer keeps using is remembered')

    // The memory is the writer's own: the other side does not get it.
    await say('好的')
    await request('/api/ai/suggest', { room, draft: '会议室' }, b.cookie)
    const theirPrompt = (await seen()).at(-1).text
    assert.match(theirPrompt, /Conversation:/, 'the other side reads the conversation too')
    assert.ok(!/Words I often use: 材料/.test(theirPrompt), "one person's habits do not become another's")
    assert.ok(!/Words I often use:/.test(theirPrompt), 'the other side has too little of their own to be a habit')

    // A long conversation: what it was about before the window is kept, and
    // read back into the next suggestion.
    const long = (await request('/api/dm', { user: b.id }, a.cookie)).data.room.id
    // The digest is built in the background as messages are sent, so the
    // model is told what to answer before the messages go out.
    await say('约好了明天的会议')
    for (let i = 0; i < 30; i++) {
      await request('/api/messages', { room: long, type: 'text', text: `第${i}条消息` }, i % 2 ? a.cookie : b.cookie)
    }
    await say('约好了明天的会议')
    await request('/api/ai/suggest', { room: long, draft: '好' }, a.cookie)
    const withDigest = (await seen()).at(-1).text
    assert.match(withDigest, /Earlier in this chat/, 'what the conversation was about earlier is read')
    assert.match(withDigest, /约好了明天的会议/, 'the digest itself is read')

    // The digest belongs to one conversation: another one does not get it.
    const c = await register('mem-c')
    const group = (await request('/api/group', { name: '别处', members: [b.id, c.id] }, a.cookie)).data.room.id
    await request('/api/messages', { room: group, type: 'text', text: '这里聊的是另一件事' }, a.cookie)
    await request('/api/ai/suggest', { room: group, draft: '好' }, a.cookie)
    const elsewhere = (await seen()).at(-1).text
    assert.ok(!/Earlier in this chat/.test(elsewhere), 'a digest does not cross conversations')

    // What is remembered is yours to read, and nobody else's.
    const mine = (await request('/api/ai/memory', undefined, a.cookie)).data
    assert.ok(mine.style.words.length, 'the writer sees what is remembered about them')
    assert.ok(mine.style.words.includes('材料'), 'their own words are what is kept')
    const theirs = (await request('/api/ai/memory', undefined, b.cookie)).data
    assert.ok(!theirs.style.words.includes('材料'), "another person's words are not shown as yours")
    for (const d of theirs.digests) {
      assert.ok(!d.text.includes('会议室'), "another person's digest is not shown")
    }

    // And it can be forgotten.
    const cleared = await request('/api/ai/memory', undefined, a.cookie, { method: 'DELETE' })
    assert.equal(cleared.data.ok, true)
    const after = (await request('/api/ai/memory', undefined, a.cookie)).data
    assert.equal(after.style.messages, 0, 'the style is forgotten')
    assert.equal(after.digests.length, 0, 'and so are the digests')
  } finally {
    await mf.dispose()
    await rm(persistence, { recursive: true, force: true })
  }
})
