#!/usr/bin/env node
// Local stand-in for the WeChat web servers, for development and UI testing
// only. The Worker talks to it when WX_MOCK_ORIGIN is set (see dev-mock.mjs):
// every https://<host>/<path> request becomes http://127.0.0.1:PORT/__host/<host>/<path>.
//
// Control endpoints (for scripts):
//   POST /__ctl/scan        mark the current QR code as scanned
//   POST /__ctl/confirm     confirm the login on the "phone"
//   POST /__ctl/incoming    {from, text, type?, member?, w?, h?} queue an incoming message
//   POST /__ctl/logout      make the next synccheck report 1101
//   GET  /__ctl/sent        messages the client sent

import http from 'node:http'

const PORT = Number(process.env.MOCK_PORT || 8790)
const AUTO = process.env.MOCK_AUTO === '1'
const HOLD_MS = Number(process.env.MOCK_HOLD_MS || 8000)

const SID = 'MockSid0001'
const UIN = '2088001234'
const SKEY = '@crypt_mock_skey'
const PASS = 'mock%2Bpass%3D'
const SELF = '@a1b2c3d4e5f6self'

let seq = 1
const id = p => `@${p}${(seq++).toString(16).padStart(6, '0')}${'0'.repeat(20)}`.slice(0, 33)
let msgSeq = 5_000_000_000_000_000_000n

const nextMsgId = () => String((msgSeq += 1n))

const PEOPLE = [
  ['林晓', 'linxiao', 'LX', '晓'], ['陈一鸣', 'chenyiming', 'CYM'], ['王思远', 'wangsiyuan', 'WSY'],
  ['周可', 'zhouke', 'ZK'], ['妈妈', 'mama', 'MM'], ['Emma Li', 'emmali', 'EL'], ['赵磊', 'zhaolei', 'ZL'],
  ['孙悦', 'sunyue', 'SY'], ['何以安', 'heyian', 'HYA'], ['许诺', 'xunuo', 'XN'], ['唐果', 'tangguo', 'TG'],
  ['顾北', 'gubei', 'GB'], ['叶舟', 'yezhou', 'YZ'], ['沈清', 'shenqing', 'SQ'], ['陆川', 'luchuan', 'LC'],
  ['Kevin', 'kevin', 'K'], ['宋雨', 'songyu', 'SY'], ['韩冬', 'handong', 'HD'], ['方圆', 'fangyuan', 'FY'],
  ['程橙', 'chengcheng', 'CC'], ['白露', 'bailu', 'BL'], ['苏一', 'suyi', 'SY'], ['江南', 'jiangnan', 'JN'],
  ['夏天', 'xiatian', 'XT'], ['秦朗', 'qinlang', 'QL'], ['邓佳', 'dengjia', 'DJ'], ['梁晨', 'liangchen', 'LC'],
  ['冯可欣', 'fengkexin', 'FKX'], ['曹阳', 'caoyang', 'CY'], ['袁野', 'yuanye', 'YY']
]

const contacts = new Map()
const people = PEOPLE.map(([nick, py, pyi], i) => {
  const c = {
    Uin: 0, UserName: id('f'), NickName: nick, HeadImgUrl: '', ContactFlag: i === 0 ? 3 | 2048 : 3,
    MemberCount: 0, MemberList: [], RemarkName: i === 4 ? '妈妈' : '', Sex: i % 2 + 1,
    Signature: i === 0 ? '慢慢来，比较快' : '', VerifyFlag: 0, PYInitial: pyi, PYQuanPin: py,
    RemarkPYInitial: '', RemarkPYQuanPin: '', StarFriend: 0, Statues: 0, Province: '上海', City: '徐汇',
    Alias: '', DisplayName: '', EncryChatRoomId: '', KeyWord: ''
  }
  c.HeadImgUrl = `/cgi-bin/mmwebwx-bin/webwxgeticon?seq=${1000 + i}&username=${c.UserName}&skey=${SKEY}`
  contacts.set(c.UserName, c)
  return c
})

