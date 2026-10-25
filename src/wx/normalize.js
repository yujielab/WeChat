// Turns raw web-protocol contacts and messages into the compact shapes the
// app stores and sends to the browser. All text is plain text here — the UI
// renders it with text nodes only, never as HTML.

import {
  MSG, APPMSG, STATUS_NOTIFY, CONTACT_FLAG, VERIFY_FLAG_BIZ_BRAND, SPECIAL_USERS, CHATTABLE_SPECIALS
} from './conf.js'
import { contentToText, convertEmoji, decodeEntities, xmlText, xmlAttr } from './parse.js'

export const isRoomId = id => typeof id === 'string' && (id.startsWith('@@') || id.endsWith('@chatroom'))

const clean = s => decodeEntities(convertEmoji(s || ''))

export function normContact(c) {
  const id = c.UserName
  const room = isRoomId(id)
  const nick = clean(c.NickName)
  const remark = clean(c.RemarkName)
  const members = room && Array.isArray(c.MemberList)
    ? c.MemberList.map(m => ({
        id: m.UserName,
        nick: clean(m.NickName),
        dn: clean(m.DisplayName)
      }))
    : undefined
  const fallbackName = room && members?.length
    ? members.slice(0, 3).map(m => m.dn || m.nick).filter(Boolean).join('、')
    : ''
  return {
    id,
    name: remark || nick || fallbackName || (room ? '群聊' : id),
    nick,
    remark,
    room,
    biz: Boolean(c.VerifyFlag & VERIFY_FLAG_BIZ_BRAND),
    special: SPECIAL_USERS.has(id) && !CHATTABLE_SPECIALS.has(id),
    friend: Boolean(c.ContactFlag & CONTACT_FLAG.CONTACT),
    pinned: Boolean(c.ContactFlag & CONTACT_FLAG.TOP),
    muted: room ? c.Statues === 0 : Boolean(c.ContactFlag & CONTACT_FLAG.NOTIFY_CLOSE),
    py: String(c.RemarkPYQuanPin || c.PYQuanPin || '').toLowerCase(),
    pyi: String(c.RemarkPYInitial || c.PYInitial || '').toLowerCase(),
    alias: c.Alias || '',
    sex: c.Sex || 0,
    sig: clean(c.Signature),
    region: [c.Province, c.City].filter(Boolean).join(' '),
    img: c.HeadImgUrl || '',
    enc: c.EncryChatRoomId || '',
    count: room ? (c.MemberCount || members?.length || 0) : 0,
    members
  }
}

/** Merge a fresh contact over a stored one without losing group members. */
export function mergeContact(prev, next) {
  if (!prev) return next
  const out = { ...prev, ...next }
  if (!next.members?.length && prev.members?.length) {
    out.members = prev.members
    out.count = next.count || prev.count
    if (!next.remark && !next.nick && prev.name) out.name = prev.name
  }
  return out
}

export function memberName(room, memberId, contacts) {
  const m = room?.members?.find(x => x.id === memberId)
  const friend = contacts?.get?.(memberId)
  return m?.dn || friend?.remark || m?.nick || friend?.nick || ''
}

const SENDER_PREFIX = /^(@[0-9A-Za-z]+|[A-Za-z][\w-]{2,}):<br\s*\/?>/

/**
 * @param raw   AddMsgList entry
 * @param ctx   { self, contacts: Map<id, contact> }
 * @returns normalized message, or { kind: 'notify', ... } for status notifications
 */
export function normMessage(raw, ctx) {
  const type = Number(raw.MsgType)
  const from = raw.FromUserName || ''
  const to = raw.ToUserName || ''
  const out = from === ctx.self || from === ''

  if (type === MSG.STATUS_NOTIFY) {
    return {
      kind: 'notify',
      code: Number(raw.StatusNotifyCode),
      chat: to,
      targets: String(raw.StatusNotifyUserName || '').split(',').filter(Boolean)
    }
  }

  const chat = out ? to : from
  const room = isRoomId(chat)
  let content = raw.Content || ''
  let sender = out ? ctx.self : chat

  if (room && !out && type !== MSG.SYS && type !== MSG.RECALLED) {
    const m = SENDER_PREFIX.exec(content)
    if (m) {
      sender = m[1]
      content = content.slice(m[0].length)
    }
  }

  const base = {
    id: String(raw.MsgId || raw.NewMsgId || ''),
    chat,
    ts: (Number(raw.CreateTime) || Math.floor(Date.now() / 1000)) * 1000,
    out,
    from: sender,
    fromName: ''
  }

  if (room && !out && sender !== chat) base.fromName = memberName(ctx.contacts?.get(chat), sender, ctx.contacts)

  return { ...base, ...body(type, raw, content, ctx) }
}

