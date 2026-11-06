// Guides (css/guides.css): a welcome the first time the app opens, and short
// tips that point at a place the first time it is there to use — one at a
// time, each said once, never over a sheet, a menu or the keyboard.
//
//   welcome()                 the first-run cards: what the app's places are
//   tip(id, anchor, { title, text, side })
//                             a bubble beside `anchor`, once ever; queued while
//                             something else has the screen
//   resetGuides()             Settings › Show tips again
//
// Shown to people, not to automation: a browser driven by tests
// (navigator.webdriver) sees none unless localStorage 'ui:guides' is 'on'.

import { h, icon, reducedMotion } from './dom.js'

const KEY = id => `guide:${id}`
const store = {
  seen: id => { try { return localStorage.getItem(KEY(id)) === '1' } catch { return true } },
  mark: id => { try { localStorage.setItem(KEY(id), '1') } catch {} }
}
const enabled = () => {
  try { if (localStorage.getItem('ui:guides') === 'on') return true } catch {}
  return !navigator.webdriver
}

// ------------------------------------------------------------ welcome
const STEPS = [
  { icon: 'bubble', title: 'Your chats', text: 'Messages, calls and drawings with the people you know. Share a note at the top for friends to see for a day.' },
  { icon: 'people', title: 'Moments', text: 'Photos, videos and words for your friends or for everyone. Choose who can see and comment before you post.' },
  { icon: 'photo-stack', title: 'Memories', text: 'Every photo, video and drawing from your chats is kept here by month, without saving anything.' },
  { icon: 'house', title: 'Always in reach', text: 'On iPhone Duo the capsule at the foot of the right edge switches between Chats, Moments, Memories, Requests and You.' }
]
let welcoming = false

/** The first-run cards; resolves when they are done (or at once when seen before). */
export async function welcome() {
  if (!enabled() || store.seen('welcome') || welcoming) return
  welcoming = true
  const { openSheet } = await import('../views/overlay.js')
  let at = 0
  const art = h('div', { class: 'gd-art', 'aria-hidden': 'true' })
  const title = h('h2', { class: 'gd-title', id: 'gd-title' })
  const text = h('p', { class: 'gd-text' })
  const dots = h('div', { class: 'gd-dots', 'aria-hidden': 'true' }, STEPS.map(() => h('i')))
  const next = h('button', { class: 'gd-next', type: 'button' })
  const skip = h('button', { class: 'gd-skip', type: 'button' }, 'Skip')
  const card = h('div', { class: 'gd-welcome', role: 'group', 'aria-labelledby': 'gd-title' }, art, title, text, dots, h('div', { class: 'gd-actions' }, skip, next))
  const sheet = openSheet({ label: 'Welcome to Cuven', content: card })
  sheet.el.classList.add('gd-sheet')
  // However it goes (Get started, Skip, a drag, Escape): seen, and the tips may follow.
  sheet.el.addEventListener('sheet-close', () => { store.mark('welcome'); welcoming = false; setTimeout(flush, 500) }, { once: true })
  const paint = (dir = 0) => {
    const s = STEPS[at]
    art.replaceChildren(h('span', { class: 'gd-orb' }, icon(s.icon)))
    title.textContent = s.title
    text.textContent = s.text
    dots.querySelectorAll('i').forEach((d, i) => d.classList.toggle('on', i === at))
    next.textContent = at === STEPS.length - 1 ? 'Get started' : 'Next'
    skip.hidden = at === STEPS.length - 1
    if (dir && !reducedMotion()) card.animate([{ opacity: 0, transform: `translateX(${dir * 18}px)` }, { opacity: 1, transform: 'none' }], { duration: 260, easing: 'cubic-bezier(.2,.8,.2,1)' })
  }
  next.addEventListener('click', () => { if (at < STEPS.length - 1) { at++; paint(1) } else sheet.close() })
  skip.addEventListener('click', () => sheet.close())
  // A swipe across the card moves between steps too.
  let x0 = null
  card.addEventListener('pointerdown', e => { x0 = e.clientX })
  card.addEventListener('pointerup', e => {
    if (x0 === null) return
    const dx = e.clientX - x0
    x0 = null
    if (Math.abs(dx) < 40) return
    if (dx < 0 && at < STEPS.length - 1) { at++; paint(1) } else if (dx > 0 && at > 0) { at--; paint(-1) }
  })
  paint()
  next.focus({ preventScroll: true })
}

// ------------------------------------------------------------ tips
const queue = []
let showing = null
let leaving = false // one going away: the next waits until it has gone, and a beat more

/**
 * Point at `anchor` once ever, with a title and a line. anchor: an element, or a selector to find it by
 * when it is time (views redraw: the place is looked up then). side: 'auto' | 'above' | 'below' | 'start' | 'end'.
 */
