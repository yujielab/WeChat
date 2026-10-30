import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readSet, readSets, publicSet, catalog, warmSets, chosenSets, allowedName, allowedSets, stickerFile, contentRange, setNames, PRESETS } from '../src/stickers.js'

// An R2 bucket in memory.
function bucket() {
  const items = new Map()
  return {
    items,
    async get(key, opts) {
      const it = items.get(key)
      if (!it) return null
      let bytes = it.bytes
      // Like R2: a Range header in, the part and its range out (the whole
      // file reads as offset 0, its full length).
      let range = { offset: 0, length: bytes.length }
      const asked = opts?.range?.get('range')?.match(/^bytes=(\d*)-(\d*)$/)
      if (asked) {
        range = asked[1] === '' ? { suffix: Number(asked[2]) } : { offset: Number(asked[1]), length: (asked[2] ? Number(asked[2]) + 1 : bytes.length) - Number(asked[1]) }
        const start = range.suffix != null ? bytes.length - range.suffix : range.offset
        bytes = bytes.slice(start, range.length ? start + range.length : undefined)
      }
      return {
        size: it.bytes.length,
        range,
        body: new Blob([bytes]).stream(),
        httpMetadata: it.httpMetadata,
        async json() { return JSON.parse(new TextDecoder().decode(bytes)) },
        async text() { return new TextDecoder().decode(bytes) },
        async arrayBuffer() { return bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength) }
      }
    },
    async head(key) {
      return items.has(key) ? { size: items.get(key).bytes.length } : null
    },
    async put(key, value, opts = {}) {
      const bytes = typeof value === 'string' ? new TextEncoder().encode(value) : new Uint8Array(value)
      items.set(key, { bytes, httpMetadata: opts.httpMetadata })
    }
  }
}

const gzip = async text => new Uint8Array(await new Response(new Blob([text]).stream().pipeThrough(new CompressionStream('gzip'))).arrayBuffer())
const LOTTIE = JSON.stringify({ v: '5.7.4', fr: 60, w: 512, h: 512, layers: [] })

// Telegram's Bot API, as much as the pipeline uses.
async function withTelegram(fn, { failSets = false, failFiles = false } = {}) {
  const calls = []
  const files = {
    F_STATIC: ['stickers/a.webp', new Uint8Array([82, 73, 70, 70, 1])],
    F_VIDEO: ['stickers/b.webm', new Uint8Array([26, 69, 223, 163, 2])],
    F_ANIM: ['stickers/c.tgs', await gzip(LOTTIE)],
    T_ANIM: ['thumbnails/c.webp', new Uint8Array([82, 73, 70, 70, 3])],
    F_DUCK: ['stickers/d.tgs', await gzip(LOTTIE)]
  }
  const real = globalThis.fetch
  globalThis.fetch = async (url, init = {}) => {
    const u = String(url)
    calls.push(u.replace(/bot[^/]+/, 'bot…'))
    if (u.endsWith('/getStickerSet')) {
      if (failSets) return Response.json({ ok: false, description: 'Too Many Requests' }, { status: 429 })
      const { name } = JSON.parse(init.body)
      if (name === 'UtyaDuck') return Response.json({ ok: true, result: { name, title: 'Duck @somechannel', stickers: [
        { file_id: 'F_DUCK', file_unique_id: 'AgADduck', emoji: '🦆', is_animated: true, is_video: false }
      ] } })
      if (name !== 'HandDrawnEmoji') return Response.json({ ok: false, description: 'Bad Request: STICKERSET_INVALID' }, { status: 400 })
      return Response.json({ ok: true, result: { name, title: 'Hand Drawn', stickers: [
        { file_id: 'F_STATIC', file_unique_id: 'AgADstat', emoji: '😀', is_animated: false, is_video: false },
        { file_id: 'F_VIDEO', file_unique_id: 'AgADvide', emoji: '🎉', is_animated: false, is_video: true },
        { file_id: 'F_ANIM', file_unique_id: 'AgADanim', emoji: '😎', is_animated: true, is_video: false, thumbnail: { file_id: 'T_ANIM' } },
        { file_id: 'F_BAD', file_unique_id: 'x', emoji: '?', is_animated: false, is_video: false }
      ] } })
    }
    if (u.endsWith('/getFile')) {
      const { file_id } = JSON.parse(init.body)
      return Response.json({ ok: true, result: { file_id, file_path: files[file_id][0] } })
    }
    const hit = Object.values(files).find(([p]) => u.endsWith('/' + p))
    if (u.includes('/file/bot') && failFiles) return new Response('busy', { status: 429 })
    if (u.includes('/file/bot') && hit) return new Response(hit[1])
    return new Response('not found', { status: 404 })
  }
  try {
    return await fn(calls)
  } finally {
    globalThis.fetch = real
  }
}

