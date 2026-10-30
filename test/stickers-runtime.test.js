import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { Miniflare, convertV4MiniflareOptions } from 'miniflare'

// Telegram's Bot API as the Worker sees it: two packs exist, the rest don't.
const gzip = async text => new Uint8Array(await new Response(new Blob([text]).stream().pipeThrough(new CompressionStream('gzip'))).arrayBuffer())
const LOTTIE = JSON.stringify({ v: '5.7.4', fr: 30, w: 512, h: 512, layers: [] })
async function telegram(request) {
  const url = new URL(request.url)
  if (url.hostname !== 'api.telegram.org') return new Response('offline', { status: 502 })
  if (url.pathname.endsWith('/getStickerSet')) {
    const { name } = await request.json()
    const packs = {
      HandDrawnEmoji: [{ file_id: 'F_HAND', file_unique_id: 'AgADhand', emoji: '😀', is_animated: false, is_video: false }],
      UtyaDuck: [{ file_id: 'F_DUCK', file_unique_id: 'AgADduck', emoji: '🦆', is_animated: true, is_video: false }]
    }
    if (!packs[name]) return Response.json({ ok: false, description: 'Bad Request: STICKERSET_INVALID' }, { status: 400 })
    return Response.json({ ok: true, result: { name, title: name, stickers: packs[name] } })
  }
  if (url.pathname.endsWith('/getFile')) {
    const { file_id } = await request.json()
    return Response.json({ ok: true, result: { file_id, file_path: file_id === 'F_DUCK' ? 'stickers/d.tgs' : 'stickers/h.webp' } })
  }
  if (url.pathname.endsWith('/stickers/d.tgs')) return new Response(await gzip(LOTTIE))
  if (url.pathname.endsWith('/stickers/h.webp')) return new Response(new Uint8Array([82, 73, 70, 70]))
  return new Response('not found', { status: 404 })
}

test('packs are chosen in the app from the table, per person, and a sticker loads for someone without its pack', async () => {
  const bundled = await build({
    entryPoints: [fileURLToPath(new URL('../src/index.js', import.meta.url))],
    bundle: true,
    write: false,
    format: 'esm',
    platform: 'browser'
  })
  const persistence = await mkdtemp(join(tmpdir(), 'duo-stickers-'))
  const mf = new Miniflare(convertV4MiniflareOptions({
    name: 'duo-stickers-test',
    modules: true,
    compatibilityDate: '2026-10-01',
    resourcePersistencePath: persistence,
    script: bundled.outputFiles[0].text,
    durableObjects: { HUB: { className: 'Hub', useSQLite: true } },
    r2Buckets: ['MEDIA'],
    bindings: { TELEGRAM_BOT_TOKEN: '1:test', STICKER_SETS: 'HandDrawnEmoji' },
    outboundService: telegram
  }))
  const origin = 'https://duo.test'
  const request = async (path, body, session) => {
    const response = await mf.dispatchFetch(origin + path, {
      method: body !== undefined ? 'POST' : 'GET',
      headers: { origin, ...(body !== undefined && { 'content-type': 'application/json' }), ...(session && { cookie: session }) },
      ...(body !== undefined && { body: JSON.stringify(body) })
    })
    return { response, data: response.headers.get('content-type')?.includes('json') ? await response.json() : await response.arrayBuffer() }
  }
  const register = async username => (await request('/auth/register', { username, password: 'hunter22' })).response.headers.get('set-cookie').split(';')[0]
  const names = r => r.data.sets.map(s => s.name)

  try {
    const a = await register('stickers-a')
    const b = await register('stickers-b')

    // Everyone starts with STICKER_SETS; the add list has every pack Telegram has.
    assert.deepEqual(names(await request('/api/stickers', undefined, a)), ['HandDrawnEmoji'])
    const list = (await request('/api/stickers/catalog', undefined, a)).data.packs
    assert.deepEqual(list.map(p => [p.name, p.title, p.added]), [['HandDrawnEmoji', '手绘', true], ['UtyaDuck', '小黄鸭', false]])

    // Behind those answers, your packs' files and the add list's covers are
    // fetched ahead of time, before anyone asks for them.
    const r2 = await mf.getR2Bucket('MEDIA')
    const kept = async key => {
      for (let i = 0; i < 40; i++) {
        if (await r2.head(key)) return true
        await new Promise(r => setTimeout(r, 50))
      }
      return false
    }
    assert.ok(await kept('stickers/AgADhand.webp'), 'your pack')
    assert.ok(await kept('stickers/AgADduck.json'), 'a cover in the add list')

    // Adding puts the pack first; only names in the table are read.
    assert.deepEqual(names(await request('/api/stickers/mine', { add: 'utyaduck' }, a)), ['UtyaDuck', 'HandDrawnEmoji'])
    assert.equal((await request('/api/stickers/mine', { add: 'SomeoneElsesPack' }, a)).response.status, 400)
    const refused = await request('/api/stickers/mine', { add: 'HotCherry' }, a)
    assert.equal(refused.response.status, 502, 'in the table, but Telegram has no such pack')
    assert.deepEqual(names(await request('/api/stickers/mine', { remove: 'HandDrawnEmoji' }, a)), ['UtyaDuck'])
    assert.deepEqual(names(await request('/api/stickers', undefined, a)), ['UtyaDuck'], 'kept')
    assert.deepEqual(names(await request('/api/stickers', undefined, b)), ['HandDrawnEmoji'], 'one person’s packs are theirs alone')
    assert.equal((await request('/api/stickers/catalog', undefined, a)).data.packs.find(p => p.name === 'UtyaDuck').added, true)

    // b hasn't added UtyaDuck, but a sticker from it (named in the message) still loads.
    const anim = await request('/api/stickers/anim/AgADduck?set=UtyaDuck', undefined, b)
    assert.equal(anim.response.status, 200)
    assert.deepEqual(anim.data, JSON.parse(LOTTIE))
    assert.equal((await request('/api/stickers/img/AgADhand', undefined, b)).response.status, 200, 'the starting packs without a name')

    // Removing every pack leaves none, rather than the starting packs again.
    assert.deepEqual(names(await request('/api/stickers/mine', { remove: 'UtyaDuck' }, a)), [])
    assert.deepEqual(names(await request('/api/stickers', undefined, a)), [])
  } finally {
    await mf.dispose()
    await rm(persistence, { recursive: true, force: true })
  }
})
