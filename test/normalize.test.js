import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { normContact, normMessage, previewOf, mergeContact, isRoomId } from '../src/wx/normalize.js'

const fixture = name => JSON.parse(readFileSync(new URL(`./fixtures/${name}.json`, import.meta.url), 'utf8'))

const SELF = '@self'
const ROOM = '@@room1'
const contacts = new Map([
  [ROOM, normContact({
    UserName: ROOM,
    NickName: '周末徒步',
    MemberCount: 2,
    MemberList: [
      { UserName: '@m1', NickName: 'Alice', DisplayName: '' },
      { UserName: '@m2', NickName: 'Bob', DisplayName: '鲍勃' }
    ]
  })],
  ['@friend', normContact({ UserName: '@friend', NickName: 'Carol', RemarkName: '卡罗', ContactFlag: 3 })]
])
const ctx = { self: SELF, contacts }

test('contacts from the real webwxgetcontact fixture normalize', () => {
  const list = fixture('webwxgetcontact').MemberList.map(normContact)
  assert.ok(list.length > 0)
  for (const c of list) {
    assert.equal(typeof c.id, 'string')
    assert.equal(typeof c.name, 'string')
    assert.ok(c.name.length > 0)
  }
})

test('room naming and flags', () => {
  const room = contacts.get(ROOM)
  assert.equal(room.room, true)
  assert.equal(room.name, '周末徒步')
  assert.equal(room.members.length, 2)
  const unnamed = normContact({ UserName: '@@x', NickName: '', MemberList: [{ UserName: '@a', NickName: 'A' }, { UserName: '@b', NickName: 'B' }] })
  assert.equal(unnamed.name, 'A、B')
  const muted = normContact({ UserName: '@@y', NickName: 'g', Statues: 0 })
  assert.equal(muted.muted, true)
  const pinned = normContact({ UserName: '@p', NickName: 'p', ContactFlag: 2048 | 1 })
  assert.equal(pinned.pinned, true)
  assert.equal(pinned.friend, true)
  assert.ok(isRoomId('123@chatroom'))
})

test('mergeContact keeps known members when an update omits them', () => {
  const prev = contacts.get(ROOM)
  const next = normContact({ UserName: ROOM, NickName: '周末徒步 2', MemberList: [] })
  const merged = mergeContact(prev, next)
  assert.equal(merged.name, '周末徒步 2')
  assert.equal(merged.members.length, 2)
})

test('text message from the real webwxsync fixture', () => {
  const data = fixture('webwxsync')
  const self = data.AddMsgList[1].FromUserName
  const msgs = data.AddMsgList.map(m => normMessage(m, { self, contacts: new Map() }))
  assert.equal(msgs[0].kind, 'notify')
  assert.equal(msgs[0].code, 4)
  assert.ok(msgs[0].targets.length > 0)
  assert.equal(msgs[1].type, 'text')
  assert.equal(msgs[1].text, 'Hello World')
  assert.equal(msgs[1].out, true)
})

test('group message: sender prefix split and group nickname resolved', () => {
  const m = normMessage({
    MsgId: '1', MsgType: 1, FromUserName: ROOM, ToUserName: SELF, CreateTime: 1700000000,
    Content: '@m2:<br/>明早 7 点<br/>集合 &amp; 出发 <span class="emoji emoji1f44d"></span>'
  }, ctx)
  assert.equal(m.chat, ROOM)
  assert.equal(m.from, '@m2')
  assert.equal(m.fromName, '鲍勃')
  assert.equal(m.text, '明早 7 点\n集合 & 出发 👍')
  assert.equal(m.ts, 1700000000000)
  assert.equal(previewOf(m), '鲍勃: 明早 7 点 集合 & 出发 👍')
})

test('outgoing group message sent from the phone has no prefix', () => {
  const m = normMessage({ MsgId: '2', MsgType: 1, FromUserName: SELF, ToUserName: ROOM, Content: '收到', CreateTime: 1 }, ctx)
  assert.equal(m.out, true)
  assert.equal(m.chat, ROOM)
  assert.equal(m.from, SELF)
  assert.equal(previewOf(m), '收到')
})