function body(type, raw, content, ctx) {
  switch (type) {
    case MSG.TEXT: {
      if (Number(raw.SubMsgType) === MSG.LOCATION) return location(raw, content)
      return { type: 'text', text: contentToText(content) }
    }
    case MSG.IMAGE:
      return { type: 'image', w: Number(raw.ImgWidth) || 0, h: Number(raw.ImgHeight) || 0 }
    case MSG.VOICE:
      return { type: 'voice', dur: Number(raw.VoiceLength) || 0 }
    case MSG.VIDEO:
    case MSG.MICROVIDEO:
      return { type: 'video', dur: Number(raw.PlayLength) || 0, w: Number(raw.ImgWidth) || 0, h: Number(raw.ImgHeight) || 0 }
    case MSG.EMOTICON: {
      const xml = decodeEntities(content)
      if (Number(raw.HasProductId)) return { type: 'text', text: '[表情]', note: 'store-sticker' }
      return {
        type: 'sticker',
        w: Number(xmlAttr(xml, 'emoji', 'width')) || Number(raw.ImgWidth) || 0,
        h: Number(xmlAttr(xml, 'emoji', 'height')) || Number(raw.ImgHeight) || 0
      }
    }
    case MSG.LOCATION:
      return location(raw, content)
    case MSG.CARD: {
      const r = raw.RecommendInfo || {}
      return {
        type: 'card',
        title: clean(r.NickName) || '个人名片',
        desc: [r.Province, r.City].filter(Boolean).join(' '),
        text: `[名片] ${clean(r.NickName)}`
      }
    }
    case MSG.APP:
      return appMessage(raw, content)
    case MSG.SYS:
    case MSG.SYS_NOTICE:
      return { type: 'system', text: contentToText(content) }
    case MSG.RECALLED: {
      const xml = decodeEntities(content)
      return {
        type: 'recall',
        target: xmlText(xml, 'msgid') || xmlText(xml, 'oldmsgid'),
        text: xmlText(xml, 'replacemsg') || '撤回了一条消息'
      }
    }
    case MSG.VERIFY: {
      const r = raw.RecommendInfo || {}
      return { type: 'system', text: `${clean(r.NickName) || '有人'} 请求添加你为朋友，请在手机上处理` }
    }
    case MSG.VOIP:
    case MSG.VOIP_NOTIFY:
    case MSG.VOIP_INVITE:
      return { type: 'system', text: '[语音/视频通话] 请在手机上查看' }
    case MSG.POSSIBLE_FRIEND:
      return { type: 'ignore' }
    default:
      return { type: 'unknown', text: '[暂不支持的消息，请在手机上查看]', raw: type }
  }
}

function location(raw, content) {
  const text = contentToText(content)
  const label = text.split('\n')[0].replace(/:$/, '')
  return { type: 'location', title: label || '位置', url: raw.Url || '' }
}

function appMessage(raw, content) {
  const xml = decodeEntities(content)
  const appType = Number(raw.AppMsgType) || Number(xmlText(xml, 'type')) || 0
  const title = xmlText(xml, 'title') || clean(raw.FileName)
  const desc = xmlText(xml, 'des')
  const url = xmlText(xml, 'url') || raw.Url || ''
  const source = xmlText(xml, 'sourcedisplayname') || xmlText(xml, 'appname') || ''
  switch (appType) {
    case APPMSG.ATTACH:
      return {
        type: 'file',
        name: clean(raw.FileName) || title || '文件',
        size: Number(raw.FileSize) || Number(xmlText(xml, 'totallen')) || 0,
        mediaId: raw.MediaId || xmlText(xml, 'attachid'),
        ext: (xmlText(xml, 'fileext') || '').toLowerCase()
      }
    case APPMSG.QUOTE: {
      const refer = /<refermsg>([\s\S]*?)<\/refermsg>/.exec(xml)?.[1] || ''
      const referType = Number(xmlText(refer, 'type'))
      let quoted = xmlText(refer, 'content')
      if (referType === MSG.IMAGE) quoted = '[图片]'
      else if (referType === MSG.APP) quoted = xmlText(decodeEntities(quoted), 'title') || '[链接]'
      else if (referType && referType !== MSG.TEXT) quoted = '[消息]'
      quoted = quoted.replace(/^[\w-]+:\n/, '')
      return {
        type: 'text',
        text: title,
        quote: { name: xmlText(refer, 'displayname'), text: quoted }
      }
    }
    case APPMSG.TRANSFER:
      return { type: 'money', kind: 'transfer', title: xmlText(xml, 'feedesc') || '转账', desc: desc || '请在手机上查看' }
    case APPMSG.RED_PACKET:
      return { type: 'money', kind: 'redpacket', title: title || '微信红包', desc: '请在手机上查看' }
    case APPMSG.EMOJI:
      return { type: 'sticker', w: 0, h: 0 }
    case APPMSG.REALTIME_LOCATION:
      return { type: 'system', text: '[共享实时位置] 请在手机上查看' }
    case APPMSG.MINIPROGRAM:
    case APPMSG.MINIPROGRAM_PAGE:
      return { type: 'link', title: title || '小程序', desc, url: '', source: source || '小程序' }
    case APPMSG.CHAT_HISTORY:
      return { type: 'link', title: title || '聊天记录', desc, url: '', source: '聊天记录' }
    case APPMSG.CHANNELS:
      return { type: 'link', title: title || '视频号', desc, url: '', source: '视频号' }
    case APPMSG.TEXT:
      return { type: 'text', text: title }
    default:
      return { type: 'link', title: title || '[链接]', desc, url, source }
  }
}

const PREVIEW = {
  image: () => '[图片]',
  voice: m => `[语音] ${Math.max(1, Math.round((m.dur || 0) / 1000))}″`,
  video: () => '[视频]',
  sticker: () => '[动画表情]',
  link: m => `[链接] ${m.title || ''}`.trim(),
  file: m => `[文件] ${m.name || ''}`.trim(),
  location: m => `[位置] ${m.title || ''}`.trim(),
  card: m => `[名片] ${m.title || ''}`.trim(),
  money: m => (m.kind === 'transfer' ? '[转账]' : '[微信红包]'),
  unknown: () => '[消息]'
}

/** One-line chat list preview. */
export function previewOf(m) {
  if (!m) return ''
  if (m.recalled) return m.recalled
  const fn = PREVIEW[m.type]
  const text = fn ? fn(m) : (m.text || '')
  const oneLine = text.replace(/\s+/g, ' ').trim()
  const room = isRoomId(m.chat)
  if (room && !m.out && m.fromName && m.type !== 'system') return `${m.fromName}: ${oneLine}`
  return oneLine
}

export { STATUS_NOTIFY }