function room(name, py, members, extra = {}) {
  const c = {
    Uin: 0, UserName: `@@${id('r').slice(1)}`, NickName: name, ContactFlag: 3, MemberCount: members.length,
    MemberList: members.map((p, i) => ({
      Uin: 0, UserName: p.UserName, NickName: p.NickName, AttrStatus: 0, PYQuanPin: p.PYQuanPin,
      RemarkPYQuanPin: '', MemberStatus: 0, DisplayName: i === 1 ? `${p.NickName}（组长）` : '', KeyWord: ''
    })),
    RemarkName: '', Statues: 1, PYInitial: '', PYQuanPin: py, VerifyFlag: 0, EncryChatRoomId: `@enc${seq++}`,
    Signature: '', Province: '', City: '', Alias: '', DisplayName: '', KeyWord: '', ...extra
  }
  c.HeadImgUrl = `/cgi-bin/mmwebwx-bin/webwxgetheadimg?seq=${seq++}&username=${c.UserName}&skey=${SKEY}`
  contacts.set(c.UserName, c)
  return c
}

const hiking = room('周末徒步小分队', 'zhoumotubuxiaofendui', people.slice(0, 9))
const design = room('产品设计组', 'chanpinshejizu', [people[1], people[2], people[5], people[8], people[13]], { ContactFlag: 3 | 2048 })
const family = room('相亲相爱一家人', 'xiangqinxiangaiyijiaren', [people[4], people[19], people[20]])
const classmates = room('大学同学', 'daxuetongxue', people.slice(10, 30), { Statues: 0 })

const filehelper = {
  UserName: 'filehelper', NickName: '文件传输助手', HeadImgUrl: `/cgi-bin/mmwebwx-bin/webwxgeticon?seq=1&username=filehelper&skey=${SKEY}`,
  ContactFlag: 3, PYQuanPin: 'wenjianchuanshuzhushou', PYInitial: 'WJCSZS', VerifyFlag: 0, MemberList: []
}
contacts.set('filehelper', filehelper)
const news = {
  UserName: id('g'), NickName: '少数派', HeadImgUrl: `/cgi-bin/mmwebwx-bin/webwxgeticon?seq=2&username=x&skey=${SKEY}`,
  ContactFlag: 3, PYQuanPin: 'shaoshupai', PYInitial: 'SSP', VerifyFlag: 24, MemberList: []
}
contacts.set(news.UserName, news)

const self = {
  Uin: Number(UIN), UserName: SELF, NickName: '小宇', HeadImgUrl: `/cgi-bin/mmwebwx-bin/webwxgeticon?seq=9&username=${SELF}&skey=${SKEY}`,
  RemarkName: '', PYInitial: 'XY', PYQuanPin: 'xiaoyu', Sex: 1, Signature: '做好看的东西'
}

// ---------------------------------------------------------------- state

let qr = null // { uuid, state: 'waiting'|'scanned'|'confirmed', at }
let loggedIn = false
let forceLogout = false
const queue = []
const waiters = []
const sent = []
let syncKey = 1

function enqueue(raw) {
  queue.push(raw)
  while (waiters.length) waiters.shift()()
}

function message({ from, to = SELF, type = 1, text = '', member, Content, ...rest }) {
  const isRoom = from.startsWith('@@')
  const body = Content ?? text
  const content = isRoom && member ? `${member}:<br/>${body}` : body
  return {
    MsgId: nextMsgId(), FromUserName: from, ToUserName: to, MsgType: type, Content: content,
    Status: 3, ImgStatus: 1, CreateTime: Math.floor(Date.now() / 1000), VoiceLength: 0, PlayLength: 0,
    FileName: '', FileSize: '', MediaId: '', Url: '', AppMsgType: 0, StatusNotifyCode: 0,
    StatusNotifyUserName: '', RecommendInfo: {}, ForwardFlag: 0, AppInfo: { AppID: '', Type: 0 },
    HasProductId: 0, Ticket: '', ImgHeight: 0, ImgWidth: 0, SubMsgType: 0, NewMsgId: 0, OriContent: '',
    ...rest
  }
}

