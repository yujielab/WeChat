import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { Miniflare, convertV4MiniflareOptions } from 'miniflare'

// Workers AI standing in: a photo is "a beach at sunset"; a conversation
// reads as whatever the stub was last told to say (and every prompt is kept).
const AI_STUB = `
import { WorkerEntrypoint } from 'cloudflare:workers'
const seen = []
let answer = '{}'
export class AI extends WorkerEntrypoint {
  async run(model, input) {
    if (input.image) { seen.push({ model, image: input.image.length }); return { description: 'a beach at sunset' } }
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

test('smart panels: read when asked, for you alone; photos described once; weather where they are, else where you are', async () => {
  const bundled = await build({ entryPoints: [fileURLToPath(new URL('../src/index.js', import.meta.url))], bundle: true, write: false, format: 'esm', platform: 'browser' })
  const persistence = await mkdtemp(join(tmpdir(), 'duo-insights-'))
  const weatherAsked = []
  const mf = new Miniflare(convertV4MiniflareOptions({
    resourcePersistencePath: persistence,
    workers: [
      {
        name: 'duo-insights-test',
        modules: true,
        compatibilityDate: '2026-10-01',
        script: bundled.outputFiles[0].text,
        durableObjects: { HUB: { className: 'Hub', useSQLite: true } },
        r2Buckets: ['MEDIA'],
        serviceBindings: { AI: { name: 'ai-stub', entrypoint: 'AI' } },
        // Open-Meteo, standing in.
        outboundService: async request => {
          const url = new URL(request.url)
          weatherAsked.push(url.href)
          if (url.hostname.startsWith('geocoding')) return Response.json({ results: url.searchParams.get('name') === '杭州' ? [{ name: '杭州', latitude: 30.29, longitude: 120.16 }] : [] })
          return Response.json({ utc_offset_seconds: 28800, current: { temperature_2m: 22.4, weather_code: 0, is_day: 1 }, daily: { sunrise: ['2099-01-01T06:12'], sunset: ['2099-01-01T17:28'], temperature_2m_max: [25], temperature_2m_min: [15] } })
        }
      },
      { name: 'ai-stub', modules: true, compatibilityDate: '2026-10-01', script: AI_STUB }
    ]
  }))
  const origin = 'https://duo.test'
  const request = async (path, body, session, extra = {}) => {
    const response = await mf.dispatchFetch(origin + path, {
      method: body !== undefined ? 'POST' : 'GET',
      headers: { origin, ...(body !== undefined && { 'content-type': typeof body === 'string' || body instanceof Uint8Array ? 'image/png' : 'application/json' }), ...(session && { cookie: session }) },
      ...(body !== undefined && { body: typeof body === 'string' || body instanceof Uint8Array ? body : JSON.stringify(body) }),
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
  const local = (offsetMin, d) => { const t = new Date(Date.now() + offsetMin * 60e3 + 8 * 3600e3); return t.toISOString().slice(0, d ? 10 : 16).replace('T', ' ') }

  try {
    const a = await register('ins-a')
    const b = await register('ins-b')
    const room = (await request('/api/dm', { user: b.id }, a.cookie)).data.room.id
    await request('/api/messages', { room, type: 'text', text: '我到杭州了，明天下午三点星巴克见？' }, b.cookie)
    const up = await request(`/api/media/upload?kind=image&room=${room}`, new Uint8Array([137, 80, 78, 71, 13, 10, 26, 10]), b.cookie)
    await request('/api/messages', { room, type: 'image', meta: { url: up.data.url } }, b.cookie)
    await request('/api/messages', { room, type: 'text', text: '好，明天见' }, a.cookie)

    // Nothing read yet: the conversation is listed as waiting to be read.
    let list = (await request('/api/insights', undefined, a.cookie)).data
    assert.equal(list.enabled, true)
    assert.equal(list.rooms.length, 1)
    assert.equal(list.rooms[0].peer.id, b.id)
    assert.equal(list.rooms[0].stale, true)
    assert.equal(list.rooms[0].insight, null)

    await say({ city: '杭州', meetup: { place: '星巴克', at: local(21 * 60), ref: 1 }, photos: [{ ref: 2, place: '海边', reading: '日落时的沙滩' }], summary: '她到杭州了，约明天见', likes: ['咖啡'] })
    const read = (await request('/api/insights/refresh', { room, tz: -480 }, a.cookie)).data
    assert.equal(read.stale, false)
    assert.equal(read.insight.city, '杭州')
    assert.equal(read.insight.meetup.place, '星巴克')
    assert.equal(read.insight.photos[0].url, up.data.url)
    assert.equal(read.insight.summary, '她到杭州了，约明天见')
    let prompts = await seen()
    assert.equal(prompts.filter(p => p.image).length, 1, 'their photo described')
    assert.match(prompts.at(-1).text, /\[照片：a beach at sunset\]/, 'and read with the conversation')
    assert.match(prompts.at(-1).text, /对方：我到杭州了/)
    assert.match(prompts.at(-1).text, /我：好，明天见/)

    // Kept for the one who asked, and the weather is where they are.
    list = (await request('/api/insights?unit=c', undefined, a.cookie)).data
    assert.equal(list.rooms[0].insight.meetup.place, '星巴克')
    assert.deepEqual({ place: list.weather.place, who: list.weather.who, temp: list.weather.temp, text: list.weather.text }, { place: '杭州', who: 'ins-b', temp: 22, text: '晴' })
    assert.equal((await request('/api/insights', undefined, b.cookie)).data.rooms[0].insight, null, 'not shown to the other side')

    // Read again only when there's something new, at most once a minute; the photo isn't described twice.
    const again = (await request('/api/insights/refresh', { room, tz: -480 }, a.cookie)).data
    assert.equal(again.limited, true)
    assert.equal((await seen()).length, prompts.length, 'no new call')

    // Not theirs to read, and not a group.
    const c = await register('ins-c')
    assert.equal((await request('/api/insights/refresh', { room }, c.cookie)).response.status, 400)
    const group = (await request('/api/group', { name: '周末', members: [b.id] }, a.cookie)).data.room.id
    assert.equal((await request('/api/insights/refresh', { room: group }, a.cookie)).response.status, 400)

    // No city said: the weather where you are (Cloudflare's estimate).
    const d = await register('ins-d')
    const room2 = (await request('/api/dm', { user: a.id }, d.cookie)).data.room.id
    await request('/api/messages', { room: room2, type: 'text', text: '在吗' }, a.cookie)
    const here = (await request('/api/insights?unit=f', undefined, d.cookie, { cf: { latitude: '31.23', longitude: '121.47', city: 'Shanghai' } })).data
    assert.deepEqual({ place: here.weather.place, who: here.weather.who, unit: here.weather.unit }, { place: 'Shanghai', who: '', unit: 'f' })
    assert.ok(weatherAsked.some(u => u.includes('temperature_unit=fahrenheit')))
  } finally {
    await mf.dispose()
    await rm(persistence, { recursive: true, force: true })
  }
})
