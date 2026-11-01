import test from 'node:test'
import assert from 'node:assert/strict'
import { createOutbox, transient } from '../public/js/outbox.js'

const err = status => Object.assign(new Error('x'), { status })
const tick = () => new Promise(r => setImmediate(r))

function rig({ fail = () => null, saved = [], clock = { t: 1000 } } = {}) {
  const timers = []
  const box = createOutbox({ now: () => clock.t, setTimer: (fn, ms) => { timers.push({ fn, ms }); return timers.length }, clearTimer: () => {} })
  const log = { posted: [], landed: [], failed: [], waiting: [], restored: null, saved: null }
  let n = 0
  box.connect({
    post: async body => { log.posted.push(body); const e = fail(body, ++n); if (e) throw e; return { msg: { id: `s-${body.localId}` } } },
    onLanded: (e, r) => log.landed.push([e.cid, r.msg.id]),
    onFailed: (e, x) => log.failed.push([e.cid, x.message]),
    onWaiting: e => log.waiting.push(e.cid),
    onRestore: list => { log.restored = list.map(e => e.cid) },
    save: list => { log.saved = list },
    load: () => saved
  })
  return { box, log, timers, clock }
}

test('transient: no network, timeouts and server trouble wait; refusals don\'t', () => {
  for (const e of [new ApiLike(0), err(500), err(503), err(408), err(429), Object.assign(new Error(), { name: 'AbortError' })]) assert.equal(transient(e), true)
  for (const e of [err(400), err(403), err(413)]) assert.equal(transient(e), false)
  function ApiLike(status) { return err(status) }
})

test('sends one at a time, in order, each with its localId', async () => {
  const { box, log } = rig()
  for (const c of ['a', 'b', 'c']) box.add({ cid: c, chat: 'r', body: { room: 'r', type: 'text', text: c } })
  await tick(); await tick(); await tick()
  assert.deepEqual(log.posted.map(b => b.localId), ['a', 'b', 'c'])
  assert.deepEqual(log.landed, [['a', 's-a'], ['b', 's-b'], ['c', 's-c']])
  assert.equal(box.size, 0)
  assert.deepEqual(log.saved, [])
})

test('offline: the queue holds, keeps order, and resumes on reconnect with the same ids', async () => {
  let offline = true
  const { box, log, timers } = rig({ fail: () => offline ? err(0) : null })
  box.add({ cid: 'a', chat: 'r', body: { text: 'a' } })
  box.add({ cid: 'b', chat: 'r', body: { text: 'b' } })
  await tick()
  assert.deepEqual(log.waiting, ['a'])
  assert.deepEqual(log.landed, [])
  assert.equal(box.size, 2)
  assert.equal(timers.at(-1).ms, 2000, 'a back-off is scheduled too')
  assert.deepEqual(log.saved.map(e => e.cid), ['a', 'b'], 'kept on the device meanwhile')
  offline = false
  box.resume()
  await tick(); await tick()
  assert.deepEqual(log.posted.map(b => b.localId), ['a', 'a', 'b'])
  assert.deepEqual(log.landed.map(x => x[0]), ['a', 'b'])
})

test('back-off grows to 30s and resets after a success', async () => {
  let down = true
  const { box, timers } = rig({ fail: () => down ? err(503) : null })
  box.add({ cid: 'a', chat: 'r', body: {} })
  for (let i = 0; i < 6; i++) { await tick(); timers.at(-1).fn() }
  await tick()
  assert.deepEqual(timers.map(t => t.ms), [2000, 4000, 8000, 16000, 30000, 30000, 30000])
  down = false
  timers.at(-1).fn(); await tick()
  assert.equal(box.size, 0)
})

test('a refusal fails that message only; the rest still go', async () => {
  const { box, log } = rig({ fail: b => b.text === 'bad' ? err(400) : null })
  box.add({ cid: 'a', chat: 'r', body: { text: 'bad' } })
  box.add({ cid: 'b', chat: 'r', body: { text: 'ok' } })
  await tick(); await tick()
  assert.deepEqual(log.failed, [['a', 'x']])
  assert.deepEqual(log.landed, [['b', 's-b']])
})

test('a reload carries on with what was queued; stale or malformed entries are handled', async () => {
  const clock = { t: 100 * 3600e3 }
  const saved = [
    { cid: 'old', chat: 'r', body: { text: 'old' }, at: clock.t - 25 * 3600e3 },
    { cid: 'x', chat: 'r', body: { text: 'x' }, at: clock.t - 1000 },
    { nope: 1 }, null
  ]
  const { log } = rig({ saved, clock })
  await tick(); await tick()
  assert.deepEqual(log.restored, ['old', 'x'])
  assert.deepEqual(log.failed, [['old', '发送超时']])
  assert.deepEqual(log.landed, [['x', 's-x']])
})

