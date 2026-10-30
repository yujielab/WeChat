import { test } from 'node:test'
import assert from 'node:assert/strict'
import { transcript, readInsight, fromLocal, localTime, insightRooms, photosToRead, allowRefresh, analyze } from '../src/insights.js'
import { describe, weatherAt, geocode } from '../src/weather.js'

// Beijing time (getTimezoneOffset is -480); "now" is 2026-10-30 17:40 there.
const TZ = -480
const NOW = Date.UTC(2026, 9, 30, 9, 40)
const at = (local) => fromLocal(local, TZ)

test('times go to and from the viewer\'s clock', () => {
  assert.equal(localTime(NOW, TZ), '2026-10-30 17:40')
  assert.equal(at('2026-10-30 17:40'), NOW)
  assert.equal(at('2026-10-31'), Date.UTC(2026, 9, 30, 16, 0), 'a date is its midnight')
  for (const bad of ['', 'tomorrow', '2026-13-01 10:00', '2026-10-32', null, 42]) assert.equal(fromLocal(bad, TZ), null, String(bad))
})

test('the model reads numbered lines of sent messages, photos by their description', () => {
  const msgs = [
    { id: 'a', sender: 'p', ts: NOW - 3600e3, type: 'text', body: '我在杭州\n刚下飞机' },
    { id: 'b', sender: 'me', ts: NOW - 3000e3, type: 'text', body: '好的' },
    { id: 'x', sender: 'p', ts: NOW - 2900e3, type: 'text', body: '', state: 'revoked' },
    { id: 'c', sender: 'p', ts: NOW - 2000e3, type: 'image', body: '', meta: { url: '/api/media/image/r/c1' } },
    { id: 'd', sender: 'p', ts: NOW - 1000e3, type: 'sticker', meta: { emoji: '😂' } }
  ]
  const { text, refs } = transcript(msgs, { me: 'me', tzOffset: TZ, photos: new Map([['c', 'a beach at sunset']]) })
  assert.deepEqual(refs.map(m => m.id), ['a', 'b', 'c', 'd'], 'nothing taken back')
  assert.equal(text.split('\n')[0], '[1] 10-30 16:40 周五 对方：我在杭州 刚下飞机')
  assert.match(text, /\[2\] .* 我：好的/)
  assert.match(text, /\[3\] .* 对方：\[照片：a beach at sunset\]/)
  assert.match(text, /\[4\] .* 对方：\[表情 😂\]/)
})

test('what the model says is checked: real values, sensible times, real messages', () => {
  const refs = [
    { id: 'm1', type: 'text', ts: NOW - 600e3 },
    { id: 'm2', type: 'image', ts: NOW - 500e3, meta: { url: '/api/media/image/r/p2' } },
    { id: 'm3', type: 'text', ts: NOW - 400e3 }
  ]
  const raw = '<think>…</think>好的：' + JSON.stringify({
    city: '杭州',
    upcoming: [{ what: '快递送到', at: '2026-10-31 18:00', ref: 1 }, { what: '去年的事', at: '2025-01-01 10:00', ref: 1 }, { what: '', at: '2026-10-31 18:00' }],
    ride: { stage: '等车', plate: '浙A·12345', car: '白色比亚迪', pickup: '2026-10-30 17:50', dropoff: 'soon', to: '西湖', ref: 3 },
    home: { state: '出门', at: '2026-10-30 17:30', ref: 3 },
    meetup: { place: '星巴克（西湖店）', at: '2026-10-31 15:00', ref: 1 },
    mood: { label: '疲惫', note: '说今天好累', ref: 3 },
    photos: [{ ref: 2, place: '海边', reading: '日落时分的沙滩' }, { ref: 1, place: '不是照片', reading: 'x' }, { ref: 9, place: '不存在' }],
    summary: '她到杭州了，约明天下午见面'.repeat(10),
    ongoing: [{ what: '经期', since: '2026-10-29', until: '', note: '前天说的', ref: 1 }, { what: '出差', since: '2026-10-01', until: '2026-10-20' }],
    likes: ['火锅', '猫', '火锅', 7], dislikes: ['香菜'], hobbies: ['摄影']
  })
  const r = readInsight(raw, { now: NOW, tzOffset: TZ, refs })
  assert.equal(r.city, '杭州')
  assert.deepEqual(r.upcoming, [{ what: '快递送到', at: at('2026-10-31 18:00'), ref: 'm1' }], 'past and empty ones dropped')
  assert.deepEqual(r.ride, { stage: '等车', plate: '浙A·12345', car: '白色比亚迪', pickup: at('2026-10-30 17:50'), dropoff: null, to: '西湖', ref: 'm3' })
  assert.deepEqual(r.home, { state: '出门', at: at('2026-10-30 17:30'), ref: 'm3' })
  assert.deepEqual(r.meetup, { place: '星巴克（西湖店）', at: at('2026-10-31 15:00'), ref: 'm1' })
  assert.deepEqual(r.mood, { label: '疲惫', note: '说今天好累', ref: 'm3' })
  assert.deepEqual(r.photos, [{ ref: 'm2', url: '/api/media/image/r/p2', at: NOW - 500e3, place: '海边', reading: '日落时分的沙滩' }], 'only real photos')
  assert.equal([...r.summary].length, 80)
  assert.deepEqual(r.ongoing.map(e => e.what), ['经期'], 'what has ended goes')
  assert.equal(r.ongoing[0].since, at('2026-10-29'))
  assert.deepEqual(r.likes, ['火锅', '猫'])
  assert.deepEqual(r.dislikes, ['香菜'])
  assert.deepEqual(r.hobbies, ['摄影'])
})

