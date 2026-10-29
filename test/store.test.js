import { test } from 'node:test'
import assert from 'node:assert/strict'
import { DatabaseSync } from 'node:sqlite'
import { webcrypto } from 'node:crypto'
import { Store } from '../src/store.js'

globalThis.crypto ??= webcrypto

function makeStore() {
  const db = new DatabaseSync(':memory:')
  return new Store((q, ...b) => db.prepare(q).all(...b).map(r => ({ ...r })))
}
const mkUser = (s, name) => s.createUser({ username: name, display: name[0].toUpperCase() + name.slice(1), salt: 's', hash: 'h' })

test('accounts: create, unique username (case-insensitive), search', () => {
  const s = makeStore()
  const a = mkUser(s, 'alice')
  mkUser(s, 'bob')
  assert.equal(s.userCount(), 2)
  assert.throws(() => s.createUser({ username: 'ALICE', display: 'x', salt: 's', hash: 'h' }))
  assert.equal(s.getUserByUsername('ALICE').id, a.id)
  assert.deepEqual(s.searchUsers('li', a.id).map(u => u.username), []) // excludes self
  assert.deepEqual(s.searchUsers('bo', a.id).map(u => u.username), ['bob'])
})

test('contacts: request, reciprocal accept, list', () => {
  const s = makeStore()
  const a = mkUser(s, 'alice'); const b = mkUser(s, 'bob')
  assert.equal(s.requestContact(a.id, b.id), 'pending_out')
  assert.equal(s.contactState(a.id, b.id), 'pending_out')
  assert.equal(s.contactState(b.id, a.id), 'pending_in')
  assert.equal(s.acceptContact(a.id, b.id), false) // a has no incoming
  assert.equal(s.acceptContact(b.id, a.id), true)
  assert.equal(s.contactState(a.id, b.id), 'accepted')
  assert.deepEqual(s.listContacts(a.id, 'accepted').map(c => c.username), ['bob'])
})

test('dm dedupe and group membership/roles', () => {
  const s = makeStore()
  const a = mkUser(s, 'alice'); const b = mkUser(s, 'bob'); const c = mkUser(s, 'carol')
  const dm = s.getOrCreateDM(a.id, b.id)
  assert.equal(dm, s.getOrCreateDM(b.id, a.id))
  assert.equal(s.roomMembers(dm).length, 2)
  const g = s.createGroup({ name: 'hike', creator: a.id, members: [b.id, c.id] })
  assert.equal(s.roomMembers(g).length, 3)
  assert.equal(s.membership(g, a.id).role, 'owner')
  assert.equal(s.isMember(g, c.id), true)
  s.removeMember(g, c.id)
  assert.equal(s.isMember(g, c.id), false)
})

test('messages: store, last, unread, read, paging, revoke', () => {
  const s = makeStore()
  const a = mkUser(s, 'alice'); const b = mkUser(s, 'bob')
  const dm = s.getOrCreateDM(a.id, b.id)
  s.addMessage({ room: dm, sender: a.id, ts: 1000, type: 'text', body: 'one' })
  s.addMessage({ room: dm, sender: a.id, ts: 2000, type: 'text', body: 'two' })
  const m3 = s.addMessage({ room: dm, sender: a.id, ts: 3000, type: 'text', body: 'three' })
  assert.equal(s.lastMessage(dm).body, 'three')
  let row = s.listRoomsFor(b.id).find(r => r.id === dm)
  assert.equal(row.unread, 3)
  assert.equal(row.peer.username, 'alice')
  assert.equal(row.name, 'Alice')
  s.markRead(dm, b.id, 2000)
  assert.equal(s.listRoomsFor(b.id).find(r => r.id === dm).unread, 1)
  // paging
  assert.deepEqual(s.listMessages(dm, { limit: 2 }).map(m => m.body), ['two', 'three'])
  assert.deepEqual(s.listMessages(dm, { before: 3000, limit: 10 }).map(m => m.body), ['one', 'two'])
  assert.deepEqual(s.listMessages(dm, { after: 1000, limit: 10 }).map(m => m.body), ['two', 'three'])
  // revoke only by sender
  assert.equal(s.revokeMessage(m3.id, b.id), null)
  assert.equal(s.revokeMessage(m3.id, a.id).state, 'revoked')
  assert.equal(s.getMessage(m3.id).body, '')
})