const esc = s => s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;')

function seedHistory() {
  const now = Math.floor(Date.now() / 1000)
  const at = (minsAgo, raw) => ({ ...raw, CreateTime: now - minsAgo * 60 })
  const [lin, chen, wang, zhou, mom, emma] = people
  const list = [
    at(60 * 26, message({ from: lin.UserName, text: '周末去不去西湖边走走？' })),
    at(60 * 26 - 3, message({ from: SELF, to: lin.UserName, text: '可以呀，周六上午？' })),
    at(60 * 26 - 4, message({ from: lin.UserName, text: '好，九点地铁站见<span class="emoji emoji1f44c"></span>' })),
    at(60 * 3, message({ from: mom.UserName, text: '降温了，记得多穿点衣服' })),
    at(60 * 3 - 1, message({ from: mom.UserName, type: 3, ImgWidth: 1080, ImgHeight: 1440 })),
    at(60 * 3 - 30, message({ from: SELF, to: mom.UserName, text: '知道啦，今天穿了大衣' })),
    at(55, message({ from: design.UserName, member: chen.UserName, text: '新版首页的稿子我放到群文件了，大家看看' })),
    at(54, message({
      from: design.UserName, member: chen.UserName, type: 49, AppMsgType: 6, FileName: '首页改版 v3.pdf', FileSize: '4823411',
      MediaId: '@crypt_mock_media_1', Content: esc('<msg><appmsg><title>首页改版 v3.pdf</title><type>6</type><appattach><totallen>4823411</totallen><fileext>pdf</fileext></appattach></appmsg></msg>')
    })),
    at(50, message({ from: design.UserName, member: wang.UserName, text: '顶部导航的玻璃效果再轻一点会更好，正文对比度要保证' })),
    at(49, message({ from: design.UserName, member: emma.UserName, text: '同意，按钮按压的回弹也可以再柔和一些' })),
    at(48, message({ from: SELF, to: design.UserName, text: '收到，我下午改一版' })),
    at(30, message({
      from: news.UserName, type: 49, AppMsgType: 5, FileName: '如何在 iPhone 上用好折叠屏', Url: 'https://example.com/article',
      Content: esc('<msg><appmsg><title>如何在 iPhone 上用好折叠屏</title><des>展开即是小平板：分屏、拖放和连续性的 12 个技巧</des><url>https://example.com/article</url><type>5</type></appmsg></msg>')
    })),
    at(20, message({ from: hiking.UserName, member: zhou.UserName, text: '这周六天气不错，有人报名吗？' })),
    at(19, message({ from: hiking.UserName, member: lin.UserName, text: '+1' })),
    at(18, message({ from: hiking.UserName, member: people[6].UserName, type: 3, ImgWidth: 1600, ImgHeight: 900 })),
    at(17, message({ from: hiking.UserName, member: people[6].UserName, text: '上次拍的，九溪那段路特别好走' })),
    at(12, message({ from: hiking.UserName, member: people[7].UserName, type: 34, VoiceLength: 7000 })),
    at(8, message({ from: zhou.UserName, text: '明天的会改到下午三点了' })),
    at(7, message({ from: zhou.UserName, text: '会议室还是 5F 那间' })),
    at(4, message({ from: chen.UserName, type: 47, Content: esc('<msg><emoji md5="abc" width="200" height="200" /></msg>') })),
    at(2, message({ from: classmates.UserName, member: people[11].UserName, text: '下个月十周年聚会，大家记得填问卷' })),
    at(1, message({ from: wang.UserName, text: '那个链接我发你了，有空看看～' }))
  ]
  for (const m of list) enqueue(m)
}

