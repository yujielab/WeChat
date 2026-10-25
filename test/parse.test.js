import { test } from 'node:test'
import assert from 'node:assert/strict'
import {
  parseJsLogin, parseLoginCheck, parseSyncCheck, parseLoginXml, decodeEntities, convertEmoji,
  contentToText, xmlText, xmlAttr, cookiePairs
} from '../src/wx/parse.js'

test('jslogin', () => {
  assert.deepEqual(parseJsLogin('window.QRLogin.code = 200; window.QRLogin.uuid = "4dcaWx3uBw==";'), {
    code: 200,
    uuid: '4dcaWx3uBw=='
  })
  assert.deepEqual(parseJsLogin('window.QRLogin.code = 400;'), { code: 400, uuid: '' })
  assert.deepEqual(parseJsLogin('<html>blocked</html>'), { code: 0, uuid: '' })
})

test('login check: waiting, scanned, confirmed', () => {
  assert.equal(parseLoginCheck('window.code=408;').code, 408)
  const scanned = parseLoginCheck("window.code=201;window.userAvatar = 'data:img/jpg;base64,/9j/4AAQ';")
  assert.equal(scanned.code, 201)
  assert.equal(scanned.avatar, 'data:img/jpg;base64,/9j/4AAQ')
  const ok = parseLoginCheck(
    'window.code=200;\nwindow.redirect_uri="https://wx2.qq.com/cgi-bin/mmwebwx-bin/webwxnewloginpage?ticket=A6@qrticket_0&uuid=4dca==&lang=zh_CN&scan=1463755895";'
  )
  assert.equal(ok.code, 200)
  assert.match(ok.redirect, /^https:\/\/wx2\.qq\.com\/cgi-bin\/mmwebwx-bin\/webwxnewloginpage\?ticket=/)
})

test('synccheck', () => {
  assert.deepEqual(parseSyncCheck('window.synccheck={retcode:"0",selector:"2"}'), { retcode: 0, selector: 2 })
  assert.deepEqual(parseSyncCheck('window.synccheck={retcode:"1101",selector:"0"}'), { retcode: 1101, selector: 0 })
  assert.equal(parseSyncCheck(''), null)
})

test('login xml: success and refusal', () => {
  const ok = parseLoginXml(
    '<error><ret>0</ret><message></message><skey>@crypt_8e4ad7fa_27</skey><wxsid>PsWd4FvKROR5EVcG</wxsid><wxuin>155217200</wxuin><pass_ticket>VgRra%2BZV9X1PB9w9w%3D</pass_ticket><isgrayscale>1</isgrayscale></error>'
  )
  assert.equal(ok.ret, 0)
  assert.equal(ok.wxsid, 'PsWd4FvKROR5EVcG')
  assert.equal(ok.wxuin, '155217200')
  assert.equal(ok.passTicket, 'VgRra%2BZV9X1PB9w9w%3D')
  const no = parseLoginXml('<error><ret>1203</ret><message>为了你的帐号安全，此微信号不能登录网页微信。</message></error>')
  assert.equal(no.ret, 1203)
  assert.equal(no.message, '为了你的帐号安全，此微信号不能登录网页微信。')
  assert.ok(Number.isNaN(parseLoginXml('<html></html>').ret))
})

test('entities, emoji and line breaks', () => {
  assert.equal(decodeEntities('a &lt;b&gt; &amp;amp; &#39;x&#39; &#x1F600; &bogus;'), "a <b> &amp; 'x' 😀 &bogus;")
  assert.equal(convertEmoji('hi <span class="emoji emoji1f604"></span>!'), 'hi 😄!')
  assert.equal(convertEmoji('<span class="emoji emoji1f1e81f1f3"></span>'), '🇨🇳')
  assert.equal(contentToText('line1<br/>line2 &lt;3'), 'line1\nline2 <3')
})

test('xml helpers unwrap CDATA and decode', () => {
  const xml = '<msg><appmsg><title><![CDATA[Hello & bye]]></title><des>a&amp;b</des></appmsg><emoji md5="abc" width="240" height="120" /></msg>'
  assert.equal(xmlText(xml, 'title'), 'Hello & bye')
  assert.equal(xmlText(xml, 'des'), 'a&b')
  assert.equal(xmlAttr(xml, 'emoji', 'width'), '240')
  assert.equal(xmlAttr(xml, 'emoji', 'missing'), '')
})

test('cookie parsing keeps value, flags expiry', () => {
  const pairs = cookiePairs([
    'wxuin=155217200; Domain=wx2.qq.com; Path=/; Expires=Thu, 01-Jan-2099 00:00:00 GMT',
    'webwx_data_ticket=gScXm+Pa/n6Fg==; Domain=.qq.com; Path=/',
    'old=1; Max-Age=0',
    'gone=x; Expires=Thu, 01-Jan-1970 00:00:00 GMT'
  ])
  assert.deepEqual(pairs.map(p => [p.name, p.value, p.expired]), [
    ['wxuin', '155217200', false],
    ['webwx_data_ticket', 'gScXm+Pa/n6Fg==', false],
    ['old', '1', true],
    ['gone', 'x', true]
  ])
})
