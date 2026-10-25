import { test } from 'node:test'
import assert from 'node:assert/strict'
import { WxClient, WxError } from '../src/wx/client.js'

// A tiny scripted fetch: each route returns a Response and records the call.
function fakeFetch(routes) {
  const calls = []
  const fn = async (url, init) => {
    const u = new URL(url)
    const key = `${init.method || 'GET'} ${u.host}${u.pathname}`
    calls.push({ key, url, init, headers: Object.fromEntries(init.headers.entries()) })
    const route = routes[key]
    if (!route) throw new Error(`unexpected request ${key}`)
    return route(u, init)
  }
  fn.calls = calls
  return fn
}

const LOGIN_XML =
  '<error><ret>0</ret><message></message><skey>@crypt_k1</skey><wxsid>SID1</wxsid><wxuin>155217200</wxuin><pass_ticket>Vg%2BZ%3D</pass_ticket><isgrayscale>1</isgrayscale></error>'

test('full login handshake: uuid → confirm → newloginpage (UOS headers) → init', async () => {
  const fetch = fakeFetch({
    'GET login.wx.qq.com/jslogin': () => new Response('window.QRLogin.code = 200; window.QRLogin.uuid = "UU==";'),
    'GET login.wx.qq.com/cgi-bin/mmwebwx-bin/login': () =>
      new Response('window.code=200;\nwindow.redirect_uri="https://wx2.qq.com/cgi-bin/mmwebwx-bin/webwxnewloginpage?ticket=T&uuid=UU==&lang=zh_CN&scan=1";'),
    'GET wx2.qq.com/cgi-bin/mmwebwx-bin/webwxnewloginpage': () =>
      new Response(LOGIN_XML, {
        status: 301,
        headers: [
          ['Location', 'https://wx2.qq.com/'],
          ['Set-Cookie', 'wxuin=155217200; Domain=wx2.qq.com; Path=/'],
          ['Set-Cookie', 'webwx_data_ticket=DT+1; Domain=.qq.com; Path=/']
        ]
      }),
    'POST wx2.qq.com/cgi-bin/mmwebwx-bin/webwxinit': () =>
      Response.json({
        BaseResponse: { Ret: 0 },
        User: { UserName: '@me', NickName: 'Me' },
        SKey: '@crypt_k2',
        SyncKey: { Count: 1, List: [{ Key: 1, Val: 100 }] },
        ContactList: []
      })
  })
  const c = new WxClient(undefined, { fetch })
  const uuid = await c.getUuid()
  assert.equal(uuid, 'UU==')
  const jsloginUrl = new URL(fetch.calls[0].url)
  assert.equal(jsloginUrl.searchParams.get('redirect_uri'), 'https://wx.qq.com/cgi-bin/mmwebwx-bin/webwxnewloginpage?mod=desktop')

  const check = await c.checkLogin(uuid)
  assert.equal(check.code, 200)

  await c.completeLogin(check.redirect)
  const loginCall = fetch.calls[2]
  assert.equal(loginCall.init.redirect, 'manual')
  assert.equal(loginCall.headers['client-version'], '2.0.0')
  assert.ok(loginCall.headers.extspam.length > 100)
  assert.equal(c.s.host, 'wx2.qq.com')
  assert.equal(c.s.sid, 'SID1')
  assert.equal(c.s.uin, '155217200')
  assert.equal(c.s.dataTicket, 'DT+1')
  assert.equal(c.s.cookies.wxuin, '155217200')

  const init = await c.init()
  const initCall = fetch.calls[3]
  // pass_ticket is sent exactly as the server issued it (already encoded).
  assert.match(initCall.url, /pass_ticket=Vg%2BZ%3D(&|$)/)
  assert.match(initCall.headers.cookie, /wxuin=155217200/)
  const sent = JSON.parse(initCall.init.body)
  assert.deepEqual(Object.keys(sent.BaseRequest), ['Uin', 'Sid', 'Skey', 'DeviceID'])
  assert.equal(sent.BaseRequest.Uin, 155217200)
  assert.equal(init.User.UserName, '@me')
  assert.equal(c.s.skey, '@crypt_k2')
  assert.equal(c.s.syncCheckKey, '1_100')
  assert.ok(c.loggedIn)
})