const env = { TELEGRAM_BOT_TOKEN: '123:secret', STICKER_SETS: 'HandDrawnEmoji, missing-set!, NoSuchPack' }
const sets = calls => calls.filter(c => c.endsWith('/getStickerSet')).length

test('the table: STICKER_SETS (safe names only, or the defaults) and the presets, any case', () => {
  assert.deepEqual(setNames(env), ['HandDrawnEmoji', 'NoSuchPack'])
  assert.deepEqual(setNames({}), ['HandDrawnEmoji', 'GameEmoji'])
  const all = allowedSets(env)
  assert.equal(all.length, PRESETS.length + 1, 'NoSuchPack added, HandDrawnEmoji not twice')
  assert.equal(allowedName(env, 'utyaduck'), 'UtyaDuck')
  assert.equal(allowedName(env, 'SomeoneElsesPack'), null, 'only names in the table')
  assert.equal(allowedName(env, '../x'), null)
  assert.deepEqual(chosenSets(env, undefined), ['HandDrawnEmoji', 'NoSuchPack'], 'nothing chosen: the starting packs')
  assert.deepEqual(chosenSets(env, []), [], 'all removed stays empty')
  assert.deepEqual(chosenSets(env, ['hotcherry', 'Evil', 'HotCherry', 'UtyaDuck']), ['HotCherry', 'UtyaDuck'])
})

test('a pack is kept for a while; one Telegram refuses is remembered; the browser gets no file ids', async () => {
  await withTelegram(async calls => {
    const r2 = bucket()
    const hand = await readSet(env, r2, 'HandDrawnEmoji', { now: 1000 })
    assert.equal(hand.stickers.length, 3, 'the bad id is left out')
    const pub = publicSet(hand)
    assert.equal(pub.title, '手绘', 'our title for a preset')
    assert.deepEqual(pub.stickers, [
      { id: 'AgADstat', emoji: '😀', kind: 'static', nt: false },
      { id: 'AgADvide', emoji: '🎉', kind: 'video', nt: true },
      { id: 'AgADanim', emoji: '😎', kind: 'animated', nt: false }
    ])
    assert.ok(!JSON.stringify(pub).includes('F_'), 'no Telegram file ids reach the browser')
    assert.equal(sets(calls), 1)
    await readSet(env, r2, 'HandDrawnEmoji', { now: 1000 + 3600e3 })
    assert.equal(sets(calls), 1, 'kept, not asked again')
    await readSet(env, r2, 'HandDrawnEmoji', { now: 1000 + 7 * 3600e3 })
    assert.equal(sets(calls), 2, 'asked again once stale')

    assert.equal(await readSet(env, r2, 'NoSuchPack', { now: 1000 }), null)
    assert.equal(await readSet(env, r2, 'NoSuchPack', { now: 1000 + 1800e3 }), null)
    assert.equal(sets(calls), 3, 'a missing pack is not asked for again within the hour')
    assert.deepEqual((await readSets(env, r2, ['NoSuchPack', 'HandDrawnEmoji'], { now: 1000 + 7 * 3600e3 })).map(s => s.name), ['HandDrawnEmoji'])
  })
})