// ---------------------------------------------------------------- helpers

const svgAvatar = (seedStr) => {
  let h = 0
  for (const ch of seedStr) h = (h * 31 + ch.codePointAt(0)) >>> 0
  const hue = h % 360
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 120 120"><defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="hsl(${hue} 70% 68%)"/><stop offset="1" stop-color="hsl(${(hue + 40) % 360} 65% 52%)"/></linearGradient></defs><rect width="120" height="120" fill="url(#g)"/><circle cx="60" cy="48" r="20" fill="rgba(255,255,255,.85)"/><path d="M22 112c6-24 22-36 38-36s32 12 38 36" fill="rgba(255,255,255,.85)"/></svg>`
}

const svgPhoto = (w, h, seedStr) => {
  let n = 0
  for (const ch of seedStr) n = (n * 33 + ch.codePointAt(0)) >>> 0
  const hue = n % 360
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${w} ${h}" width="${w}" height="${h}"><defs><linearGradient id="s" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="hsl(${hue} 60% 78%)"/><stop offset=".6" stop-color="hsl(${(hue + 30) % 360} 55% 62%)"/><stop offset="1" stop-color="hsl(${(hue + 60) % 360} 45% 38%)"/></linearGradient></defs><rect width="${w}" height="${h}" fill="url(#s)"/><circle cx="${w * 0.72}" cy="${h * 0.28}" r="${Math.min(w, h) * 0.09}" fill="rgba(255,250,235,.9)"/><path d="M0 ${h * 0.78} L${w * 0.25} ${h * 0.52} L${w * 0.45} ${h * 0.7} L${w * 0.68} ${h * 0.45} L${w} ${h * 0.8} V${h} H0Z" fill="hsl(${(hue + 120) % 360} 30% 28% / .85)"/></svg>`
}

function silentWav(seconds = 1) {
  const rate = 8000
  const n = rate * seconds
  const buf = Buffer.alloc(44 + n)
  buf.write('RIFF', 0); buf.writeUInt32LE(36 + n, 4); buf.write('WAVE', 8); buf.write('fmt ', 12)
  buf.writeUInt32LE(16, 16); buf.writeUInt16LE(1, 20); buf.writeUInt16LE(1, 22); buf.writeUInt32LE(rate, 24)
  buf.writeUInt32LE(rate, 28); buf.writeUInt16LE(1, 32); buf.writeUInt16LE(8, 34); buf.write('data', 36); buf.writeUInt32LE(n, 40)
  for (let i = 0; i < n; i++) buf[44 + i] = 128 + Math.round(20 * Math.sin(i / 6) * Math.exp(-i / (rate * 0.6)))
  return buf
}

const readBody = req => new Promise(resolve => {
  const chunks = []
  req.on('data', c => chunks.push(c))
  req.on('end', () => resolve(Buffer.concat(chunks)))
})

function send(res, status, body, type = 'application/json', headers = {}) {
  const data = typeof body === 'string' || Buffer.isBuffer(body) ? body : JSON.stringify(body)
  res.writeHead(status, { 'content-type': type, ...headers })
  res.end(data)
}

const ok = extra => ({ BaseResponse: { Ret: 0, ErrMsg: '' }, ...extra })
const syncKeyObj = () => ({ Count: 2, List: [{ Key: 1, Val: syncKey }, { Key: 2, Val: syncKey + 100 }] })

const findMsg = (() => {
  const all = new Map()
  return { add: m => all.set(m.MsgId, m), get: id => all.get(id) }
})()

// ---------------------------------------------------------------- server

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url, `http://127.0.0.1:${PORT}`)
  const body = await readBody(req)

  if (url.pathname.startsWith('/__ctl/')) {
    const cmd = url.pathname.slice(7)
    const payload = body.length ? JSON.parse(body.toString() || '{}') : {}
    if (cmd === 'scan' && qr) qr.state = 'scanned'
    else if (cmd === 'confirm' && qr) qr.state = 'confirmed'
    else if (cmd === 'logout') forceLogout = true
    else if (cmd === 'sent') return send(res, 200, sent)
    else if (cmd === 'state') return send(res, 200, { qr, loggedIn, queued: queue.length })
    else if (cmd === 'incoming') {
      const from = payload.from === 'hiking' ? hiking.UserName
        : payload.from === 'design' ? design.UserName
          : payload.from === 'family' ? family.UserName
            : payload.from === 'filehelper' ? 'filehelper'
              : people[Number(payload.from) || 0].UserName
      const member = payload.member !== undefined ? people[Number(payload.member)].UserName : undefined
      const m = message({ from, member, text: payload.text || '', type: payload.type || 1, ImgWidth: payload.w || 0, ImgHeight: payload.h || 0, VoiceLength: payload.voice || 0 })
      findMsg.add(m)
      enqueue(m)
      return send(res, 200, { ok: true, id: m.MsgId })
    }
    return send(res, 200, { ok: true })
  }

  const m = /^\/__host\/([^/]+)(\/.*)$/.exec(url.pathname)
  if (!m) return send(res, 404, 'not found', 'text/plain')
  const [, host, path] = m
  const q = url.searchParams
  const json = body.length && (req.headers['content-type'] || '').includes('json') ? JSON.parse(body.toString()) : null

  // ---- login
  if (path === '/jslogin') {
    qr = { uuid: `Mock${Math.random().toString(36).slice(2, 8)}==`, state: 'waiting', at: Date.now() }
    if (AUTO) {
      setTimeout(() => { if (qr) qr.state = 'scanned' }, 3000)
      setTimeout(() => { if (qr) qr.state = 'confirmed' }, 6000)
    }
    return send(res, 200, `window.QRLogin.code = 200; window.QRLogin.uuid = "${qr.uuid}";`, 'text/javascript')
  }
  if (path === '/cgi-bin/mmwebwx-bin/login') {
    const deadline = Date.now() + 4000
    while (qr && qr.uuid === q.get('uuid') && qr.state === 'waiting' && Date.now() < deadline) await new Promise(r => setTimeout(r, 200))
    if (!qr || qr.uuid !== q.get('uuid')) return send(res, 200, 'window.code=400;', 'text/javascript')
    if (qr.state === 'waiting') return send(res, 200, 'window.code=408;', 'text/javascript')
    if (qr.state === 'scanned' && q.get('tip') === '1') {
      const av = Buffer.from(svgAvatar(SELF)).toString('base64')
      return send(res, 200, `window.code=201;window.userAvatar = 'data:image/svg+xml;base64,${av}';`, 'text/javascript')
    }
    if (qr.state === 'scanned') {
      const until = Date.now() + 4000
      while (qr.state === 'scanned' && Date.now() < until) await new Promise(r => setTimeout(r, 200))
      if (qr.state === 'scanned') return send(res, 200, 'window.code=408;', 'text/javascript')
    }
    return send(res, 200,
      `window.code=200;\nwindow.redirect_uri="https://wx2.qq.com/cgi-bin/mmwebwx-bin/webwxnewloginpage?ticket=MockTicket@qrticket_0&uuid=${qr.uuid}&lang=zh_CN&scan=${Math.floor(Date.now() / 1000)}";`,
      'text/javascript')
  }
  if (path === '/cgi-bin/mmwebwx-bin/webwxnewloginpage') {
    if (!req.headers.extspam || req.headers['client-version'] !== '2.0.0') {
      return send(res, 200, '<error><ret>1203</ret><message>为了你的帐号安全，此微信号不能登录网页微信。</message></error>', 'text/plain')
    }
    loggedIn = true
    forceLogout = false
    qr = null
    return send(res, 301,
      `<error><ret>0</ret><message></message><skey>${SKEY}</skey><wxsid>${SID}</wxsid><wxuin>${UIN}</wxuin><pass_ticket>${PASS}</pass_ticket><isgrayscale>1</isgrayscale></error>`,
      'text/plain', {
        location: 'https://wx2.qq.com/',
        'set-cookie': [`wxuin=${UIN}; Domain=wx2.qq.com; Path=/`, `wxsid=${SID}; Domain=wx2.qq.com; Path=/`, 'webwx_data_ticket=MockDataTicket+1; Domain=.qq.com; Path=/']
      })
  }

  // ---- everything below needs the session
  const authed = (q.get('skey') === SKEY) || json?.BaseRequest?.Sid === SID || q.get('sid') === SID ||
    (req.headers.cookie || '').includes(`wxsid=${SID}`)
  if (!authed || !loggedIn) {
    if (path.endsWith('/synccheck')) return send(res, 200, 'window.synccheck={retcode:"1101",selector:"0"}', 'text/javascript')
    return send(res, 200, ok({ BaseResponse: { Ret: 1101, ErrMsg: '' } }))
  }

  if (path === '/cgi-bin/mmwebwx-bin/webwxinit') {
    setTimeout(seedHistory, 1500)
    const recent = [hiking, design, people[0], people[3], people[4], filehelper, news, people[2]]
    return send(res, 200, ok({
      Count: recent.length, ContactList: recent.map(c => ({ ...c, MemberList: [] })), SyncKey: syncKeyObj(), User: self,
      ChatSet: recent.map(c => c.UserName).join(','), SKey: SKEY, ClientVersion: 0, SystemTime: Math.floor(Date.now() / 1000)
    }))
  }
  if (path === '/cgi-bin/mmwebwx-bin/webwxstatusnotify') return send(res, 200, ok({ MsgID: nextMsgId() }))
  if (path === '/cgi-bin/mmwebwx-bin/webwxgetcontact') {
    const all = [...contacts.values()].map(c => ({ ...c, MemberList: [] }))
    return send(res, 200, ok({ MemberCount: all.length, MemberList: all, Seq: 0 }))
  }
  if (path === '/cgi-bin/mmwebwx-bin/webwxbatchgetcontact') {
    const list = (json?.List || []).map(x => contacts.get(x.UserName)).filter(Boolean)
    return send(res, 200, ok({ Count: list.length, ContactList: list }))
  }
  if (path === '/cgi-bin/mmwebwx-bin/synccheck') {
    if (forceLogout) return send(res, 200, 'window.synccheck={retcode:"1101",selector:"0"}', 'text/javascript')
    if (!queue.length) {
      await new Promise(resolve => {
        const t = setTimeout(resolve, HOLD_MS)
        waiters.push(() => { clearTimeout(t); resolve() })
      })
    }
    if (forceLogout) return send(res, 200, 'window.synccheck={retcode:"1101",selector:"0"}', 'text/javascript')
    return send(res, 200, `window.synccheck={retcode:"0",selector:"${queue.length ? 2 : 0}"}`, 'text/javascript')
  }
  if (path === '/cgi-bin/mmwebwx-bin/webwxsync') {
    const batch = queue.splice(0, queue.length)
    batch.forEach(findMsg.add)
    syncKey++
    return send(res, 200, ok({
      AddMsgCount: batch.length, AddMsgList: batch, ModContactCount: 0, ModContactList: [], DelContactCount: 0,
      DelContactList: [], ModChatRoomMemberCount: 0, ModChatRoomMemberList: [], ContinueFlag: 0,
      SyncKey: syncKeyObj(), SyncCheckKey: syncKeyObj(), SKey: ''
    }))
  }
  if (path === '/cgi-bin/mmwebwx-bin/webwxsendmsg') {
    const msg = json.Msg
    const id = nextMsgId()
    sent.push({ type: 'text', to: msg.ToUserName, content: msg.Content, id })
    // Echo it back through sync like the real server does.
    setTimeout(() => enqueue(message({ from: SELF, to: msg.ToUserName, text: esc(msg.Content).replace(/\n/g, '<br/>'), MsgId: id })), 300)
    if (msg.Content.includes('自动回复')) {
      setTimeout(() => {
        const r = message({ from: msg.ToUserName.startsWith('@@') ? msg.ToUserName : msg.ToUserName, member: msg.ToUserName.startsWith('@@') ? people[1].UserName : undefined, text: '收到～这是一条自动回复' })
        enqueue(r)
      }, 2500)
    }
    return send(res, 200, ok({ MsgID: id, LocalID: msg.LocalID }))
  }
  if (path === '/cgi-bin/mmwebwx-bin/webwxuploadmedia') {
    return send(res, 200, ok({ MediaId: `@crypt_upload_${Date.now()}`, StartPos: body.length, CDNThumbImgHeight: 100, CDNThumbImgWidth: 100 }))
  }
  if (path === '/cgi-bin/mmwebwx-bin/webwxsendmsgimg') {
    const id = nextMsgId()
    sent.push({ type: 'image', to: json.Msg.ToUserName, media: json.Msg.MediaId, id })
    return send(res, 200, ok({ MsgID: id, LocalID: json.Msg.LocalID }))
  }
  if (path === '/cgi-bin/mmwebwx-bin/webwxrevokemsg') {
    setTimeout(() => enqueue(message({
      from: SELF, to: json.ToUserName, type: 10002,
      Content: esc(`<sysmsg type="revokemsg"><revokemsg><session>${json.ToUserName}</session><msgid>${json.SvrMsgId}</msgid><replacemsg><![CDATA[你撤回了一条消息]]></replacemsg></revokemsg></sysmsg>`)
    })), 300)
    return send(res, 200, ok({ Introduction: '', SysWording: '' }))
  }
  if (path === '/cgi-bin/mmwebwx-bin/webwxoplog') return send(res, 200, ok())
  if (path === '/cgi-bin/mmwebwx-bin/webwxlogout') {
    loggedIn = false
    return send(res, 200, '', 'text/plain')
  }
  if (path === '/cgi-bin/mmwebwx-bin/webwxgeticon' || path === '/cgi-bin/mmwebwx-bin/webwxgetheadimg') {
    return send(res, 200, svgAvatar(q.get('username') || 'x'), 'image/svg+xml')
  }
  if (path === '/cgi-bin/mmwebwx-bin/webwxgetmsgimg') {
    const msg = findMsg.get(q.get('MsgID'))
    if (msg?.MsgType === 47) {
      return send(res, 200, `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 200"><circle cx="100" cy="100" r="88" fill="#ffd25a"/><circle cx="72" cy="84" r="12" fill="#3a2a10"/><circle cx="128" cy="84" r="12" fill="#3a2a10"/><path d="M60 122c16 26 64 26 80 0" stroke="#3a2a10" stroke-width="10" fill="none" stroke-linecap="round"/></svg>`, 'image/svg+xml')
    }
    const w = msg?.ImgWidth || 800
    const h = msg?.ImgHeight || 600
    const scale = q.get('type') === 'slave' ? 0.25 : 1
    return send(res, 200, svgPhoto(Math.round(w * scale), Math.round(h * scale), q.get('MsgID') || 'p'), 'image/svg+xml')
  }
  if (path === '/cgi-bin/mmwebwx-bin/webwxgetvoice') return send(res, 200, silentWav(2), 'audio/wav')
  if (path === '/cgi-bin/mmwebwx-bin/webwxgetmedia') return send(res, 200, Buffer.from('%PDF-1.4 mock'), 'application/pdf')
  return send(res, 200, ok())
})

server.listen(PORT, '127.0.0.1', () => {
  console.log(`mock WeChat listening on http://127.0.0.1:${PORT}${AUTO ? ' (auto login)' : ''}`)
})