test('media types', () => {
  const img = normMessage({ MsgId: '3', MsgType: 3, FromUserName: '@friend', ToUserName: SELF, ImgWidth: 300, ImgHeight: 200, Content: '' }, ctx)
  assert.deepEqual([img.type, img.w, img.h], ['image', 300, 200])
  const voice = normMessage({ MsgId: '4', MsgType: 34, FromUserName: '@friend', ToUserName: SELF, VoiceLength: 4200, Content: '' }, ctx)
  assert.equal(previewOf(voice), '[语音] 4″')
  const video = normMessage({ MsgId: '5', MsgType: 43, FromUserName: '@friend', ToUserName: SELF, PlayLength: 12, Content: '' }, ctx)
  assert.equal(video.type, 'video')
  const sticker = normMessage({
    MsgId: '6', MsgType: 47, FromUserName: '@friend', ToUserName: SELF,
    Content: '&lt;msg&gt;&lt;emoji fromusername = "x" md5="ab" width="240" height="180" /&gt;&lt;/msg&gt;'
  }, ctx)
  assert.deepEqual([sticker.type, sticker.w, sticker.h], ['sticker', 240, 180])
})

test('app messages: link, file, quote, money', () => {
  const link = normMessage({
    MsgId: '7', MsgType: 49, AppMsgType: 5, FromUserName: '@friend', ToUserName: SELF, FileName: '标题',
    Url: 'https://example.com/a?x=1&amp;y=2',
    Content: '&lt;msg&gt;&lt;appmsg&gt;&lt;title&gt;标题&lt;/title&gt;&lt;des&gt;描述&lt;/des&gt;&lt;url&gt;https://example.com/a?x=1&amp;amp;y=2&lt;/url&gt;&lt;/appmsg&gt;&lt;/msg&gt;'
  }, ctx)
  assert.equal(link.type, 'link')
  assert.equal(link.title, '标题')
  assert.equal(link.desc, '描述')
  assert.equal(link.url, 'https://example.com/a?x=1&y=2')

  const file = normMessage({
    MsgId: '8', MsgType: 49, AppMsgType: 6, FromUserName: '@friend', ToUserName: SELF,
    FileName: 'report.pdf', FileSize: '20480', MediaId: '@crypt_media', Content: ''
  }, ctx)
  assert.deepEqual([file.type, file.name, file.size, file.mediaId], ['file', 'report.pdf', 20480, '@crypt_media'])

  const quote = normMessage({
    MsgId: '9', MsgType: 49, AppMsgType: 57, FromUserName: ROOM, ToUserName: SELF,
    Content: '@m1:<br/>&lt;msg&gt;&lt;appmsg&gt;&lt;title&gt;好的&lt;/title&gt;&lt;type&gt;57&lt;/type&gt;&lt;refermsg&gt;&lt;type&gt;1&lt;/type&gt;&lt;displayname&gt;鲍勃&lt;/displayname&gt;&lt;content&gt;明早 7 点&lt;/content&gt;&lt;/refermsg&gt;&lt;/appmsg&gt;&lt;/msg&gt;'
  }, ctx)
  assert.equal(quote.type, 'text')
  assert.equal(quote.text, '好的')
  assert.deepEqual(quote.quote, { name: '鲍勃', text: '明早 7 点' })
  assert.equal(quote.fromName, 'Alice')

  const money = normMessage({ MsgId: '10', MsgType: 49, AppMsgType: 2001, FromUserName: '@friend', ToUserName: SELF, Content: '' }, ctx)
  assert.equal(previewOf(money), '[微信红包]')
})

test('recall notice points at the original message', () => {
  const r = normMessage({
    MsgId: '11', MsgType: 10002, FromUserName: '@friend', ToUserName: SELF,
    Content: '&lt;sysmsg type="revokemsg"&gt;&lt;revokemsg&gt;&lt;session&gt;x&lt;/session&gt;&lt;oldmsgid&gt;1&lt;/oldmsgid&gt;&lt;msgid&gt;123456&lt;/msgid&gt;&lt;replacemsg&gt;&lt;![CDATA["卡罗" 撤回了一条消息]]&gt;&lt;/replacemsg&gt;&lt;/revokemsg&gt;&lt;/sysmsg&gt;'
  }, ctx)
  assert.equal(r.type, 'recall')
  assert.equal(r.target, '123456')
  assert.equal(r.text, '"卡罗" 撤回了一条消息')
})

test('location shared as text with SubMsgType 48', () => {
  const loc = normMessage({
    MsgId: '12', MsgType: 1, SubMsgType: 48, FromUserName: '@friend', ToUserName: SELF,
    Url: 'http://apis.map.qq.com/uri/v1/geocoder?coord=1,2',
    Content: '上海虹桥站:<br/>/cgi-bin/mmwebwx-bin/webwxgetpubliclinkimg?url=xxx'
  }, ctx)
  assert.equal(loc.type, 'location')
  assert.equal(loc.title, '上海虹桥站')
})

test('unknown message types degrade to a readable placeholder', () => {
  const u = normMessage({ MsgId: '13', MsgType: 777, FromUserName: '@friend', ToUserName: SELF, Content: '' }, ctx)
  assert.equal(u.type, 'unknown')
  assert.match(u.text, /手机/)
})