test('a queued message can be taken back before it goes, not while in flight', async () => {
  const { box, log } = rig({ fail: () => err(0) })
  box.add({ cid: 'a', chat: 'r', body: {} })
  box.add({ cid: 'b', chat: 'r', body: {} })
  await tick()
  assert.equal(box.drop('b'), true)
  assert.equal(box.has('b'), false)
  assert.equal(box.drop('zz'), false)
  assert.deepEqual(log.saved.map(e => e.cid), ['a'])
})

// ------------------------------------------------------------ pictures in the same line

// A rig whose post and upload both go through a pretend server that, like the
// real one, answers a repeated localId with what already landed.
function picRig({ files = new Map(), saved = [], offline = { on: false }, lose = { post: 0, upload: 0 }, server = { messages: [], objects: new Map(), uploads: 0 } } = {}) {
  const timers = []
  const box = createOutbox({ now: () => 1000, setTimer: (fn, ms) => { timers.push({ fn, ms }); return timers.length }, clearTimer: () => {} })
  const log = { landed: [], failed: [], forgot: [], saved: null, restored: null }
  box.connect({
    blob: async cid => files.get(cid) || null,
    upload: async (e, file) => {
      if (offline.on) throw err(0)
      server.uploads++
      const key = `image/${e.chat}/l-${e.cid}`
      server.objects.set(key, file)
      if (lose.upload > 0) { lose.upload--; throw err(0) }
      return { url: `/api/media/${key}`, meta: { w: e.media.w, h: e.media.h } }
    },
    post: async body => {
      if (offline.on) throw err(0)
      let m = server.messages.find(x => x.localId === body.localId)
      if (!m) server.messages.push(m = { id: `s${server.messages.length}`, ...body })
      if (lose.post > 0) { lose.post--; throw err(0) }
      return { msg: m }
    },
    forget: cid => { log.forgot.push(cid); files.delete(cid) },
    onLanded: (e, r) => log.landed.push([e.cid, r.msg.id]),
    onFailed: (e, x) => log.failed.push([e.cid, x.message]),
    onRestore: list => { log.restored = list.map(e => e.cid) },
    save: list => { log.saved = JSON.parse(JSON.stringify(list)) },
    load: () => saved
  })
  return { box, log, server, timers, files }
}
const settle = async (n = 8) => { for (let i = 0; i < n; i++) await tick() }
const pic = (cid, extra = {}) => ({ cid, chat: 'r', body: { room: 'r', type: 'image', ...extra }, local: { id: `local:${cid}`, type: 'image' }, media: { kind: 'image', name: 'p.jpg', w: 4, h: 3 } })

test('a photo queued offline waits as "sending" and goes in its place among the texts on reconnect', async () => {
  const offline = { on: true }
  const files = new Map([['p', 'BLOB-p'], ['d', 'BLOB-d']])
  const { box, log, server } = picRig({ files, offline })
  box.add({ cid: 't1', chat: 'r', body: { room: 'r', type: 'text', text: '先' } })
  box.add(pic('p'))
  box.add({ cid: 't2', chat: 'r', body: { room: 'r', type: 'text', text: '中' } })
  box.add({ ...pic('d'), body: { room: 'r', type: 'drawing', replyTo: 'm9' }, media: { kind: 'drawing', name: 'drawing.png', w: 2, h: 2 } })
  box.add({ cid: 't3', chat: 'r', body: { room: 'r', type: 'text', text: '后' } })
  await settle()
  assert.deepEqual(log.failed, [], 'offline is waiting, not failing')
  assert.equal(box.size, 5)
  assert.deepEqual(log.saved.map(e => e.cid), ['t1', 'p', 't2', 'd', 't3'])
  assert.deepEqual(log.saved[1].media, { kind: 'image', name: 'p.jpg', w: 4, h: 3 }, 'the picture is kept as a description; its file lives apart')
  offline.on = false
  box.resume()
  await settle(20)
  assert.deepEqual(server.messages.map(m => m.localId), ['t1', 'p', 't2', 'd', 't3'], 'one line, nobody overtakes')
  assert.deepEqual(server.messages[1].meta, { w: 4, h: 3, url: '/api/media/image/r/l-p' })
  assert.equal(server.messages[3].type, 'drawing')
  assert.equal(server.messages[3].replyTo, 'm9', 'a reply stays a reply')
  assert.deepEqual(log.landed.map(x => x[0]), ['t1', 'p', 't2', 'd', 't3'])
  assert.deepEqual(log.forgot, ['p', 'd'], 'the kept files go once they landed')
  assert.equal(files.size, 0)
})

