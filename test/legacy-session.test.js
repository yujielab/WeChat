import test from 'node:test'
import assert from 'node:assert/strict'
import { mkdtemp, readFile, readdir, rm } from 'node:fs/promises'
import { tmpdir } from 'node:os'
import { join } from 'node:path'
import { fileURLToPath } from 'node:url'
import { DatabaseSync } from 'node:sqlite'
import { build } from 'esbuild'
import { Miniflare, convertV4MiniflareOptions } from 'miniflare'

const root = fileURLToPath(new URL('..', import.meta.url))

test('upgrading retains the retired namespace and starts Hub with separate storage', async t => {
  // The production migration history must remain append-only. Miniflare does
  // not apply Cloudflare migrations, so check that contract separately.
  const source = await readFile(join(root, 'wrangler.jsonc'), 'utf8')
  const config = JSON.parse(source.replace(/^\s*\/\/.*$/gm, ''))
  assert.deepEqual(config.migrations, [
    { tag: 'v1', new_sqlite_classes: ['WeChatSession'] },
    { tag: 'v2', new_sqlite_classes: ['Hub'] }
  ])

  const persistence = await mkdtemp(join(tmpdir(), 'duo-upgrade-'))
  t.after(() => rm(persistence, { recursive: true, force: true }))
  const options = {
    name: config.name,
    modules: true,
    compatibilityDate: config.compatibility_date,
    resourcePersistencePath: persistence,
    durableObjects: { WX: { className: 'WeChatSession', useSQLite: true } },
    // Seed a representative old schema, intentionally incompatible with Hub.
    script: `export class WeChatSession {
      constructor(ctx) { this.ctx = ctx }
      async fetch() {
        this.ctx.storage.sql.exec('CREATE TABLE IF NOT EXISTS messages (id TEXT PRIMARY KEY, content TEXT)')
        this.ctx.storage.sql.exec('INSERT OR REPLACE INTO messages VALUES (?, ?)', 'old-message', 'preserve me')
        return new Response('seeded')
      }
    }
    export default { fetch() { return new Response('legacy') } }`
  }
  const mf = new Miniflare(convertV4MiniflareOptions(options))
  try {
    const legacy = await mf.getDurableObjectNamespace('WX')
    assert.equal(await (await legacy.get(legacy.idFromName('main')).fetch('http://legacy/')).text(), 'seeded')

    const bundled = await build({
      entryPoints: [join(root, config.main)],
      bundle: true,
      write: false,
      format: 'esm',
      platform: 'browser'
    })
    await mf.setOptions(convertV4MiniflareOptions({
      ...options,
      script: bundled.outputFiles[0].text,
      durableObjects: {
        WX: { className: 'WeChatSession', useSQLite: true },
        HUB: { className: 'Hub', useSQLite: true }
      },
      r2Buckets: ['MEDIA']
    }))

    const retired = await mf.getDurableObjectNamespace('WX')
    const response = await retired.get(retired.idFromName('main')).fetch('http://legacy/')
    assert.equal(response.status, 410)
    const status = await mf.dispatchFetch('http://duo/auth/status')
    assert.equal(status.status, 200)
    assert.deepEqual(await status.json(), { configured: true, needsCode: false, authed: false, me: null })
  } finally {
    await mf.dispose()
  }
  {
    // Inspect persisted databases after shutdown; neither class exposes a
    // storage RPC method just for this test.
    const files = await readdir(persistence, { recursive: true })
    let oldDatabases = 0
    let hubDatabases = 0
    for (const file of files.filter(file => file.endsWith('.sqlite'))) {
      const db = new DatabaseSync(join(persistence, file), { readOnly: true })
      try {
        const columns = db.prepare('PRAGMA table_info(messages)').all().map(row => row.name)
        if (!columns.length) continue
        if (columns.includes('content')) {
          oldDatabases++
          assert.deepEqual(db.prepare('SELECT id, content FROM messages').all().map(row => ({ ...row })), [
            { id: 'old-message', content: 'preserve me' }
          ])
        } else {
          hubDatabases++
          assert.equal(db.prepare('SELECT COUNT(*) AS count FROM messages').get().count, 0)
        }
      } finally {
        db.close()
      }
    }
    assert.equal(oldDatabases, 1, 'the retired namespace keeps its original database')
    assert.equal(hubDatabases, 1, 'the new hub has a separate database')
  }
})