test('login refusal surfaces the server message after trying both logins', async () => {
  const fetch = fakeFetch({
    'GET wx.qq.com/cgi-bin/mmwebwx-bin/webwxnewloginpage': () =>
      new Response('<error><ret>1203</ret><message>当前登录环境异常。为了你的帐号安全，暂时不能登录web微信。</message></error>')
  })
  const c = new WxClient(undefined, { fetch })
  await assert.rejects(c.completeLogin('https://wx.qq.com/cgi-bin/mmwebwx-bin/webwxnewloginpage?ticket=x'), err => {
    assert.ok(err instanceof WxError)
    assert.equal(err.code, 1203)
    assert.match(err.message, /暂时不能登录web微信/)
    assert.deepEqual(err.detail.map(d => d.mode), ['desktop', 'web'])
    return true
  })
  assert.equal(fetch.calls.length, 2)
  assert.equal(c.s.mode, '')
})

const TOO_OLD = '<error><ret>1203</ret><message>当前微信版本过低，暂无法登录，请前往微信官网下载最新的微信 Linux 版后重新登录。</message></error>'

test('UOS "version too low" falls back to a web login on the same scan, and remembers it', async () => {
  const fetch = fakeFetch({
    'GET wx2.qq.com/cgi-bin/mmwebwx-bin/webwxnewloginpage': u =>
      u.searchParams.get('fun') === 'new' ? new Response(LOGIN_XML) : new Response(TOO_OLD),
    'GET login.wx2.qq.com/jslogin': () => new Response('window.QRLogin.code = 200; window.QRLogin.uuid = "U2";')
  })
  const c = new WxClient(undefined, { fetch })
  const r = await c.completeLogin('https://wx2.qq.com/cgi-bin/mmwebwx-bin/webwxnewloginpage?ticket=T@qrticket_0&uuid=UU==&lang=zh_CN&scan=1')
  assert.equal(r.mode, 'web')
  assert.equal(r.refused.length, 1)
  assert.match(r.refused[0].message, /版本过低/)

  const [desktop, web] = fetch.calls
  assert.equal(desktop.headers['client-version'], '2.0.0')
  assert.match(desktop.headers['user-agent'], /UOS/)
  // The retry is the classic web request: same ticket, no UOS headers.
  assert.equal(web.url, 'https://wx2.qq.com/cgi-bin/mmwebwx-bin/webwxnewloginpage?ticket=T@qrticket_0&uuid=UU==&lang=zh_CN&scan=1&fun=new&version=v2')
  assert.equal(web.headers.extspam, undefined)
  assert.equal(web.headers['client-version'], undefined)
  assert.doesNotMatch(web.headers['user-agent'], /UOS/)
  assert.equal(c.s.sid, 'SID1')
  assert.equal(c.s.mode, 'web')

  // Next time the web login goes first and the QR code is requested for it.
  const next = new WxClient(c.snapshot(), { fetch })
  assert.equal(next.mode, 'web')
  await next.getUuid()
  const jslogin = new URL(fetch.calls.at(-1).url)
  assert.equal(jslogin.searchParams.get('redirect_uri'), 'https://wx.qq.com/cgi-bin/mmwebwx-bin/webwxnewloginpage')
  assert.doesNotMatch(fetch.calls.at(-1).headers['user-agent'], /UOS/)
})

test('web retry strips mod=desktop from the redirect', async () => {
  const fetch = fakeFetch({
    'GET wx.qq.com/cgi-bin/mmwebwx-bin/webwxnewloginpage': u => (u.searchParams.get('fun') ? new Response(LOGIN_XML) : new Response(TOO_OLD))
  })
  const c = new WxClient(undefined, { fetch })
  await c.completeLogin('https://wx.qq.com/cgi-bin/mmwebwx-bin/webwxnewloginpage?mod=desktop&ticket=T&uuid=U')
  assert.equal(fetch.calls[1].url, 'https://wx.qq.com/cgi-bin/mmwebwx-bin/webwxnewloginpage?ticket=T&uuid=U&fun=new&version=v2')
})

test('network failures are not retried as the other login; forced mode never falls back', async () => {
  let calls = 0
  const down = new WxClient(undefined, { fetch: async () => { calls++; throw new TypeError('fetch failed') } })
  await assert.rejects(down.completeLogin('https://wx.qq.com/cgi-bin/mmwebwx-bin/webwxnewloginpage?ticket=x'), err => err.step === 'newloginpage' && err.code === undefined)
  assert.equal(calls, 1)

  const fetch = fakeFetch({ 'GET wx.qq.com/cgi-bin/mmwebwx-bin/webwxnewloginpage': () => new Response(TOO_OLD) })
  const forced = new WxClient(undefined, { fetch, loginMode: 'desktop', clientVersion: '2.1.0', extspam: 'X' })
  await assert.rejects(forced.completeLogin('https://wx.qq.com/cgi-bin/mmwebwx-bin/webwxnewloginpage?ticket=x'), err => /版本过低/.test(err.message))
  assert.equal(fetch.calls.length, 1)
  assert.equal(fetch.calls[0].headers['client-version'], '2.1.0')
  assert.equal(fetch.calls[0].headers.extspam, 'X')

  // A session saved before modes were recorded keeps its original browser UA.
  assert.doesNotMatch(new WxClient({ sid: 's', uin: '1' }).ua, /UOS/)
  assert.match(new WxClient().ua, /UOS/)
})