test('Telegram unreachable: the last copy of a pack is served', async () => {
  const r2 = bucket()
  await withTelegram(() => readSet(env, r2, 'HandDrawnEmoji', { now: 0 }))
  await withTelegram(async () => {
    assert.equal((await readSet(env, r2, 'HandDrawnEmoji', { now: 10 * 3600e3 })).stickers.length, 3)
    assert.equal(await readSet(env, r2, 'UtyaDuck', { now: 10 * 3600e3 }), null, 'nothing kept, nothing to show')
  }, { failSets: true })
  await withTelegram(async calls => {
    assert.ok(await readSet(env, r2, 'UtyaDuck', { now: 10 * 3600e3 + 1 }), 'a failure is not remembered as missing')
    assert.equal(sets(calls), 1)
  })
})

test('the add list: every pack in the table Telegram has, with a cover and whether it is added', async () => {
  await withTelegram(async () => {
    const list = catalog(await readSets(env, bucket(), allowedSets(env)), ['UtyaDuck'])
    assert.deepEqual(list, [
      { name: 'HandDrawnEmoji', title: '手绘', count: 3, cover: { id: 'AgADstat', emoji: '😀', kind: 'static', nt: false }, added: false },
      { name: 'UtyaDuck', title: '小黄鸭', count: 1, cover: { id: 'AgADduck', emoji: '🦆', kind: 'animated', nt: true }, added: true }
    ], 'packs Telegram refuses are left out; our titles, not the channel handle')
  })
})

test('each file is fetched from Telegram once, then served from R2; animated stickers as plain Lottie JSON', async () => {
  await withTelegram(async calls => {
    const r2 = bucket()
    assert.equal(await stickerFile(env, r2, 'AgADduck', { thumb: true }), null, 'not in the starting packs')
    assert.equal(await stickerFile(env, r2, 'AgADduck', { set: 'UtyaDuck', anim: true }).then(o => o.httpMetadata.contentType), 'application/json', 'found in its pack')
    assert.equal(await stickerFile(env, r2, 'AgADduck', { set: 'SomeoneElsesPack', thumb: true }), null, 'a pack outside the table is never read')
    const still = await stickerFile(env, r2, 'AgADstat')
    assert.equal(still.httpMetadata.contentType, 'image/webp')
    const fetched = calls.filter(c => c.includes('/file/')).length
    await stickerFile(env, r2, 'AgADstat')
    assert.equal(calls.filter(c => c.includes('/file/')).length, fetched, 'second time from R2')

    const video = await stickerFile(env, r2, 'AgADvide')
    assert.equal(video.httpMetadata.contentType, 'video/webm')
    assert.equal(await stickerFile(env, r2, 'AgADvide', { thumb: true }), null, 'no still picture for this video sticker')

    const anim = await stickerFile(env, r2, 'AgADanim', { anim: true })
    assert.equal(anim.httpMetadata.contentType, 'application/json')
    assert.deepEqual(JSON.parse(await anim.text()), JSON.parse(LOTTIE), 'unzipped .tgs')
    const thumb = await stickerFile(env, r2, 'AgADanim', { thumb: true })
    assert.equal(thumb.httpMetadata.contentType, 'image/webp')
    assert.ok(r2.items.has('stickers/AgADanim.json') && r2.items.has('stickers/AgADanim.thumb'))

    assert.equal(await stickerFile(env, r2, 'AgADstat', { anim: true }), null, 'only animated stickers have Lottie')
    assert.equal(await stickerFile(env, r2, 'nope/../x'), null)
    assert.equal(await stickerFile(env, r2, 'AgADunknown'), null)
    assert.ok(!calls.some(c => c.includes('123:secret')), 'stub sees no token in this log')
  })
})

test('a kept sticker stays readable after its pack is dropped, without reading the list', async () => {
  await withTelegram(async calls => {
    const r2 = bucket()
    await stickerFile(env, r2, 'AgADstat')
    await stickerFile(env, r2, 'AgADanim')
    await stickerFile(env, r2, 'AgADanim', { anim: true })
    const asked = calls.length
    const other = { ...env, STICKER_SETS: 'NoSuchPack' }
    assert.equal((await stickerFile(other, r2, 'AgADstat')).httpMetadata.contentType, 'image/webp')
    assert.equal((await stickerFile(other, r2, 'AgADanim')).httpMetadata.contentType, 'image/webp', 'its still picture')
    assert.equal((await stickerFile(other, r2, 'AgADanim', { anim: true })).httpMetadata.contentType, 'application/json')
    assert.equal(calls.length, asked, 'nothing asked of Telegram')
  })
})

