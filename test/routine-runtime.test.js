// The routine and habits as the Worker learns them (src/routine.js through src/hub.js), with Workers AI stood in for.
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

test('the routine and habits are learned from your own use, in your own time zone; switched off, forgotten, and yours alone', async () => {
  const bundled = await build({ entryPoints: [fileURLToPath(new URL('../src/index.js', import.meta.url))], bundle: true, write: false, format: 'esm', platform: 'browser' })
  const persistence = await mkdtemp(join(tmpdir(), 'duo-routine-'))
  const mf = new Miniflare(convertV4MiniflareOptions({
    resourcePersistencePath: persistence,
    workers: [
      {
        name: 'duo-routine-test',
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
  // Every request carries the device's time zone, as the app's do (x-tz: Date#getTimezoneOffset).
  const request = async (path, body, session, extra = {}) => {
    const response = await mf.dispatchFetch(origin + path, {
      method: extra.method || (body !== undefined ? 'POST' : 'GET'),
      headers: { origin, 'x-tz': '-480', ...(body !== undefined && { 'content-type': 'application/json' }), ...(session && { cookie: session }) },
      ...(body !== undefined && { body: JSON.stringify(body) }),
      ...extra
    })
    return { response, data: await response.json() }
  }
  const register = async username => {
    const r = await request('/auth/register', { username, password: 'hunter22' })
    return { cookie: r.response.headers.get('set-cookie').split(';')[0], id: r.data.me.id }
  }
  const memory = async who => (await request('/api/ai/memory', undefined, who.cookie)).data
  const stub = async () => mf.getWorker('ai-stub')
  const seen = async () => (await (await stub()).fetch('http://stub/')).json()

  try {
    const a = await register('rt-a')
    const b = await register('rt-b')
    const room = (await request('/api/dm', { user: b.id }, a.cookie)).data.room.id

    // Nothing yet: learning is on, nothing known.
    let r = (await memory(a)).routine
    assert.equal(r.learning, true); assert.equal(r.days, 0); assert.equal(r.confidence, 'none')

    await request('/api/messages', { room, type: 'text', text: '在吗？' }, b.cookie)
    await request('/api/messages', { room, type: 'text', text: '在的😂' }, a.cookie)
    await request('/api/messages', { room, type: 'sticker', meta: { id: 'AgADAQADbbbbbb', kind: 'static', emoji: '👍' } }, a.cookie)
    await request('/api/messages', { room, type: 'text', text: '好的👍' }, a.cookie)
    await request(`/api/room/${room}/read`, { ts: Date.now() }, a.cookie)

    r = (await memory(a)).routine
    assert.equal(r.days, 1, 'today is seen')
    assert.equal(r.tz, -480, 'in the device\'s own time zone')
    assert.equal(r.hours.length, 24); assert.equal(Math.max(...r.hours), 1, 'this hour, the busiest so far')
    const sentKinds = Object.fromEntries(r.kinds.map(k => [k.kind, k.share]))
    assert.ok(sentKinds.text > sentKinds.sticker && sentKinds.sticker > 0, 'what was sent: ' + JSON.stringify(r.kinds))
    assert.deepEqual(r.emoji.slice(0, 2), ['👍', '😂'], 'the emoji reached for, from texts and stickers')
    assert.equal(r.wake, null, 'a few minutes on one day are not "usually": no waking or sleeping time yet')
    assert.equal(r.sleep, null)
    // Only a's own use: b's message is not in a's routine, and a's is not in b's.
    const theirs = (await memory(b)).routine
    assert.equal(theirs.days, 1)
    assert.deepEqual(theirs.emoji, [], "a's emoji are not b's")
    assert.deepEqual(theirs.kinds.map(k => k.kind), ['text'])

    // One day is too little to tell the writing help anything.
    await request('/api/ai/suggest', { room, draft: '好' }, a.cookie)
    assert.ok(!/我的作息和习惯/.test((await seen()).at(-1)?.text || ''), 'nothing read from a single day')

    // Switched off: forgotten at once, and nothing more is learned.
    assert.equal((await request('/api/ai/memory/routine', { learn: 'yes' }, a.cookie)).response.status, 400)
    r = (await request('/api/ai/memory/routine', { learn: false }, a.cookie)).data.routine
    assert.equal(r.learning, false); assert.equal(r.days, 0); assert.deepEqual(r.emoji, [])
    await request('/api/messages', { room, type: 'text', text: '还在😅' }, a.cookie)
    r = (await memory(a)).routine
    assert.equal(r.learning, false); assert.equal(r.days, 0, 'nothing learned while off')
    // Clearing the memory keeps it off.
    await request('/api/ai/memory', undefined, a.cookie, { method: 'DELETE' })
    assert.equal((await memory(a)).routine.learning, false)

    // On again: it starts afresh.
    r = (await request('/api/ai/memory/routine', { learn: true }, a.cookie)).data.routine
    assert.equal(r.learning, true); assert.equal(r.days, 0)
    await request('/api/messages', { room, type: 'text', text: '回来了' }, a.cookie)
    assert.equal((await memory(a)).routine.days, 1)

    // Clearing the memory forgets the routine, and learning stays on.
    await request('/api/ai/memory', undefined, a.cookie, { method: 'DELETE' })
    r = (await memory(a)).routine
    assert.equal(r.days, 0); assert.equal(r.learning, true)
  } finally {
    await mf.dispose()
    await rm(persistence, { recursive: true, force: true })
  }
})
