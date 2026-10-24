import { test } from 'node:test'
import assert from 'node:assert/strict'
import { DatabaseSync } from 'node:sqlite'
import { Store } from '../src/store.js'
import { normContact } from '../src/wx/normalize.js'

function makeStore() {
  const db = new DatabaseSync(':memory:')
  return new Store((q, ...b) => db.prepare(q).all(...b).map(r => ({ ...r })))
}

const msg = (id, chat, ts, extra = {}) => ({ id, chat, ts, out: false, from: chat, fromName: '', type: 'text', text: `m${id}`, ...extra })

test('kv round trip', () => {
  const s = makeStore()
  assert.equal(s.get('x', 5), 5)
  s.set('x', { a: 1 })
  assert.deepEqual(s.get('x'), { a: 1 })
  s.set('x', null)
  assert.equal(s.get('x'), null)
})

test('messages: dedupe, unread, last summary, paging', () => {
  const s = makeStore()
  assert.equal(s.addMessage(msg('1', '@a', 1000)), true)
  assert.equal(s.addMessage(msg('1', '@a', 1000)), false)
  s.addMessage(msg('2', '@a', 2000))
  s.addMessage(msg('3', '@a', 1500, { type: 'system', text: 'sys' }))
  let row = s.chatRow('@a')
  assert.equal(row.unread, 2)
  assert.equal(row.ts, 2000)
  assert.equal(row.last.text, 'm2')

  // A reply (from this or another device) means the chat has been read.
  s.addMessage(msg('4', '@a', 3000, { out: true }))
  row = s.chatRow('@a')
  assert.equal(row.unread, 0)
  assert.equal(row.last.out, true)

  // Unread is not counted while the chat is open.
  s.addMessage(msg('5', '@a', 4000), { countUnread: false })
  assert.equal(s.chatRow('@a').unread, 0)

  const page = s.listMessages('@a', { limit: 2 })
  assert.deepEqual(page.map(m => m.id), ['4', '5'])
  const older = s.listMessages('@a', { before: 3000, limit: 10 })
  assert.deepEqual(older.map(m => m.id), ['1', '3', '2'])
})

test('rekey local message to server id and refresh last', () => {
  const s = makeStore()
  s.addMessage(msg('local:1', '@a', 1000, { out: true, status: 'sending' }))
  const m = s.rekeyMessage('local:1', '99', { status: 'sent' })
  assert.equal(m.id, '99')
  assert.equal(s.getMessage('local:1'), null)
  assert.equal(s.chatRow('@a').last.id, '99')
  assert.equal(s.chatRow('@a').last.status, 'sent')
})

test('hidden chats come back with a new message', () => {
  const s = makeStore()
  s.addMessage(msg('1', '@a', 1000))
  s.hideChat('@a')
  assert.equal(s.listChats().length, 0)
  s.addMessage(msg('2', '@a', 2000))
  assert.equal(s.listChats().length, 1)
})

test('re-login remaps chats onto new session user names', () => {
  const s = makeStore()
  const put = (raw, epoch) => s.putContact(normContact(raw), epoch)
  // Login 1
  put({ UserName: '@old-carol', NickName: 'Carol', RemarkName: '卡罗' }, 1)
  put({ UserName: '@@old-room', NickName: '徒步群', MemberList: [{ UserName: '@old-m', NickName: 'Bob', DisplayName: '' }] }, 1)
  put({ UserName: '@old-gone', NickName: 'Gone' }, 1)
  put({ UserName: '@old-twin1', NickName: 'Twin' }, 1)
  s.addMessage(msg('1', '@old-carol', 1000))
  s.addMessage(msg('2', '@@old-room', 2000, { from: '@old-m', fromName: 'Bob' }))
  s.addMessage(msg('3', '@old-gone', 3000))
  s.addMessage(msg('4', '@old-twin1', 4000))
  s.ensureChat('@old-empty')
  // Login 2: same people, new ids; two contacts now share "Twin".
  put({ UserName: '@new-carol', NickName: 'Carol', RemarkName: '卡罗' }, 2)
  put({ UserName: '@@new-room', NickName: '徒步群', MemberList: [{ UserName: '@new-m', NickName: 'Bob', DisplayName: '' }] }, 2)
  put({ UserName: '@new-twin1', NickName: 'Twin' }, 2)
  put({ UserName: '@new-twin2', NickName: 'Twin' }, 2)

  const moved = s.remapAfterLogin(2)
  assert.equal(moved, 2)
  assert.equal(s.getMessage('1').chat, '@new-carol')
  assert.equal(s.getMessage('1').from, '@new-carol')
  assert.equal(s.getMessage('2').chat, '@@new-room')
  assert.equal(s.getMessage('2').from, '@new-m')
  // Ambiguous and vanished contacts keep their history under the old id, read-only.
  assert.equal(s.getMessage('4').chat, '@old-twin1')
  assert.equal(s.getMessage('3').chat, '@old-gone')
  const contacts = s.loadContacts()
  assert.equal(contacts.get('@old-gone').stale, true)
  assert.equal(contacts.has('@old-carol'), false)
  // Empty chats from the old login are dropped.
  assert.equal(s.chatRow('@old-empty'), null)
})