test('a pack in someone\'s list is fetched ahead of time, once', async () => {
  await withTelegram(async calls => {
    const r2 = bucket()
    const hand = await readSet(env, r2, 'HandDrawnEmoji')
    await warmSets(env, r2, [hand])
    const downloads = () => calls.filter(c => c.includes('/file/bot')).sort()
    assert.deepEqual(downloads(), [
      'https://api.telegram.org/file/bot…/stickers/a.webp',
      'https://api.telegram.org/file/bot…/stickers/b.webm',
      'https://api.telegram.org/file/bot…/stickers/c.tgs',
      'https://api.telegram.org/file/bot…/thumbnails/c.webp'
    ], 'pictures, the still and Lottie of the animated one, the video')
    for (const key of ['AgADstat.webp', 'AgADvide.webm', 'AgADanim.thumb', 'AgADanim.json']) assert.ok(r2.items.has(`stickers/${key}`), key)
    const asked = calls.length
    await warmSets(env, r2, [hand])
    assert.equal(calls.length, asked, 'done once: not looked at again')
    await stickerFile(env, r2, 'AgADanim', { anim: true })
    assert.equal(calls.length, asked, 'readers get it from R2')

    const covers = bucket()
    await warmSets(env, covers, [await readSet(env, covers, 'UtyaDuck')], { covers: true })
    assert.deepEqual([...covers.items.keys()].filter(k => !k.includes('/sets/') && !k.includes('/warm/')), ['stickers/AgADduck.json'], 'the add list: only the cover')
  })
})

test('a pack Telegram won\'t hand over stops early and is tried again later', async () => {
  const r2 = bucket()
  let hand
  await withTelegram(async calls => {
    hand = await readSet(env, r2, 'HandDrawnEmoji', { now: 0 })
    await warmSets(env, r2, [hand], { now: 0 })
    const mark = JSON.parse(new TextDecoder().decode(r2.items.get('stickers/warm/handdrawnemoji').bytes))
    assert.ok(mark.failed >= 3, 'the refusals are remembered')
    assert.ok(!r2.items.has('stickers/AgADstat.webp'))
    const asked = calls.length
    await warmSets(env, r2, [hand], { now: 3600e3 })
    assert.equal(calls.length, asked, 'not again within a few hours')
  }, { failFiles: true })
  await withTelegram(async calls => {
    await warmSets(env, r2, [hand], { now: 7 * 3600e3 })
    assert.equal(calls.filter(c => c.includes('/file/bot')).length, 4, 'then fetched in full')
  })
})

test('video stickers come in parts when asked (Safari plays video only that way)', async () => {
  await withTelegram(async () => {
    const r2 = bucket()
    const whole = await stickerFile(env, r2, 'AgADvide', { range: new Headers() })
    assert.equal(contentRange(whole), null, 'no Range header: the whole file')
    const head = await stickerFile(env, r2, 'AgADvide', { range: new Headers({ range: 'bytes=0-1' }) })
    assert.equal(contentRange(head), 'bytes 0-1/5')
    assert.deepEqual([...new Uint8Array(await head.arrayBuffer())], [26, 69])
    const tail = await stickerFile(env, r2, 'AgADvide', { range: new Headers({ range: 'bytes=3-' }) })
    assert.equal(contentRange(tail), 'bytes 3-4/5')
    assert.equal(contentRange(await stickerFile(env, r2, 'AgADvide', { range: new Headers({ range: 'bytes=-2' }) })), 'bytes 3-4/5')
    assert.equal(contentRange(await stickerFile(env, r2, 'AgADvide', { range: new Headers({ range: 'bytes=0-' }) })), null, 'all of it: a plain 200')
  })
})

test('readers asking at once share one trip to Telegram', async () => {
  await withTelegram(async calls => {
    const r2 = bucket()
    await Promise.all([1, 2, 3].map(() => stickerFile(env, r2, 'AgADvide')))
    assert.equal(calls.filter(c => c.endsWith('b.webm')).length, 1)
    assert.equal(sets(calls), 2, 'each starting pack read once')
  })
})