test('a picture sent twice (answers lost) is one upload object and one message', async () => {
  const { box, log, server, timers } = picRig({ files: new Map([['p', 'BLOB']]), lose: { upload: 1, post: 1 } })
  box.add(pic('p'))
  await settle()
  timers.at(-1).fn(); await settle()  // upload's answer was lost: same key again
  timers.at(-1).fn(); await settle()  // post's answer was lost: same localId again
  assert.equal(server.uploads, 2)
  assert.equal(server.objects.size, 1, 'the repeated upload overwrote nothing new')
  assert.equal(server.messages.length, 1)
  assert.deepEqual(log.landed, [['p', 's0']])
  // Adding the same cid again (a double tap on 重试) doesn't queue a copy.
  box.add(pic('q')); box.add(pic('q'))
  assert.ok(box.size <= 1)
})

test('once uploaded, a reload posts without uploading again; a kept file survives the reload', async () => {
  // First page: uploaded, then the network went before the post.
  const files = new Map([['p', 'BLOB'], ['k', 'BLOB-k']])
  const first = picRig({ files, lose: { post: 1 } })
  first.box.add(pic('p'))
  first.box.add({ cid: 't', chat: 'r', body: { room: 'r', type: 'text', text: 'x' } })
  first.box.add(pic('k'))
  await settle()
  const saved = first.log.saved
  assert.deepEqual(saved.map(e => e.cid), ['p', 't', 'k'])
  assert.equal(saved[0].uploaded.url, '/api/media/image/r/l-p', 'what was uploaded is remembered')
  // Reload: a new page, same device storage.
  const again = picRig({ files, saved, server: first.server })
  await settle(20)
  assert.deepEqual(again.log.restored, ['p', 't', 'k'])
  assert.equal(again.server.uploads, 2, 'p was uploaded once (first page), k once (after the reload)')
  assert.deepEqual(again.server.messages.map(m => m.localId), ['p', 't', 'k'], 'and still one message each')
  assert.deepEqual(again.log.failed, [])
})

test('a reload where the file could not be kept fails that picture visibly; the rest still go', async () => {
  const saved = [
    { ...pic('gone'), at: 1000 },
    { cid: 't', chat: 'r', body: { room: 'r', type: 'text', text: 'x' }, at: 1000 }
  ]
  const { log, server } = picRig({ files: new Map(), saved })
  await settle()
  assert.deepEqual(log.restored, ['gone', 't'])
  assert.deepEqual(log.failed, [['gone', '请重新选择这张图片']])
  assert.deepEqual(server.messages.map(m => m.localId), ['t'])
})

test('a queued picture taken back is dropped with its file', async () => {
  const offline = { on: true }
  const files = new Map([['a', 'A'], ['p', 'P']])
  const { box, log } = picRig({ files, offline })
  box.add(pic('a'))
  box.add(pic('p'))
  await settle()
  assert.equal(box.drop('p'), true)
  assert.deepEqual(log.forgot, ['p'])
  assert.equal(files.has('p'), false)
  assert.deepEqual(log.saved.map(e => e.cid), ['a'])
})

test('blobStore without IndexedDB: this page keeps the file, put says it is not on the device, a new page has none', async () => {
  const { blobStore } = await import('../public/js/outbox.js')
  const page = blobStore({ idb: undefined })
  assert.equal(await page.put('u:p', 'BLOB'), false)
  assert.equal(await page.get('u:p'), 'BLOB')
  const reloaded = blobStore({ idb: undefined })
  assert.equal(await reloaded.get('u:p'), null)
  await page.del('u:p')
  assert.equal(await page.get('u:p'), null)
})

// ------------------------------------------------------------ failed ones stay

test('a refused message is kept as failed across a reload, in the order it was, and can be sent again with the same id', async () => {
  let refuse = true
  const { box, log } = rig({ fail: b => refuse && b.text === 'bad' ? err(400) : null })
  box.add({ cid: 'a', chat: 'r', body: { text: 'bad', replyTo: 'm1' }, local: { id: 'local:a' } })
  box.add({ cid: 'b', chat: 'r', body: { text: 'ok' } })
  await tick(); await tick()
  assert.deepEqual(log.failed, [['a', 'x']])
  assert.deepEqual(log.saved.map(e => [e.cid, Boolean(e.failed)]), [['a', true]], 'the failed one is still on the device')
  assert.equal(box.isFailed('a'), true)
  assert.equal(box.has('a'), false, 'not in the line: nothing waits behind it')
  // Reload: it comes back failed.
  const again = rig({ saved: log.saved, fail: () => err(400) })
  await tick()
  assert.deepEqual(again.log.restored, ['a'])
  assert.deepEqual(again.log.posted, [], 'a failed one is not sent by itself')
  assert.equal(again.box.isFailed('a'), true)
  // 重试 after the reload: same localId, the reply kept.
  refuse = false
  const third = rig({ saved: log.saved })
  await tick()
  assert.equal(third.box.retry('a'), true)
  assert.equal(third.box.retry('a'), false, 'a second tap does nothing')
  await tick(); await tick()
  assert.deepEqual(third.log.posted.map(b => [b.localId, b.replyTo]), [['a', 'm1']])
  assert.deepEqual(third.log.landed, [['a', 's-a']])
  assert.deepEqual(third.log.saved, [])
})