test('synccheck maps 1101 to a logout error and 0/2 to a selector', async () => {
  let reply = 'window.synccheck={retcode:"0",selector:"2"}'
  const fetch = fakeFetch({
    'GET webpush.wx2.qq.com/cgi-bin/mmwebwx-bin/synccheck': () => new Response(reply)
  })
  const c = new WxClient({ host: 'wx2.qq.com', sid: 's', uin: '1', skey: 'k', user: { UserName: '@me' } }, { fetch })
  assert.deepEqual(await c.syncCheck(), { retcode: 0, selector: 2 })
  reply = 'window.synccheck={retcode:"1101",selector:"0"}'
  await assert.rejects(c.syncCheck(), err => err.logout === true && err.code === 1101)
})

test('sendText posts the expected payload and returns MsgID', async () => {
  const fetch = fakeFetch({
    'POST wx.qq.com/cgi-bin/mmwebwx-bin/webwxsendmsg': (u, init) => {
      const body = JSON.parse(init.body)
      assert.equal(body.Msg.Type, 1)
      assert.equal(body.Msg.Content, '你好 👋')
      assert.equal(body.Msg.FromUserName, '@me')
      assert.equal(body.Msg.ToUserName, '@friend')
      assert.equal(body.Msg.LocalID, body.Msg.ClientMsgId)
      return Response.json({ BaseResponse: { Ret: 0 }, MsgID: '9001', LocalID: body.Msg.LocalID })
    }
  })
  const c = new WxClient({ sid: 's', uin: '1', skey: 'k', passTicket: 'p', user: { UserName: '@me' } }, { fetch })
  const r = await c.sendText('@friend', '你好 👋', '17000000000000123')
  assert.deepEqual(r, { msgId: '9001', localId: '17000000000000123' })
})

test('BaseResponse errors become WxError; 1101 marks logout', async () => {
  const fetch = fakeFetch({
    'POST wx.qq.com/cgi-bin/mmwebwx-bin/webwxsync': () => Response.json({ BaseResponse: { Ret: 1101, ErrMsg: '' } })
  })
  const c = new WxClient({ sid: 's', uin: '1', skey: 'k', user: { UserName: '@me' } }, { fetch })
  await assert.rejects(c.sync(), err => err instanceof WxError && err.logout && err.step === 'webwxsync')
})

test('rewrite hook and request counter', async () => {
  const seen = []
  const fetch = async url => {
    seen.push(url)
    return new Response('window.QRLogin.code = 200; window.QRLogin.uuid = "A";')
  }
  let count = 0
  const c = new WxClient(undefined, {
    fetch,
    rewrite: url => url.replace('https://', 'http://127.0.0.1:9/__host/'),
    onRequest: () => count++
  })
  await c.getUuid()
  assert.equal(count, 1)
  assert.match(seen[0], /^http:\/\/127\.0\.0\.1:9\/__host\/login\.wx\.qq\.com\/jslogin\?/)
})

test('media urls carry the current skey', () => {
  const c = new WxClient({ host: 'wx2.qq.com', skey: '@crypt_k', uin: '42', passTicket: 'p%2B', dataTicket: 'd' })
  assert.equal(c.mediaUrl('thumb', { id: '77' }), 'https://wx2.qq.com/cgi-bin/mmwebwx-bin/webwxgetmsgimg?MsgID=77&skey=%40crypt_k&type=slave')
  assert.match(c.mediaUrl('avatar', { user: '@@r', room: true }), /webwxgetheadimg\?username=%40%40r&skey=/)
  assert.match(c.mediaUrl('avatar', { user: '@u', chatroom: 'enc1' }), /webwxgeticon\?username=%40u&skey=%40crypt_k&chatroomid=enc1/)
  const file = new URL(c.mediaUrl('file', { sender: '@f', mediaId: 'M', name: '报告 1.pdf' }))
  assert.equal(file.host, 'file.wx2.qq.com')
  assert.equal(file.searchParams.get('encryfilename'), '报告 1.pdf')
  assert.equal(file.searchParams.get('fromuser'), '42')
})
