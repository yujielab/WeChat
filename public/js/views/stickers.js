// Telegram sticker packs in the chat (served by src/stickers.js: the browser
// only ever talks to our own server). Static stickers are webp; video
// stickers play in a muted <video>; animated (Lottie) stickers draw with
// lottie-web, loaded from our own origin the first time one is shown. A
// sticker plays only while it is on screen; until then — and for good with
// reduced motion — its still picture (or its emoji) stands in.

import { h, reducedMotion } from '../ui/dom.js'
import { api } from '../api.js'
import { openSheet } from './overlay.js'

// lottie-web 5.13.0, light build, vendored unchanged (public/js/vendor).
const PLAYER = { src: '/js/vendor/lottie_light.min.js', integrity: 'sha384-Gr3FGWSrOz4fzm9bvrWwhuQH87JMUCLlOTaHhpddbnlHHWCZPxMeQ3KUPsomzIii' }

let sets = null
let loading = null
let playerP = null
let io = null
let tab = 0
const live = new Set()
const anims = new Map()

export const stickerUrl = (id, thumb) => `/api/stickers/img/${encodeURIComponent(id)}${thumb ? '?thumb=1' : ''}`

/** The packs (once per launch; empty when the server has none). */
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
  if (st.kind === 'video') {
    const v = h('video', { class: cls, src: stickerUrl(st.id), loop: true, muted: true, playsInline: true, preload: st.nt ? 'metadata' : 'none', 'aria-label': label, disablePictureInPicture: true })
    if (!st.nt) v.poster = stickerUrl(st.id, true)
    v.muted = true
    // A browser that can't play it shows its still picture, or its emoji.
    v.addEventListener('error', () => v.replaceWith(st.nt
      ? h('i', { class: [...cls, 'stk-fb'], role: 'img', 'aria-label': label }, label)
      : h('img', { class: cls, src: stickerUrl(st.id, true), alt: label, decoding: 'async', draggable: false })), { once: true })
    return v
  }
  if (st.kind === 'animated') {
    const fallback = () => h('i', { class: 'stk-fb', 'aria-hidden': 'true' }, label)
    const still = st.nt
      ? fallback()
      : h('img', { src: stickerUrl(st.id, true), alt: '', decoding: 'async', draggable: false, loading: size === 'grid' ? 'lazy' : 'eager' })
    // No still picture after all: its emoji stands in until it plays.
    if (!st.nt) still.addEventListener('error', () => still.replaceWith(fallback()), { once: true })
    return h('span', { class: [...cls, 'lot'], role: 'img', 'aria-label': label, dataset: { lot: st.id } }, still)
  }
  return h('img', { class: cls, src: stickerUrl(st.id), alt: label, decoding: 'async', draggable: false, loading: 'lazy' })
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

function animation(id) {
  let p = anims.get(id)
  if (!p) {
    p = fetch(`/api/stickers/anim/${encodeURIComponent(id)}`).then(r => {
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
  Promise.all([player(), animation(el.dataset.lot)]).then(([lottie, data]) => {
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
/** The packs in a sheet: one row of pack names, a grid of stickers; a tap sends one. */
export async function openStickers({ onPick, origin }) {
  const tabs = h('div', { class: 'stk-tabs', role: 'tablist', 'aria-label': '表情包' })
  const grid = h('div', { class: 'stk-grid', role: 'group' })
  const content = h('div', { class: 'stk-panel' }, tabs, grid)
  const sheet = openSheet({ title: '表情', content, tall: true, origin, onClose: () => { for (const el of [...live]) if (content.contains(el)) drop(el) } })
  const all = await loadStickers()
  if (!all.length) {
    grid.replaceChildren(h('p', { class: 'stk-empty' }, '暂时没有可用的表情'))
    return sheet
  }
  const paint = () => {
    tab = Math.min(tab, all.length - 1)
    tabs.hidden = all.length < 2
    tabs.replaceChildren(...all.map((s, i) => {
      const b = h('button', { class: ['stk-tab', i === tab && 'on'], type: 'button', role: 'tab', 'aria-selected': String(i === tab) }, s.title)
      b.addEventListener('click', () => { tab = i; paint() })
      return b
    }))
    for (const el of [...live]) if (grid.contains(el)) drop(el)
    grid.setAttribute('aria-label', all[tab].title)
    grid.replaceChildren(...all[tab].stickers.map(st => {
      const b = h('button', { class: 'stk-cell', type: 'button', 'aria-label': `发送表情 ${st.emoji || ''}`.trim() }, stickerEl(st, 'grid'))
      b.addEventListener('click', () => {
        sheet.close()
        onPick(st)
      })
      return b
    }))
    mountStickers(grid)
  }
  paint()
  return sheet
}