test('reactions: one per person, grouped per emoji, paged with messages, cleared on revoke', () => {
  const s = makeStore()
  const a = mkUser(s, 'alice'); const b = mkUser(s, 'bob'); const c = mkUser(s, 'carol')
  const g = s.createGroup({ name: 'trip', creator: a.id, members: [b.id, c.id] })
  const m1 = s.addMessage({ room: g, sender: a.id, ts: 1000, type: 'text', body: 'hi' })
  const m2 = s.addMessage({ room: g, sender: b.id, ts: 2000, type: 'text', body: 'yo' })
  assert.deepEqual(s.getMessage(m1.id).reactions, [])
  s.setReaction(m1.id, b.id, '❤️')
  s.setReaction(m1.id, c.id, '❤️')
  assert.deepEqual(s.getMessage(m1.id).reactions, [{ emoji: '❤️', users: [b.id, c.id] }])
  // Picking another emoji replaces the person's previous reaction.
  s.setReaction(m1.id, c.id, '😂')
  assert.deepEqual(s.getMessage(m1.id).reactions, [{ emoji: '❤️', users: [b.id] }, { emoji: '😂', users: [c.id] }])
  s.setReaction(m2.id, a.id, '👍')
  const page = s.listMessages(g, { limit: 10 })
  assert.deepEqual(page.map(m => m.reactions.length), [2, 1])
  assert.deepEqual(s.listMessages(g, { after: 1000, limit: 10 })[0].reactions, [{ emoji: '👍', users: [a.id] }])
  // Clearing and revoking remove reactions.
  s.setReaction(m1.id, b.id, '')
  assert.deepEqual(s.getMessage(m1.id).reactions, [{ emoji: '😂', users: [c.id] }])
  s.revokeMessage(m1.id, a.id)
  assert.deepEqual(s.getMessage(m1.id).reactions, [])
})

test('dm rows carry how far the peer has read', () => {
  const s = makeStore()
  const a = mkUser(s, 'alice'); const b = mkUser(s, 'bob')
  const dm = s.getOrCreateDM(a.id, b.id)
  assert.equal(s.listRoomsFor(a.id).find(r => r.id === dm).peerRead, 0)
  s.markRead(dm, b.id, 4200)
  assert.equal(s.listRoomsFor(a.id).find(r => r.id === dm).peerRead, 4200)
  assert.equal(s.listRoomsFor(b.id).find(r => r.id === dm).peerRead, 0)
})

test('rooms sort pinned-first then by latest activity; hidden dm reappears', () => {
  const s = makeStore()
  const a = mkUser(s, 'alice'); const b = mkUser(s, 'bob'); const c = mkUser(s, 'carol')
  const d1 = s.getOrCreateDM(a.id, b.id)
  const d2 = s.getOrCreateDM(a.id, c.id)
  s.addMessage({ room: d1, sender: b.id, ts: 1000, type: 'text', body: 'x' })
  s.addMessage({ room: d2, sender: c.id, ts: 2000, type: 'text', body: 'y' })
  assert.deepEqual(s.listRoomsFor(a.id).map(r => r.id), [d2, d1]) // d2 newer
  s.setMemberFlag(d1, a.id, { pinned: 1 })
  assert.deepEqual(s.listRoomsFor(a.id).map(r => r.id), [d1, d2]) // pinned first
  s.setMemberFlag(d1, a.id, { hidden: 1 })
  assert.equal(s.listRoomsFor(a.id).find(r => r.id === d1), undefined)
  s.getOrCreateDM(b.id, a.id) // reopening unhides
  assert.ok(s.listRoomsFor(a.id).find(r => r.id === d1))
})

test('push subscriptions dedupe by endpoint', () => {
  const s = makeStore()
  const a = mkUser(s, 'alice')
  s.addSub(a.id, { endpoint: 'https://p/1', keys: {} })
  s.addSub(a.id, { endpoint: 'https://p/1', keys: {} })
  s.addSub(a.id, { endpoint: 'https://p/2', keys: {} })
  assert.equal(s.listSubs(a.id).length, 2)
})
