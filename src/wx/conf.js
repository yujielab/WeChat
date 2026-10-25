// WeChat web protocol endpoints and constants.
// Adapted from wechat4u (MIT, https://github.com/nodeWechat/wechat4u) src/util/conf.js.

export const APPID = 'wx782c26e4c19acffb'

// Desktop UA and the UOS ("desktop mode") login headers. Without `extspam`
// and `client-version`, accounts registered after 2017 are refused by the
// classic web login. Values are the ones wechat4u 0.7.14 ships.
export const UA =
  'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/111.0.0.0 Safari/537.36'
export const UOS_CLIENT_VERSION = '2.0.0'
export const UOS_EXTSPAM =
  'Go8FCIkFEokFCggwMDAwMDAwMRAGGvAESySibk50w5Wb3uTl2c2h64jVVrV7gNs06GFlWplHQbY/5FfiO++1yH4ykCyNPWKXmco+wfQzK5R98D3so7rJ5LmGFvBLjGceleySrc3SOf2Pc1gVehzJgODeS0lDL3/I/0S2SSE98YgKleq6Uqx6ndTy9yaL9qFxJL7eiA/R3SEfTaW1SBoSITIu+EEkXff+Pv8NHOk7N57rcGk1w0ZzRrQDkXTOXFN2iHYIzAAZPIOY45Lsh+A4slpgnDiaOvRtlQYCt97nmPLuTipOJ8Qc5pM7ZsOsAPPrCQL7nK0I7aPrFDF0q4ziUUKettzW8MrAaiVfmbD1/VkmLNVqqZVvBCtRblXb5FHmtS8FxnqCzYP4WFvz3T0TcrOqwLX1M/DQvcHaGGw0B0y4bZMs7lVScGBFxMj3vbFi2SRKbKhaitxHfYHAOAa0X7/MSS0RNAjdwoyGHeOepXOKY+h3iHeqCvgOH6LOifdHf/1aaZNwSkGotYnYScW8Yx63LnSwba7+hESrtPa/huRmB9KWvMCKbDThL/nne14hnL277EDCSocPu3rOSYjuB9gKSOdVmWsj9Dxb/iZIe+S6AiG29Esm+/eUacSba0k8wn5HhHg9d4tIcixrxveflc8vi2/wNQGVFNsGO6tB5WF0xf/plngOvQ1/ivGV/C1Qpdhzznh0ExAVJ6dwzNg7qIEBaw+BzTJTUuRcPk92Sn6QDn2Pu3mpONaEumacjW4w6ipPnPw+g2TfywJjeEcpSZaP4Q3YV5HG8D6UjWA4GSkBKculWpdCMadx0usMomsSS/74QgpYqcPkmamB4nVv1JxczYITIqItIKjD35IGKAUwAA=='

// The login redirect tells us which data center the account lives on
// (wx.qq.com, wx2.qq.com, wx8.qq.com, web.wechat.com, ...). Every other
// host is derived from it.
export function hostsFor(host = 'wx.qq.com') {
  let login = 'login.wx.qq.com'
  let file = 'file.wx.qq.com'
  let push = 'webpush.weixin.qq.com'
  const m = host.match(/(\w+)(\.qq\.com|\.wechat\.com)$/)
  if (m) {
    let [, prefix, suffix] = m
    if (suffix === '.qq.com') prefix = ['wx', 'wx2', 'wx8'].includes(prefix) ? prefix : 'wx'
    else prefix = ['web', 'web2'].includes(prefix) ? prefix : 'web'
    login = `login.${prefix}${suffix}`
    file = `file.${prefix}${suffix}`
    push = `webpush.${prefix}${suffix}`
  }
  const origin = `https://${host}`
  return { host, origin, login, file, push, cgi: `${origin}/cgi-bin/mmwebwx-bin` }
}

export const QR_LOGIN_URL = uuid => `https://login.weixin.qq.com/l/${uuid}`

export const MSG = {
  TEXT: 1,
  IMAGE: 3,
  VOICE: 34,
  VERIFY: 37,
  POSSIBLE_FRIEND: 40,
  CARD: 42,
  VIDEO: 43,
  EMOTICON: 47,
  LOCATION: 48,
  APP: 49,
  VOIP: 50,
  STATUS_NOTIFY: 51,
  VOIP_NOTIFY: 52,
  VOIP_INVITE: 53,
  MICROVIDEO: 62,
  SYS_NOTICE: 9999,
  SYS: 10000,
  RECALLED: 10002
}

export const APPMSG = {
  TEXT: 1,
  IMG: 2,
  AUDIO: 3,
  VIDEO: 4,
  URL: 5,
  ATTACH: 6,
  OPEN: 7,
  EMOJI: 8,
  REALTIME_LOCATION: 17,
  CHAT_HISTORY: 19,
  MINIPROGRAM: 33,
  MINIPROGRAM_PAGE: 36,
  CHANNELS: 51,
  QUOTE: 57,
  TRANSFER: 2000,
  RED_PACKET: 2001
}

export const STATUS_NOTIFY = {
  READ: 1,
  ENTER_SESSION: 2,
  INITED: 3,
  SYNC_CONV: 4,
  QUIT_SESSION: 5
}

export const CONTACT_FLAG = {
  CONTACT: 1,
  NOTIFY_CLOSE: 512,
  TOP: 2048
}

export const VERIFY_FLAG_BIZ_BRAND = 8

// synccheck / BaseResponse codes that mean the web session is gone.
export const LOGOUT_CODES = new Set([1100, 1101, 1102])

export const SPECIAL_USERS = new Set([
  'newsapp', 'fmessage', 'filehelper', 'weibo', 'qqmail', 'tmessage', 'qmessage', 'qqsync',
  'floatbottle', 'lbsapp', 'shakeapp', 'medianote', 'qqfriend', 'readerapp', 'blogapp',
  'facebookapp', 'masssendapp', 'meishiapp', 'feedsapp', 'voip', 'blogappweixin', 'weixin',
  'brandsessionholder', 'weixinreminder', 'wxid_novlwrv3lqwv11', 'gh_22b87fa7cb3c',
  'officialaccounts', 'notification_messages', 'wxitil', 'userexperience_alarm'
])

// Chats people actually talk in; the rest of SPECIAL_USERS are system feeds.
export const CHATTABLE_SPECIALS = new Set(['filehelper'])
