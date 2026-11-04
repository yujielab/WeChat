// Message bubble renderers. All user text is inserted as text nodes; links are
// recognized and rebuilt as anchors from the plain string.

import { h, icon } from '../ui/dom.js'
import { duration, fileSize, emojiOnly, callSummary, threadTime, sendState } from '../ui/format.js'
import { state, nameOf } from '../store.js'
import { stickerEl } from './stickers.js'

const URL_RE = /\bhttps?:\/\/[^\s<>"'，。！？、；：（）【】《》]+/gi

function linkify(text) {
  const out = []
  let last = 0
  for (const m of text.matchAll(URL_RE)) {
    const url = m[0].replace(/[.,;:!?)\]]+$/, '')
    if (m.index > last) out.push(text.slice(last, m.index))
    out.push(h('a', { href: url, target: '_blank', rel: 'noopener noreferrer' }, url))
    last = m.index + url.length
  }
  if (last < text.length) out.push(text.slice(last))
  return out
}

/** Display size for photos: bounded box, original aspect ratio, no layout shift. */
export function mediaSize(w, h, maxW, maxH = 320) {
  if (!w || !h) return [Math.round(maxW * 0.8), Math.round(maxW * 0.8)]
  const s = Math.min(maxW / w, maxH / h, 1)
  let W = Math.round(w * s)
  let H = Math.round(h * s)
  if (W < 96) { H = Math.round((H * 96) / W); W = 96 }
  if (H < 72) H = 72
  return [W, Math.min(H, maxH)]
}

export function renderBubble(m, ctx) {
  switch (m.type) {
    case 'image':
    case 'drawing':
      return imageBubble(m, ctx)
    case 'voice':
      return voiceBubble(m)
    case 'video':
      return videoBubble(m, ctx)
    case 'file':
      return card(m, { icon: 'doc', iconClass: 'file', title: m.name || '文件', desc: fileSize(m.size) })
    case 'call':
      return callBubble(m)
    case 'sticker':
      return stickerBubble(m)
    default:
      return textBubble(m)
  }
}

function textBubble(m) {
  const text = m.text ?? '[消息]'
  if (emojiOnly(text)) {
    return h('div', { class: 'bubble jumbo', dataset: { kind: 'text' } }, h('span', { class: 'emoji-only' }, text))
  }
  const el = h('div', { class: 'bubble text', dataset: { kind: 'text' } })
  const keys = m.status !== 'revoked' && Array.isArray(m.meta?.keys) ? m.meta.keys : []
  el.append(...markKeys(markMentions(linkify(text), m), keys))
  return el
}

