// Telegram sticker packs in the chat (served by src/stickers.js: the browser
// only ever talks to our own server). Static stickers are webp; video
// stickers play in a muted <video>; animated (Lottie) stickers draw with
// lottie-web, loaded from our own origin the first time one is shown. A
// sticker plays only while it is on screen; until then — and for good with
// reduced motion — its still picture stands in.
//
// Nothing shows empty: after launch, while the app is idle, your packs, the
// pictures of the pack the panel opens on, the add list and the player are
// fetched ahead; a sticker whose picture is still on its way shows its emoji
// (only if that takes a moment, so a ready one never flickers); and the
// panel shows the shape of what is coming while it loads.
//
// Everyone has their own packs, picked from the server's table of names in
// the panel's add list (+, after the pack names).

import { h, icon, reducedMotion } from '../ui/dom.js'
import { api } from '../api.js'
import { openSheet, toast } from './overlay.js'

// lottie-web 5.13.0, light build, vendored unchanged (public/js/vendor).
const PLAYER = { src: '/js/vendor/lottie_light.min.js', integrity: 'sha384-Gr3FGWSrOz4fzm9bvrWwhuQH87JMUCLlOTaHhpddbnlHHWCZPxMeQ3KUPsomzIii' }

let sets = null
let loading = null
let catalogP = null
let playerP = null
let warmP = null
let io = null
let tab = 0
const live = new Set()
const anims = new Map()

// The pack goes along, so a sticker loads for someone who hasn't added it.
const fileUrl = (what, id, { set, thumb } = {}) => {
  const q = new URLSearchParams()
  if (set) q.set('set', set)
  if (thumb) q.set('thumb', '1')
  const qs = String(q)
  return `/api/stickers/${what}/${encodeURIComponent(id)}${qs ? `?${qs}` : ''}`
}
export const stickerUrl = (id, opts) => fileUrl('img', id, opts)

/** Your packs (once per launch, then kept as you add and remove them). */
export function loadStickers() {
  if (sets) return Promise.resolve(sets)
  loading ||= api.get('/api/stickers')
    .then(r => (sets = (r.sets || []).filter(s => s.stickers?.length)))
    .catch(() => {
      loading = null
      return []
    })
  return loading
}

// What a sticker shows before (or instead of) moving: the picture itself, or
// the still of an animated or video one; null when it has none.
const stillUrl = st => (st.kind === 'static' ? stickerUrl(st.id, { set: st.set }) : st.nt ? null : stickerUrl(st.id, { set: st.set, thumb: true }))

/**
 * One sticker: a box of its size holding its emoji, its picture (shown once
 * decoded) and, for a video sticker, the video (shown once playing).
 * size: grid (the panel), row (the add list) or msg (in the conversation).
 */
export function stickerEl(st, size = 'msg', { eager = size !== 'grid' } = {}) {
  st = { ...st, set: st.set || '' }
  const box = h('span', {
    class: ['stk', size, st.kind === 'animated' && 'lot'],
    role: 'img',
    'aria-label': st.emoji || '表情',
    dataset: st.kind === 'animated' ? { lot: st.id, set: st.set } : {}
  }, h('i', { class: 'stk-fb', 'aria-hidden': 'true' }, st.emoji || ''))
  // Ready at once (decoded ahead): no fade and no emoji first. Otherwise
  // the emoji stands in after a moment, and the picture fades in over it.
  const born = performance.now()
  const ready = () => {
    if (performance.now() - born < 120) box.classList.add('instant')
    box.classList.add('ready')
  }
  setTimeout(() => box.classList.add('waiting'), 120)
  const src = stillUrl(st)
  if (src) {
    const img = h('img', { class: 'stk-pic', src, alt: '', decoding: 'async', draggable: false, loading: eager ? 'eager' : 'lazy' })
    img.addEventListener('load', () => (img.decode ? img.decode().then(ready, ready) : ready()), { once: true })
    // No picture after all: the emoji stays.
    img.addEventListener('error', () => img.remove(), { once: true })
    box.append(img)
  }
  if (st.kind === 'video') {
    const v = h('video', { src: stickerUrl(st.id, { set: st.set }), loop: true, muted: true, playsInline: true, preload: 'none', disablePictureInPicture: true, 'aria-hidden': 'true' })
    v.muted = true
    v.addEventListener('playing', () => { box.classList.add('playing'); ready() })
    // A browser that can't play it keeps the still, or the emoji.
    v.addEventListener('error', () => { drop(v); v.remove() }, { once: true })
    box.append(v)
  }
  return box
}

// ------------------------------------------------------------ ahead of time
const idle = fn => (window.requestIdleCallback ? requestIdleCallback(fn, { timeout: 2000 }) : setTimeout(fn, 800))
const warmed = new Set()

