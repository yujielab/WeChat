import test from 'node:test'
import assert from 'node:assert/strict'
import { sendState } from '../public/js/ui/format.js'

test('bubble corner state: clock for every queued message, ticks, read only when read, failed', () => {
  assert.equal(sendState({ out: false, status: 'sent', id: 'x' }), null)
  assert.deepEqual(sendState({ out: true, status: 'sending', id: 'local:1' }), { state: 'sending', label: 'Sending' })
  // Queued offline: each one is still local:, so each shows the clock.
  for (const id of ['local:a', 'local:b', 'local:c']) assert.equal(sendState({ out: true, id, status: 'sending' }).state, 'sending')
  assert.equal(sendState({ out: true, id: 'local:z' }, true).state, 'sending', 'a peer read mark never ticks a message not yet sent')
  assert.deepEqual(sendState({ out: true, status: 'sent', id: 'm1' }), { state: 'sent', label: 'Sent' })
  assert.deepEqual(sendState({ out: true, status: 'delivered', id: 'm1' }), { state: 'delivered', label: 'Delivered' })
  assert.deepEqual(sendState({ out: true, status: 'sent', id: 'm1' }, true), { state: 'read', label: 'Read' })
  assert.equal(sendState({ out: true, status: 'read', id: 'm1' }).state, 'read')
  assert.deepEqual(sendState({ out: true, status: 'failed', id: 'local:f' }, true), { state: 'failed', label: 'Not sent' })
})

test('a folded group shows its weakest state, and a failure wins', async () => {
  const { groupState } = await import('../public/js/ui/format.js')
  const s = state => ({ state })
  assert.equal(groupState([s('read'), s('sent'), s('delivered')]).state, 'sent')
  assert.equal(groupState([s('read'), s('sending'), s('failed')]).state, 'failed')
  assert.equal(groupState([s('read'), s('sending')]).state, 'sending')
  assert.equal(groupState([null, null]), null, 'incoming groups have no state')
})

test('group chats never turn blue, even if the server marks read', () => {
  assert.equal(sendState({ out: true, status: 'read', id: 'g1' }, false, false).state, 'sent')
  assert.equal(sendState({ out: true, status: 'sent', id: 'g1' }, true, false).state, 'sent')
  assert.equal(sendState({ out: true, status: 'delivered', id: 'g1' }, true, false).state, 'delivered')
  assert.equal(sendState({ out: true, status: 'read', id: 'd1' }, false, true).state, 'read')
})
