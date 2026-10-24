// Message bubble renderers. All message text is inserted as text nodes;
// links are recognized and rebuilt as anchors from the plain string.

import { h, icon } from '../ui/dom.js'
import { duration, fileSize, emojiOnly } from '../ui/format.js'
import { state } from '../store.js'

const URL_RE = /\bhttps?:\/\/[^\s<>"'，。！？、；：（）【】《》]+/gi

function linkify(text) {
  const out = []
  let last = 0
  for (const m of text.matchAll(URL_RE)) {
    let url = m[0].replace(/[.,;:!?)\]]+$/, '')
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
  if (W < 96) {
    H = Math.round((H * 96) / W)
    W = 96
  }
  if (H < 72) H = 72
  return [W, Math.min(H, maxH)]
}

export function renderBubble(m, ctx) {
  switch (m.type) {
    case 'image':
      return imageBubble(m, ctx)
    case 'sticker':
      return stickerBubble(m)
    case 'voice':
      return voiceBubble(m)
    case 'video':
      return videoBubble(m, ctx)
    case 'link':
      return card(m, {
        icon: 'link',
        title: m.title || '链接',
        desc: m.desc,
        foot: m.source || hostOf(m.url),
        footIcon: m.url ? 'link' : null
      })
    case 'file':
      return card(m, { icon: 'doc', iconClass: 'file', title: m.name || '文件', desc: [fileSize(m.size), m.ext?.toUpperCase()].filter(Boolean).join(' · ') })
    case 'money':
      return card(m, {
        icon: m.kind === 'transfer' ? 'yen' : 'envelope',
        iconClass: 'money',
        title: m.title || (m.kind === 'transfer' ? '转账' : '微信红包'),
        desc: m.desc || '请在手机上查看',
        foot: m.kind === 'transfer' ? '微信转账' : '微信红包'
      })
    case 'location':
      return card(m, { icon: 'mappin', iconClass: 'loc', title: m.title || '位置', desc: '在“地图”中打开' })
    case 'card':
      return card(m, { icon: 'person', title: m.title || '个人名片', desc: m.desc, foot: '个人名片' })
    default:
      return textBubble(m)
  }
}

function textBubble(m) {
  const text = m.text ?? '[消息]'
  if (!m.quote && emojiOnly(text)) {
    return h('div', { class: 'bubble jumbo', dataset: { kind: 'text' } }, h('span', { class: 'emoji-only' }, text))
  }
  const el = h('div', { class: 'bubble text', dataset: { kind: 'text' } })
  if (m.quote) {
    const who = m.quote.name ? `${m.quote.name}：` : ''
    el.append(h('span', { class: 'quote' }, who + (m.quote.text || '')))
  }
  el.append(...linkify(text))
  return el
}

function hostOf(url) {
  try {
    return new URL(url).hostname.replace(/^www\./, '')
  } catch {
    return ''
  }
}

function imageBubble(m, ctx) {
  const [W, H] = mediaSize(m.w, m.h, ctx.maxMedia)
  const el = h('div', {
    class: ['bubble media', m.status === 'sending' && 'sending'],
    dataset: { kind: 'image' },
    style: { '--w': `${W}px`, '--h': `${H}px` }
  })
  const preview = m.cid ? state.previews.get(m.cid) : null
  const img = new Image()
  img.alt = '图片'
  img.decoding = 'async'
  img.draggable = false
  img.width = W
  img.height = H
  img.addEventListener('load', () => {
    img.classList.add('loaded')
    // The protocol's thumbnail is small; swap in the full photo once on screen.
    if (!preview && !img.dataset.full && /^\d+$/.test(m.id) && img.naturalWidth < W * 2) ctx.observeFull?.(img, m.id)
  })
  img.addEventListener('error', () => {
    if (!img.dataset.retried && /^\d+$/.test(m.id)) {
      img.dataset.retried = '1'
      img.src = `/api/media/image/${m.id}`
      return
    }
    img.replaceWith(h('div', { class: 'ph' }, icon('photo')))
  })
  if (preview) img.src = preview
  else if (/^\d+$/.test(m.id)) img.src = `/api/media/thumb/${m.id}`
  el.append(img)
  return el
}

function stickerBubble(m) {
  const size = Math.min(140, Math.max(80, m.w || 120))
  const ratio = m.w && m.h ? m.h / m.w : 1
  const el = h('div', {
    class: 'bubble sticker',
    dataset: { kind: 'sticker' },
    style: { '--w': `${size}px`, '--h': `${Math.round(size * ratio)}px` }
  })
  const img = new Image()
  img.alt = '动画表情'
  img.decoding = 'async'
  img.draggable = false
  img.addEventListener('error', () => img.replaceWith(h('span', { class: 'quote' }, '[动画表情]')))
  if (/^\d+$/.test(m.id)) img.src = `/api/media/sticker/${m.id}`
  el.append(img)
  return el
}

function voiceBubble(m) {
  const secs = Math.max(1, Math.round((m.dur || 0) / 1000))
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
    class: 'bubble media',
    dataset: { kind: 'video' },
    style: { '--w': `${W}px`, '--h': `${H}px` },
    role: 'button',
    'aria-label': `视频${m.dur ? ` ${duration(m.dur)}` : ''}，点按播放`
  })
  const img = new Image()
  img.alt = ''
  img.decoding = 'async'
  img.draggable = false
  img.addEventListener('load', () => img.classList.add('loaded'))
  img.addEventListener('error', () => img.replaceWith(h('div', { class: 'ph' }, icon('video'))))
  if (/^\d+$/.test(m.id)) img.src = `/api/media/thumb/${m.id}`
  el.append(img, h('span', { class: 'media-play glass glass-clear glass-btn' }, icon('play')))
  if (m.dur) el.append(h('span', { class: 'media-badge' }, duration(m.dur)))
  return el
}

function card(m, { icon: name, iconClass = '', title, desc, foot, footIcon }) {
  return h('div', { class: 'bubble card', dataset: { kind: m.type }, role: 'button' },
    h('div', { class: 'card-body' },
      h('div', { class: 'card-text' },
        h('div', { class: 'card-title' }, title),
        desc ? h('div', { class: 'card-desc' }, desc) : null),
      h('div', { class: ['card-icon', iconClass] }, icon(name))),
    foot ? h('div', { class: 'card-foot' }, footIcon ? icon(footIcon) : null, foot) : null)
}

/** Whether a message type draws the iMessage tail on the last bubble of a run. */
export const hasTail = m => (m.type === 'text' && !(!m.quote && emojiOnly(m.text))) || m.type === 'voice' || m.type === 'unknown'