/** Fetch and decode a pack's pictures, a few at a time, so they show at once. */
function warmPictures(pack, limit = 48) {
  const urls = pack.stickers.slice(0, limit).map(st => stillUrl({ ...st, set: pack.name })).filter(u => u && !warmed.has(u))
  urls.forEach(u => warmed.add(u))
  return (async () => {
    for (let i = 0; i < urls.length; i += 6) {
      await Promise.all(urls.slice(i, i + 6).map(src => {
        const img = new Image()
        img.decoding = 'async'
        img.src = src
        return img.decode().catch(() => warmed.delete(src))
      }))
    }
  })()
}

/**
 * Once per launch, while the app is idle: your packs, the pictures of the
 * pack the panel opens on, the add list and (when a pack moves) the player.
 */
export function prewarmStickers() {
  warmP ||= new Promise(idle).then(async () => {
    const packs = await loadStickers()
    const pack = packs[tab] || packs[0]
    if (pack) await warmPictures(pack)
    loadCatalog().catch(() => {})
    if (packs.some(p => p.stickers.some(st => st.kind === 'animated'))) await player().catch(() => {})
  })
  return warmP
}

// ------------------------------------------------------------ playing
function player() {
  if (window.lottie?.loadAnimation) return Promise.resolve(window.lottie)
  playerP ||= new Promise((resolve, reject) => {
    const s = document.createElement('script')
    s.src = PLAYER.src
    s.integrity = PLAYER.integrity
    s.async = true
    s.onload = () => (window.lottie?.loadAnimation ? resolve(window.lottie) : reject(new Error('lottie')))
    s.onerror = () => { s.remove(); reject(new Error('lottie')) }
    document.head.append(s)
  })
  // Couldn't load: the stills stay; try again in a minute.
  playerP.catch(() => setTimeout(() => { playerP = null }, 60000))
  return playerP
}

function animation(id, set) {
  let p = anims.get(id)
  if (!p) {
    p = fetch(fileUrl('anim', id, { set })).then(r => {
      if (!r.ok) throw new Error(String(r.status))
      return r.json()
    })
    p.catch(() => anims.delete(id))
    anims.set(id, p)
    if (anims.size > 40) anims.delete(anims.keys().next().value)
  }
  return p
}

/** Hand the root's moving stickers to the observer: on screen they play, off it they stop. */
export function mountStickers(root) {
  if (!root || !window.IntersectionObserver) return
  io ||= new IntersectionObserver(entries => entries.forEach(e => seen(e.target, e.isIntersecting)), { threshold: 0.01 })
  for (const el of root.querySelectorAll('.stk.lot, .stk > video')) {
    if (live.has(el)) continue
    live.add(el)
    io.observe(el)
  }
  for (const el of live) if (!el.isConnected) drop(el)
}

function seen(el, visible) {
  if (!el.isConnected) return drop(el)
  el.stkVisible = visible
  const go = visible && !reducedMotion()
  if (el.tagName === 'VIDEO') {
    if (go) el.play()?.catch?.(() => {})
    else el.pause()
    return
  }
  if (!go) return el.stkAnim?.pause()
  if (el.stkAnim) return el.stkAnim.play()
  if (el.stkBusy) return
  el.stkBusy = true
  Promise.all([player(), animation(el.dataset.lot, el.dataset.set)]).then(([lottie, data]) => {
    if (!el.isConnected || !live.has(el) || el.stkAnim) return
    const a = lottie.loadAnimation({ container: el, renderer: 'svg', loop: true, autoplay: false, animationData: data, rendererSettings: { preserveAspectRatio: 'xMidYMid meet' } })
    el.stkAnim = a
    const shown = () => el.classList.add('on', 'ready')
    if (a.isLoaded) shown()
    else a.addEventListener('DOMLoaded', shown)
    if (el.stkVisible && !reducedMotion()) a.play()
  }).catch(() => {}).finally(() => { el.stkBusy = false })
}

function drop(el) {
  try { el.stkAnim?.destroy() } catch {}
  el.stkAnim = null
  if (el.tagName === 'VIDEO') el.pause()
  live.delete(el)
  io?.unobserve(el)
}

// ------------------------------------------------------------ the panel
const release = root => { for (const el of [...live]) if (root.contains(el)) drop(el) }
const samePack = (a, b) => a.toLowerCase() === b.toLowerCase()
const skel = (cls, ...children) => h('div', { class: [cls, 'skel'], 'aria-hidden': 'true' }, ...children)

/** Every pack that can be added (once per launch). */
function loadCatalog() {
  catalogP ||= api.get('/api/stickers/catalog').then(r => r.packs || []).catch(err => {
    catalogP = null
    throw err
  })
  return catalogP
}

/**
 * The packs in a sheet: a row of pack names and +, then a grid of stickers
 * (a tap sends one) or, under +, the list of packs to add or remove. With no
 * packs yet it opens on that list. Normally everything is here already
 * (prewarmStickers); if not, the shape of the row and grid stands in.
 */