// What a reader hears for a message's text: each "@name" it mentions said
// as 「提及 名字」 (「提及你」 for this account), the same as in the bubble.
export function spokenMentions(text, m) {
  const ids = Array.isArray(m?.meta?.mentions) ? m.meta.mentions : []
  if (!text || !ids.length) return text
  const names = new Map()
  for (const id of ids) {
    const name = nameOf(id, m.chat)
    if (name) names.set(`@${name}`, id === state.me?.id ? '提及你' : `提及 ${name}`)
  }
  if (!names.size) return text
  const re = new RegExp([...names.keys()].sort((a, b) => b.length - a.length).map(k => k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|'), 'g')
  return text.replace(re, hit => names.get(hit))
}

// The members a group message @-mentions (meta.mentions), marked where
// "@name" appears; "me" when it's this account.
function markMentions(parts, m) {
  const ids = Array.isArray(m.meta?.mentions) ? m.meta.mentions : []
  if (!ids.length) return parts
  const names = new Map()
  for (const id of ids) {
    const name = nameOf(id, m.chat)
    if (name) names.set(`@${name}`, id)
  }
  if (!names.size) return parts
  const re = new RegExp([...names.keys()].sort((a, b) => b.length - a.length).map(k => k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|'), 'g')
  return parts.flatMap(part => {
    if (typeof part !== 'string') return [part]
    const out = []
    let last = 0
    for (const hit of part.matchAll(re)) {
      if (hit.index > last) out.push(part.slice(last, hit.index))
      // A reader hears 「提及 某某」 (「提及你」 for me), not 「at 某某」.
      const mine = names.get(hit[0]) === state.me?.id
      out.push(h('span', { class: ['mention', mine && 'me'] },
        h('span', { 'aria-hidden': 'true' }, hit[0]),
        h('span', { class: 'sr-only' }, mine ? '提及你' : `提及 ${hit[0].slice(1)}`)))
      last = hit.index + hit[0].length
    }
    if (last < part.length) out.push(part.slice(last))
    return out
  })
}

// A sent message's key words (src/assist.js) marked where they appear in
// its text, never inside a link. Whether the marks show is a setting
// (:root[data-keys="off"] hides them), so switching it needs no redraw.
function markKeys(parts, keys) {
  const usable = keys.filter(k => typeof k === 'string' && k)
  if (!usable.length) return parts
  const re = new RegExp(usable.map(k => k.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).join('|'), 'g')
  return parts.flatMap(part => {
    if (typeof part !== 'string') return [part]
    const out = []
    let last = 0
    for (const m of part.matchAll(re)) {
      if (m.index > last) out.push(part.slice(last, m.index))
      out.push(h('mark', { class: 'kw' }, m[0]))
      last = m.index + m[0].length
    }
    if (last < part.length) out.push(part.slice(last))
    return out
  })
}

function imageBubble(m, ctx) {
  const [W, H] = mediaSize(m.w, m.h, ctx.maxMedia)
  const el = h('div', {
    class: ['bubble media', m.type === 'drawing' && 'drawing', m.status === 'sending' && 'sending'],
    dataset: { kind: 'image' },
    style: { '--w': `${W}px`, '--h': `${H}px` }
  })
  // Failed, and its picture didn't survive a reload: the cell says so, at its
  // usual size, and offers to choose it again (thread.js opens the picker).
  if (m.status === 'failed' && m.lost) {
    el.append(h('div', { class: 'ph', role: 'group', 'aria-label': '图片已丢失' },
      icon('photo'),
      h('span', {}, '图片已丢失'),
      h('button', { class: 'text-button', type: 'button', 'aria-label': '重新选择图片' }, '重新选择')))
    return el
  }
  const src = m.url || (m.cid ? state.previews.get(m.cid) : '')
  const img = new Image()
  img.alt = m.type === 'drawing' ? '手绘' : '图片'
  img.decoding = 'async'
  img.draggable = false
  img.width = W
  img.height = H
  img.addEventListener('load', () => img.classList.add('loaded'))
  img.addEventListener('error', () => img.replaceWith(h('div', { class: 'ph' }, icon('photo'))))
  if (src) img.src = src
  el.append(img)
  return el
}

function voiceBubble(m) {
  const secs = Math.max(1, Math.round(m.dur || 0))
  const bars = []
  let seed = 0
  for (const ch of String(m.id)) seed = (seed * 31 + ch.charCodeAt(0)) >>> 0
  const n = Math.min(28, 12 + Math.round(secs * 0.8))
  for (let i = 0; i < n; i++) {
    seed = (seed * 1103515245 + 12345) >>> 0
    const env = Math.sin((Math.PI * (i + 1)) / (n + 1))
    bars.push(h('i', { style: { height: `${Math.round(5 + env * 16 * (0.45 + ((seed >>> 16) % 100) / 180))}px` } }))
  }
  return h('div', {
    class: 'bubble voice',
    dataset: { kind: 'voice' },
    style: { '--vw': `${Math.min(240, 128 + secs * 4)}px` },
    role: 'button',
    'aria-label': `语音 ${secs} 秒，点按播放`
  },
  h('span', { class: 'voice-btn' }, icon('play')),
  h('span', { class: 'wave' }, bars),
  h('span', { class: 'voice-dur' }, duration(secs)))
}

function videoBubble(m, ctx) {
  const [W, H] = mediaSize(m.w || 720, m.h || 1280, ctx.maxMedia, 300)
  const el = h('div', {
    class: 'bubble media video',
    dataset: { kind: 'video' },
    style: { '--w': `${W}px`, '--h': `${H}px` },
    role: 'button',
    'aria-label': `视频${m.dur ? ` ${duration(m.dur)}` : ''}，点按播放`
  }, h('div', { class: 'ph' }, icon('video')),
     h('span', { class: 'media-play glass glass-clear glass-btn' }, icon('play')))
  if (m.dur) el.append(h('span', { class: 'media-badge' }, duration(m.dur)))
  return el
}

// A sticker stands on its own, without a bubble behind it.
function stickerBubble(m) {
  const st = m.meta || {}
  if (!st.id) return textBubble({ ...m, text: st.emoji || '[表情]' })
  return h('div', { class: 'bubble sticker', dataset: { kind: 'sticker' } }, stickerEl({ id: st.id, kind: st.kind, emoji: st.emoji, set: st.set }, 'msg'))
}

// A record, not a control: calling back is the heading's job.
function callBubble(m) {
  const s = callSummary(m.call || {}, callMine(m))
  return h('div', { class: ['bubble call-log', s.missed && 'missed'], dataset: { kind: 'call' }, 'aria-label': s.label },
    icon(s.media === '视频' ? 'video' : 'phone'),
    h('span', { 'aria-hidden': 'true' }, s.text))
}

/** Whether this account placed the call (older records only know who logged them). */
export const callMine = m => (m.call?.caller ? m.call.caller === state.me?.id : m.out)

function card(m, { icon: name, iconClass = '', title, desc }) {
  return h('div', { class: 'bubble card', dataset: { kind: m.type }, role: 'button' },
    h('div', { class: 'card-body' },
      h('div', { class: ['card-icon', iconClass] }, icon(name)),
      h('div', { class: 'card-text' },
        h('div', { class: 'card-title' }, title),
        desc ? h('div', { class: 'card-desc' }, desc) : null)))
}

/** Whether a message type draws the iMessage tail on the last bubble of a run. */
export const hasTail = m => m.type === 'text' && !emojiOnly(m.text)

/**
 * The time, and for an outgoing message its state, in the bubble's
 * bottom-right corner (WhatsApp): span.m-meta.<state> holding <time>, the
 * state glyph(s) and the state said aloud in .sr-only. Over a picture,
 * video or sticker it is a .media-badge on the corner instead.
 */
export function bubbleMeta(m, read = false, dm = true) {
  const el = h('span', { class: 'm-meta' })
  fillMeta(el, m, read, sendState(m, read, dm))
  return el
}

export function fillMeta(el, m, read = false, s = sendState(m, read)) {
  const overlay = m.type === 'image-stack' || m.type === 'image' || m.type === 'drawing' || m.type === 'video' || m.type === 'sticker'
  el.className = ['m-meta', overlay && 'media-badge', s?.state].filter(Boolean).join(' ')
  el.metaSig = `${s?.state || ''}|${m.ts}`
  const time = threadTime(m.ts)[1]
  const glyph = !s ? [] : s.state === 'sending' ? [icon('clock')] : s.state === 'failed' ? [icon('exclaim')]
    : s.state === 'sent' ? [icon('check')] : [icon('check'), icon('check')]
  el.replaceChildren(
    h('time', { 'aria-hidden': 'true' }, time),
    ...glyph,
    h('span', { class: 'sr-only' }, s ? `${time} ${s.label}` : time))
}
