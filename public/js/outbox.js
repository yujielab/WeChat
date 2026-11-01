// Messages on their way out. Texts and stickers go one at a time, in the order
// they were written (several sent at once can't overtake each other on the
// network). When the network is gone, the queue waits, keeping each bubble
// "sending", and picks up again the moment the socket reconnects (or after a
// back-off). Every attempt carries the message's localId, so a send that
// actually landed before its answer was lost comes back as that message,
// never a copy. The queue is kept on the device: a reload carries on with it.
//
// Pictures (photos, drawings) wait in the same line, so they keep their place
// among the texts around them. Such an entry has `media` (what to upload) and
// its file is kept apart (blobStore: IndexedDB, keyed by cid), since it can't
// go in localStorage. When it's its turn the file is uploaded first (with the
// same localId, so a repeated upload is the same object), the result is noted
// on the entry (`uploaded`, kept too: a reload doesn't upload it again), then
// the message is posted like any other. A file that didn't survive (a reload
// in private mode, storage full) fails that entry, visibly, never silently.
// A failed entry stays on the device too (with its file), out of the line,
// until it is sent again (retry) or deleted (drop).

/** A failure worth waiting out (no network, a timeout, the server busy), not a refusal. */
export const transient = err => !err || err.name === 'AbortError' || !err.status || err.status >= 500 || err.status === 408 || err.status === 429

export function createOutbox({
  maxAge = 24 * 60 * 60 * 1000,
  now = () => Date.now(),
  setTimer = (fn, ms) => setTimeout(fn, ms),
  clearTimer = id => clearTimeout(id)
} = {}) {
  let deps = null
  let queue = []
  // What could not go (refused, too old, its file lost): kept, with its file,
  // until it is sent again or deleted, so a reload still shows it failed in
  // its place instead of losing it. Out of the line: nothing waits for it.
  let failed = []
  let running = false
  let timer = 0
  let backoff = 0

  const pick = ({ cid, chat, body, local, at, media, uploaded, error, lost }) => ({ cid, chat, body, local, at, ...(media && { media }), ...(uploaded && { uploaded }), ...(error && { error }), ...(lost && { lost }) })
  const persist = () => deps?.save?.([...queue.map(pick), ...failed.map(e => ({ ...pick(e), failed: true }))])
  const forget = e => { if (e.media) deps.forget?.(e.cid) }
  const valid = e => e && typeof e.cid === 'string' && typeof e.chat === 'string' && e.body && typeof e.body === 'object'
  function fail(e, err) {
    queue.shift()
    failed.push({ ...e, error: err.message || '发送失败', ...(err.noFile && { lost: true }) })
    persist()
    deps.onFailed(e, err)
  }

  async function pump() {
    if (running || !deps) return
    running = true
    clearTimer(timer)
    timer = 0
    try {
      while (queue.length) {
        const e = queue[0]
        if (now() - e.at > maxAge) {
          fail(e, new Error('发送超时'))
          continue
        }
        let r
        try {
          if (e.media && !e.uploaded) {
            const file = await deps.blob?.(e.cid)
            if (!file) throw Object.assign(new Error('请重新选择这张图片'), { status: 410, noFile: true })
            const up = await deps.upload(e, file)
            // Still at the head (not taken back meanwhile): keep what landed.
            e.uploaded = { url: up.url, meta: up.meta || {} }
            persist()
          }
          const body = e.uploaded ? { ...e.body, meta: { ...e.uploaded.meta, url: e.uploaded.url } } : e.body
          r = await deps.post({ ...body, localId: e.cid })
        } catch (err) {
          if (transient(err)) {
            // Everything behind it waits too: order is kept.
            deps.onWaiting?.(e, err)
            timer = setTimer(() => pump(), Math.min(30000, 2000 * 2 ** backoff++))
            return
          }
          fail(e, err)
          continue
        }
        // Gone from the queue only once it's known to have landed.
        queue.shift()
        persist()
        forget(e)
        backoff = 0
        deps.onLanded(e, r)
      }
    } finally {
      running = false
    }
  }

  return {
    /**
     * Wire it up: how to send, what to do with the answers, where it's kept.
     * Whatever was still queued or had failed last time is handed to
     * onRestore (failed ones marked `failed`), then the queue resumes.
     */
    connect(d) {
      deps = d
      const saved = (() => { try { return d.load?.() || [] } catch { return [] } })()
      const all = Array.isArray(saved) ? saved.filter(valid) : []
      queue = all.filter(e => !e.failed)
      failed = all.filter(e => e.failed).map(({ failed: _, ...e }) => e)
      if (all.length) d.onRestore?.([...queue.map(e => ({ ...e })), ...failed.map(e => ({ ...e, failed: true }))])
      pump()
    },
    /**
     * media: { kind, name, w, h, key? } for a picture whose file deps.blob(cid)
     * gives (key: what its upload is known by, when not its cid). The same
     * cid already failed is taken out of the failed list: this replaces it.
     */
    add({ cid, chat, body, local, media }) {
      if (queue.some(e => e.cid === cid)) return
      failed = failed.filter(e => e.cid !== cid)
      queue.push({ cid, chat, body, local, at: now(), ...(media && { media }) })
      persist()
      pump()
    },
    /** A failed message sent again as it was (its kept file, its upload if any). */
    retry(cid, local) {
      const i = failed.findIndex(e => e.cid === cid)
      if (i < 0 || queue.some(e => e.cid === cid)) return false
      const [{ error, lost, ...e }] = failed.splice(i, 1)
      queue.push({ ...e, ...(local && { local }), at: now() })
      persist()
      pump()
      return true
    },
    /** The network is back (socket reopened, browser online): try again now. */
    resume() {
      backoff = 0
      pump()
    },
    /** A queued or failed message the person took back. Not the one in flight. */
    drop(cid) {
      const f = failed.findIndex(e => e.cid === cid)
      if (f >= 0) {
        const [e] = failed.splice(f, 1)
        persist()
        forget(e)
        return true
      }
      const i = queue.findIndex(e => e.cid === cid)
      if (i < 0 || (i === 0 && running)) return false
      const [e] = queue.splice(i, 1)
      persist()
      forget(e)
      return true
    },
    has: cid => queue.some(e => e.cid === cid),
    isFailed: cid => failed.some(e => e.cid === cid),
    /** Every picture still kept (queued or failed): their files stay on the device. */
    keptFiles: () => [...queue, ...failed].filter(e => e.media).map(e => e.cid),
    get size() { return queue.length }
  }
}