export async function openStickers({ onPick, origin }) {
  const tabs = h('div', { class: 'stk-tabs', role: 'tablist', 'aria-label': '表情包' })
  const body = h('div', { class: 'stk-body' })
  const content = h('div', { class: 'stk-panel' }, tabs, body)
  const sheet = openSheet({ title: '表情', content, tall: true, origin, onClose: () => release(content) })
  if (!sets) {
    tabs.replaceChildren(...[56, 72].map(w => skel('stk-tab', h('span', { class: 'skel-bar', style: { width: `${w}px` } }))))
    body.replaceChildren(h('div', { class: 'stk-grid', 'aria-busy': 'true' }, ...Array.from({ length: 12 }, () => skel('stk-cell', h('span', { class: 'skel-blob' })))))
  }
  let all = await loadStickers()
  let adding = !all.length

  const paintTabs = () => {
    tab = Math.min(tab, Math.max(0, all.length - 1))
    const packTabs = all.map((s, i) => {
      const on = !adding && i === tab
      const b = h('button', { class: ['stk-tab', on && 'on'], type: 'button', role: 'tab', 'aria-selected': String(on) }, s.title)
      // Its pictures start on their way as the finger lands.
      b.addEventListener('pointerdown', () => warmPictures(s, 24), { once: true })
      b.addEventListener('click', () => { adding = false; tab = i; paint() })
      return b
    })
    const add = h('button', { class: ['stk-tab', 'stk-tab-add', adding && 'on'], type: 'button', role: 'tab', 'aria-selected': String(adding), 'aria-label': '添加表情包' }, icon('plus'))
    add.addEventListener('click', () => { if (!adding) { adding = true; paint() } })
    tabs.replaceChildren(...packTabs, add)
  }

  const paintPack = () => {
    const pack = all[tab]
    const grid = h('div', { class: 'stk-grid', role: 'group', 'aria-label': pack.title }, ...pack.stickers.map((st, i) => {
      const item = { ...st, set: pack.name }
      // The first rows load at once; the rest as they scroll near.
      const b = h('button', { class: 'stk-cell', type: 'button', 'aria-label': `发送表情 ${st.emoji || ''}`.trim() }, stickerEl(item, 'grid', { eager: i < 24 }))
      b.addEventListener('click', () => {
        sheet.close()
        onPick(item)
      })
      return b
    }))
    body.replaceChildren(grid)
    mountStickers(grid)
  }

  // One pack in the add list: its cover, name and size, and 添加 / 移除.
  const packRow = p => {
    const button = h('button', { class: 'stk-add', type: 'button' })
    const show = () => {
      const added = all.some(s => samePack(s.name, p.name))
      button.textContent = added ? '移除' : '添加'
      button.classList.toggle('added', added)
      button.setAttribute('aria-label', `${added ? '移除' : '添加'}${p.title}`)
    }
    show()
    button.addEventListener('click', async () => {
      if (button.disabled) return
      const add = !all.some(s => samePack(s.name, p.name))
      button.disabled = true
      try {
        const r = await api.post('/api/stickers/mine', add ? { add: p.name } : { remove: p.name })
        all = sets = (r.sets || []).filter(s => s.stickers?.length)
        // A new pack comes first, which is where the panel opens next: its
        // pictures start on their way now.
        if (add) {
          tab = 0
          if (all[0]) warmPictures(all[0])
        }
        paintTabs()
      } catch (err) {
        toast(err.message || (add ? '添加失败' : '移除失败'), { type: 'error' })
      }
      button.disabled = false
      show()
    })
    return h('div', { class: 'stk-row', role: 'listitem' },
      stickerEl({ ...p.cover, set: p.name }, 'row'),
      h('div', { class: 'stk-row-text' }, h('span', { class: 'stk-row-title' }, p.title), h('span', { class: 'stk-row-sub' }, `${p.count} 个`)),
      button)
  }

  const paintCatalog = async () => {
    // Usually here already (prewarmStickers); otherwise the rows' shape.
    body.replaceChildren(h('div', { class: 'stk-store', 'aria-busy': 'true' }, ...Array.from({ length: 4 }, () => skel('stk-row',
      h('span', { class: 'stk row' }, h('span', { class: 'skel-blob' })),
      h('div', { class: 'stk-row-text' }, h('span', { class: 'skel-bar', style: { width: '40%' } }), h('span', { class: 'skel-bar short', style: { width: '18%' } }))))))
    let packs
    try {
      packs = await loadCatalog()
    } catch {
      packs = null
    }
    // Moved to a pack, or closed, while it loaded.
    if (!adding || !content.isConnected) return
    if (!packs?.length) {
      body.replaceChildren(h('p', { class: 'stk-empty' }, packs ? '暂时没有可添加的表情包' : '暂时取不到表情包'))
      return
    }
    const list = h('div', { class: 'stk-store', role: 'list', 'aria-label': '可添加的表情包' }, ...packs.map(packRow))
    body.replaceChildren(list)
    mountStickers(list)
  }

  const paint = () => {
    paintTabs()
    release(body)
    if (adding || !all.length) {
      adding = true
      paintCatalog()
    } else paintPack()
  }
  paint()
  return sheet
}