export function tip(id, anchor, { title, text, side = 'auto' } = {}) {
  if (!enabled() || store.seen(`tip:${id}`) || !anchor) return
  if (showing?.id === id || queue.some(q => q.id === id)) return
  queue.push({ id, find: typeof anchor === 'string' ? () => document.querySelector(anchor) : () => anchor, title, text, side, tries: 0 })
  flush()
}

let waiting = 0
function busy() {
  const root = document.documentElement
  // Not before the welcome: it comes first, and a tip under it would be put away by its buttons.
  return welcoming || (enabled() && !store.seen('welcome')) || root.dataset.kb === '1' ||
    Boolean(document.querySelector('#overlays .sheet, .menu.on, .prompt, .call:not([hidden])'))
}

function flush() {
  if (showing || leaving || !queue.length) return
  if (busy()) { clearTimeout(waiting); waiting = setTimeout(flush, 1200); return }
  const next = queue.shift()
  const anchor = next.find()
  if (!anchor?.isConnected || !anchor.getClientRects().length) {
    // Not on screen just now: a few more looks, then let it go until it is asked for again.
    if (++next.tries < 5) queue.push(next)
    clearTimeout(waiting)
    waiting = setTimeout(flush, 1200)
    return
  }
  show({ ...next, anchor })
}

function show(t) {
  const close = h('button', { class: 'gd-tip-ok', type: 'button' }, 'Got it')
  const el = h('div', { class: 'gd-tip', role: 'status', 'aria-live': 'polite' },
    h('span', { class: 'gd-tip-arrow', 'aria-hidden': 'true' }),
    h('div', { class: 'gd-tip-body' }, t.title ? h('b', {}, t.title) : null, h('p', {}, t.text)), close)
  document.body.append(el)
  showing = { ...t, el }
  place(el, t.anchor, t.side)
  t.anchor.classList.add('gd-spot')
  const done = () => {
    if (showing?.el !== el) return
    store.mark(`tip:${t.id}`)
    t.anchor.classList.remove('gd-spot')
    showing = null
    window.removeEventListener('pointerdown', outside, true)
    window.removeEventListener('keydown', onKey, true)
    window.removeEventListener('resize', reposition)
    leaving = true
    el.classList.add('gd-leaving')
    const gone = () => { el.remove(); setTimeout(() => { leaving = false; flush() }, 600) }
    if (reducedMotion()) gone()
    else el.animate([{ opacity: 1 }, { opacity: 0, transform: 'scale(.96)' }], { duration: 160, easing: 'ease-out' }).finished.then(gone, gone)
  }
  // Any touch elsewhere, Escape, or the place itself being used puts it away (it has been seen).
  const outside = e => { if (!el.contains(e.target)) done() }
  const onKey = e => { if (e.key === 'Escape') done() }
  const reposition = () => (t.anchor.isConnected ? place(el, t.anchor, t.side) : done())
  close.addEventListener('click', done)
  setTimeout(() => {
    window.addEventListener('pointerdown', outside, true)
    window.addEventListener('keydown', onKey, true)
  }, 0)
  window.addEventListener('resize', reposition)
}

/** Beside the anchor, on the side with room, arrow pointing at it, inside the screen. */
function place(el, anchor, side) {
  const a = anchor.getBoundingClientRect()
  const W = innerWidth, H = innerHeight, m = 12, gap = 12
  el.style.maxWidth = `${Math.min(300, W - 2 * m)}px`
  const r = el.getBoundingClientRect()
  const room = { above: a.top, below: H - a.bottom, start: a.left, end: W - a.right }
  let s = side
  if (s === 'auto') s = room.start > r.width + gap + m && room.start > room.end ? 'start' : room.below >= r.height + gap + m ? 'below' : room.above >= r.height + gap + m ? 'above' : room.start > room.end ? 'start' : 'end'
  let x, y
  if (s === 'below' || s === 'above') {
    x = Math.min(W - m - r.width, Math.max(m, a.left + a.width / 2 - r.width / 2))
    y = s === 'below' ? a.bottom + gap : a.top - gap - r.height
  } else {
    y = Math.min(H - m - r.height, Math.max(m, a.top + a.height / 2 - r.height / 2))
    x = s === 'start' ? a.left - gap - r.width : a.right + gap
  }
  el.dataset.side = s
  el.style.left = `${Math.round(x)}px`
  el.style.top = `${Math.round(y)}px`
  // The arrow, at the anchor's middle along the bubble's edge.
  const arrow = el.querySelector('.gd-tip-arrow')
  if (s === 'below' || s === 'above') arrow.style.left = `${Math.round(Math.min(r.width - 18, Math.max(18, a.left + a.width / 2 - x)))}px`, arrow.style.top = ''
  else arrow.style.top = `${Math.round(Math.min(r.height - 18, Math.max(18, a.top + a.height / 2 - y)))}px`, arrow.style.left = ''
}

/** Settings › Show tips again: the welcome and every tip, as if new. */
export function resetGuides() {
  try {
    for (const k of Object.keys(localStorage)) if (k.startsWith('guide:')) localStorage.removeItem(k)
  } catch {}
}