test('nothing usable reads as nothing', () => {
  for (const raw of ['', 'not json', '[]', '{"mood":{"label":"愤怒"},"ride":{"stage":"飞"},"home":{"state":"到家","at":"2026-10-20 10:00"},"meetup":{"place":"","at":"2026-10-31 10:00"}}']) {
    const r = readInsight(raw, { now: NOW, tzOffset: TZ, refs: [] })
    assert.equal(r.mood, null); assert.equal(r.ride, null); assert.equal(r.home, null, 'getting home days ago is no news'); assert.equal(r.meetup, null)
    assert.deepEqual([r.upcoming, r.photos, r.ongoing, r.likes], [[], [], [], []])
  }
})

test('the conversations read: one-to-one, active this week, newest six', () => {
  const rooms = Array.from({ length: 9 }, (_, i) => ({ id: `r${i}`, kind: i === 1 ? 'group' : 'dm', peer: i === 1 ? null : { id: `p${i}` }, last: { id: 'x' }, ts: NOW - i * 3600e3 }))
  rooms.push({ id: 'old', kind: 'dm', peer: { id: 'q' }, last: { id: 'y' }, ts: NOW - 8 * 24 * 3600e3 })
  assert.deepEqual(insightRooms(rooms, NOW).map(r => r.id), ['r0', 'r2', 'r3', 'r4', 'r5', 'r6'])
})

test('only their recent photos are described, a few at most', () => {
  const img = (id, sender, ago) => ({ id, sender, type: 'image', ts: NOW - ago, meta: { url: `/api/media/image/r/${id}` } })
  const msgs = [img('old', 'p', 4 * 24 * 3600e3), img('mine', 'me', 1000), img('a', 'p', 5000), img('b', 'p', 4000), img('c', 'p', 3000), img('d', 'p', 2000), { ...img('e', 'p', 1000), meta: { url: 'https://elsewhere.example/x.jpg' } }]
  assert.deepEqual(photosToRead(msgs, 'me', NOW).map(m => m.id), ['b', 'c', 'd'])
})

test('a conversation is read again at most once a minute', () => {
  assert.equal(allowRefresh('u', 'r', 1000), true)
  assert.equal(allowRefresh('u', 'r', 30000), false)
  assert.equal(allowRefresh('u', 'other', 30000), true)
  assert.equal(allowRefresh('u', 'r', 62000), true)
})

test('a conversation is read in one call; an empty one costs nothing', async () => {
  const calls = []
  const env = { AI: { async run(model, input) { calls.push(input); return { response: '{"city":"上海","summary":"在聊周末"}' } } } }
  const r = await analyze(env, { messages: [{ id: 'a', sender: 'p', ts: NOW - 1000, type: 'text', body: '我在上海' }], me: 'me', tzOffset: TZ, now: NOW })
  assert.equal(r.city, '上海'); assert.equal(r.summary, '在聊周末')
  assert.match(calls[0].messages[1].content, /现在是 2026-10-30 17:40 周五/)
  assert.equal(calls.length, 1)
  await analyze(env, { messages: [{ id: 'z', sender: 'p', ts: NOW - 30 * 24 * 3600e3, type: 'text', body: '很久以前' }], me: 'me', tzOffset: TZ, now: NOW })
  assert.equal(calls.length, 1, 'nothing this week: no call')
})

test('weather: words and symbols, the next sunrise or sunset there, kept a while', async () => {
  assert.deepEqual(describe(0, true), { text: '晴', symbol: 'sun' })
  assert.deepEqual(describe(0, false), { text: '晴朗夜空', symbol: 'moon' })
  assert.deepEqual(describe(63, true), { text: '中雨', symbol: 'cloud-rain' })
  assert.deepEqual(describe(95, false), { text: '雷雨', symbol: 'cloud-bolt' })
  const asked = []
  const fetcher = async url => {
    asked.push(String(url))
    if (String(url).includes('geocoding')) return Response.json({ results: [{ name: '杭州', latitude: 30.29, longitude: 120.16 }] })
    return Response.json({ utc_offset_seconds: 8 * 3600, current: { temperature_2m: 23.6, weather_code: 0, is_day: 1 }, daily: { sunrise: ['2026-10-30T06:12', '2026-10-31T06:13'], sunset: ['2026-10-30T17:28', '2026-10-31T17:27'], temperature_2m_max: [25.2, 24], temperature_2m_min: [15.4, 14] } })
  }
  const place = await geocode('杭州', fetcher)
  assert.deepEqual(place, { lat: 30.29, lon: 120.16, name: '杭州' })
  const early = Date.UTC(2026, 9, 30, 6, 0) // 14:00 there
  const w = await weatherAt(place, { fetcher, now: early })
  assert.deepEqual(w, { temp: 24, unit: 'c', text: '晴', symbol: 'sun', isDay: true, high: 25, low: 15, next: { kind: 'sunset', time: '17:28' } })
  const before = asked.length
  await weatherAt(place, { fetcher, now: early + 60e3 })
  assert.equal(asked.length, before, 'kept for half an hour')
  const late = await weatherAt(place, { fetcher, now: Date.UTC(2026, 9, 30, 11, 0) + 31 * 60e3 }) // 19:31 there
  assert.deepEqual(late.next, { kind: 'sunrise', time: '06:13' }, 'after sunset, the next sunrise')
  const f = await weatherAt({ lat: 1, lon: 2 }, { fetcher, unit: 'f', now: early })
  assert.equal(f.unit, 'f')
  assert.match(asked.at(-1), /temperature_unit=fahrenheit/)
})
