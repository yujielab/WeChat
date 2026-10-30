import { test } from 'node:test'
import assert from 'node:assert/strict'
import { backdrop, readPrefs, patchPrefs, MAX_ROOMS } from '../src/prefs.js'

const uid = 'u1'
const mine = '/api/media/bg/u1/abc_123'

test('a backdrop is the default, a preset, or a photo of this account\'s own', () => {
  assert.equal(backdrop('', 'bg', uid), '')
  assert.equal(backdrop(null, 'bg', uid), '')
  assert.equal(backdrop('preset:dawn', 'bg', uid), 'preset:dawn')
  assert.equal(backdrop(mine, 'bg', uid), mine)
  assert.equal(backdrop('/api/media/cover/u1/abc', 'cover', uid), '/api/media/cover/u1/abc')
  for (const bad of ['preset:', 'preset:Dawn!', 'preset:' + 'a'.repeat(25), 'https://evil.example/x.jpg', '/api/media/bg/u2/abc', '/api/media/bg/u1/../x', '/api/media/avatar/u1/abc', 42, {}]) {
    assert.equal(backdrop(bad, 'bg', uid), undefined, String(bad))
  }
})

test('prefs read in their current shape whatever was stored', () => {
  assert.deepEqual(readPrefs(null), { chat: '', call: '', rooms: {} })
  assert.deepEqual(readPrefs({ chat: 'preset:mint', rooms: { r1: 'preset:sand', r2: '', r3: 7 }, other: 1 }), { chat: 'preset:mint', call: '', rooms: { r1: 'preset:sand' } })
})

test('a change applies only what it names, checks each value and conversation', () => {
  const isMember = id => id === 'r1' || id === 'r2'
  let r = patchPrefs(null, { chat: 'preset:dawn', rooms: { r1: mine } }, { uid, isMember })
  assert.deepEqual(r.prefs, { chat: 'preset:dawn', call: '', rooms: { r1: mine } })
  r = patchPrefs(r.prefs, { call: 'preset:night', rooms: { r1: '' } }, { uid, isMember })
  assert.deepEqual(r.prefs, { chat: 'preset:dawn', call: 'preset:night', rooms: {} }, '"" puts a conversation back to the default')
  assert.ok(patchPrefs(null, { chat: 'https://x.example/a.png' }, { uid, isMember }).error)
  assert.ok(patchPrefs(null, { rooms: { r9: 'preset:dawn' } }, { uid, isMember }).error, 'not their conversation')
  assert.ok(patchPrefs(null, { rooms: ['preset:dawn'] }, { uid, isMember }).error)
  const many = Object.fromEntries(Array.from({ length: MAX_ROOMS + 1 }, (_, i) => [`r${i}`, 'preset:dawn']))
  assert.ok(patchPrefs(null, { rooms: many }, { uid, isMember: () => true }).error, 'a limit on how many')
})