test('a failed picture keeps its file until it is sent again or deleted', async () => {
  const files = new Map([['p', 'BLOB'], ['q', 'Q']])
  let refuse = true
  const timers = []
  const box = createOutbox({ now: () => 1000, setTimer: (fn, ms) => { timers.push({ fn, ms }); return timers.length }, clearTimer: () => {} })
  const log = { forgot: [], saved: null, posted: [], restored: null }
  const deps = saved => ({
    blob: async cid => files.get(cid) || null,
    upload: async (e) => ({ url: `/u/${e.media.key || e.cid}`, meta: {} }),
    post: async body => { log.posted.push(body); if (refuse) throw err(403); return { msg: { id: `s-${body.localId}` } } },
    forget: cid => { log.forgot.push(cid); files.delete(cid) },
    onLanded: () => {}, onFailed: () => {},
    onRestore: list => { log.restored = list.map(e => [e.cid, Boolean(e.failed)]) },
    save: list => { log.saved = JSON.parse(JSON.stringify(list)) },
    load: () => saved
  })
  box.connect(deps([]))
  box.add(pic('p', { replyTo: 'm7' }))
  box.add(pic('q'))
  await settle()
  assert.deepEqual(log.saved.map(e => [e.cid, e.failed, e.uploaded?.url]), [['p', true, '/u/p'], ['q', true, '/u/q']])
  assert.deepEqual(log.forgot, [], 'files kept while failed')
  assert.deepEqual(box.keptFiles(), ['p', 'q'])
  // Reload, then: p deleted, q sent again (not uploaded again).
  const next = createOutbox({ now: () => 1000, setTimer: () => 0, clearTimer: () => {} })
  next.connect(deps(log.saved))
  assert.deepEqual(log.restored, [['p', true], ['q', true]])
  assert.equal(next.drop('p'), true)
  assert.deepEqual(log.forgot, ['p'])
  refuse = false
  log.posted = []
  assert.equal(next.retry('q'), true)
  await settle()
  assert.deepEqual(log.posted.map(b => [b.localId, b.meta.url]), [['q', '/u/q']])
  assert.deepEqual(log.forgot, ['p', 'q'], 'q\'s file goes once it landed')
  assert.deepEqual(log.saved, [])
})

test('a picture whose file was lost is kept as lost; choosing it again replaces it as the same message', async () => {
  const files = new Map()
  const saved = [{ ...pic('gone', { replyTo: 'm3' }), at: 1000 }]
  const first = picRig({ files, saved })
  await settle()
  assert.deepEqual(first.log.failed, [['gone', '请重新选择这张图片']])
  assert.deepEqual(first.log.saved.map(e => [e.cid, e.failed, e.lost]), [['gone', true, true]])
  // After another reload it is still there, still lost.
  const second = picRig({ files, saved: first.log.saved, server: first.server })
  await settle()
  assert.deepEqual(second.log.restored, ['gone'])
  assert.equal(second.box.isFailed('gone'), true)
  // 重新选择: the new file, same cid, its own upload key, still a reply.
  files.set('gone', 'NEW')
  second.box.add({ ...pic('gone', { replyTo: 'm3' }), media: { kind: 'image', name: 'n.jpg', w: 4, h: 3, key: 'gone-r1' } })
  await settle()
  assert.equal(second.box.isFailed('gone'), false)
  const sent = second.server.messages.filter(m => m.localId === 'gone')
  assert.equal(sent.length, 1)
  assert.equal(sent[0].replyTo, 'm3')
  assert.equal(second.server.objects.has('image/r/l-gone'), true, 'the picture rig keys by cid; the app passes media.key to the upload')
  assert.deepEqual(second.log.saved, [])
})

test('↓ N counts only the new messages still below the foot, going down as they come into view', async () => {
  const { stillBelow } = await import('../public/js/views/unread.js')
  const tops = { a: 100, b: 400, c: 700, d: null }
  const line = 600
  assert.deepEqual(stillBelow(['a', 'b', 'c', 'd'], id => tops[id], line), ['c', 'd'], 'a and b on screen or above; d not drawn yet still counts')
  // Scrolling down: c comes up past the foot.
  tops.c = 500
  assert.deepEqual(stillBelow(['c', 'd'], id => tops[id], line), ['d'])
  // Exactly at the line is still below it.
  assert.deepEqual(stillBelow(['x'], () => 600, line), ['x'])
})