/**
 * Where a queued picture's file waits: in memory for this page, and in
 * IndexedDB so a reload can still send it. put() answers whether it was kept
 * on the device (false: private mode, storage full, no IndexedDB), so the
 * caller knows a reload would lose it; the page itself still has it.
 */
export function blobStore({ idb = globalThis.indexedDB, name = 'outbox-files' } = {}) {
  const mem = new Map()
  let db = null
  const open = () => db || (db = new Promise((resolve, reject) => {
    if (!idb) return reject(new Error('no IndexedDB'))
    const req = idb.open(name, 1)
    req.onupgradeneeded = () => req.result.createObjectStore('files')
    req.onsuccess = () => resolve(req.result)
    req.onerror = () => reject(req.error)
  }).catch(err => { db = null; throw err }))
  const run = (mode, fn) => open().then(d => new Promise((resolve, reject) => {
    const tx = d.transaction('files', mode)
    const req = fn(tx.objectStore('files'))
    tx.oncomplete = () => resolve(req?.result)
    tx.onerror = tx.onabort = () => reject(tx.error || new Error('IndexedDB'))
  }))
  return {
    async put(cid, file) {
      mem.set(cid, file)
      try { await run('readwrite', s => s.put(file, cid)); return true } catch { return false }
    },
    async get(cid) {
      if (mem.has(cid)) return mem.get(cid)
      try { return (await run('readonly', s => s.get(cid))) || null } catch { return null }
    },
    del(cid) {
      mem.delete(cid)
      return run('readwrite', s => s.delete(cid)).catch(() => {})
    },
    /** Files under this prefix (one account's) left behind by entries no longer queued. */
    async prune(prefix, keep) {
      try {
        const keys = await run('readonly', s => s.getAllKeys())
        for (const k of keys || []) if (String(k).startsWith(prefix) && !keep.has(k) && !mem.has(k)) await this.del(k)
      } catch {}
    }
  }
}

export const outbox = createOutbox()
