// Telegram sticker packs in the chat (served by src/stickers.js: the browser
// only ever talks to our own server). Static stickers are webp; video
// stickers play in a muted <video>; animated (Lottie) stickers draw with
// lottie-web, loaded from our own origin the first time one is shown. A
// sticker plays only while it is on screen; until then — and for good with
// reduced motion — its still picture (or its emoji) stands in.
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

/** One sticker. size: grid (the panel) or msg (in the conversation). */
export function stickerEl(st, size = 'msg') {
  const label = st.emoji || '表情'
  const cls = ['stk', size]
  const set = st.set || ''
  const still = { set, thumb: true }
  if (st.kind === 'video') {
    const v = h('video', { class: cls, src: stickerUrl(st.id, { set }), loop: true, muted: true, playsInline: true, preload: st.nt ? 'metadata' : 'none', 'aria-label': label, disablePictureInPicture: true })
    if (!st.nt) v.poster = stickerUrl(st.id, still)
    v.muted = true
    // A browser that can't play it shows its still picture, or its emoji.
    v.addEventListener('error', () => v.replaceWith(st.nt
      ? h('i', { class: [...cls, 'stk-fb'], role: 'img', 'aria-label': label }, label)
      : h('img', { class: cls, src: stickerUrl(st.id, still), alt: label, decoding: 'async', draggable: false })), { once: true })
    return v
  }
  if (st.kind === 'animated') {
    const fallback = () => h('i', { class: 'stk-fb', 'aria-hidden': 'true' }, label)
    const img = st.nt
      ? fallback()
      : h('img', { src: stickerUrl(st.id, still), alt: '', decoding: 'async', draggable: false, loading: size === 'msg' ? 'eager' : 'lazy' })
    // No still picture after all: its emoji stands in until it plays.
    if (!st.nt) img.addEventListener('error', () => img.replaceWith(fallback()), { once: true })
    return h('span', { class: [...cls, 'lot'], role: 'img', 'aria-label': label, dataset: { lot: st.id, set } }, img)
  }
  return h('img', { class: cls, src: stickerUrl(st.id, { set }), alt: label, decoding: 'async', draggable: false, loading: 'lazy' })
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
  for (const el of root.querySelectorAll('.stk.lot, video.stk')) {
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
    const shown = () => el.classList.add('on')
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
 * packs yet it opens on that list.
 */
export async function openStickers({ onPick, origin }) {
  const tabs = h('div', { class: 'stk-tabs', role: 'tablist', 'aria-label': '表情包' })
  const body = h('div', { class: 'stk-body' })
  const content = h('div', { class: 'stk-panel' }, tabs, body)
  const sheet = openSheet({ title: '表情', content, tall: true, origin, onClose: () => release(content) })
  let all = await loadStickers()
  let adding = !all.length

  const paintTabs = () => {
    tab = Math.min(tab, Math.max(0, all.length - 1))
    const packTabs = all.map((s, i) => {
      const on = !adding && i === tab
      const b = h('button', { class: ['stk-tab', on && 'on'], type: 'button', role: 'tab', 'aria-selected': String(on) }, s.title)
      b.addEventListener('click', () => { adding = false; tab = i; paint() })
      return b
    })
    const add = h('button', { class: ['stk-tab', 'stk-tab-add', adding && 'on'], type: 'button', role: 'tab', 'aria-selected': String(adding), 'aria-label': '添加表情包' }, icon('plus'))
    add.addEventListener('click', () => { if (!adding) { adding = true; paint() } })
    tabs.replaceChildren(...packTabs, add)
  }

  const paintPack = () => {
    const pack = all[tab]
    const grid = h('div', { class: 'stk-grid', role: 'group', 'aria-label': pack.title }, ...pack.stickers.map(st => {
      const item = { ...st, set: pack.name }
      const b = h('button', { class: 'stk-cell', type: 'button', 'aria-label': `发送表情 ${st.emoji || ''}`.trim() }, stickerEl(item, 'grid'))
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
        // A new pack comes first, which is where the panel opens next.
        if (add) tab = 0
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
    body.replaceChildren(h('p', { class: 'stk-empty' }, '正在载入…'))
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
