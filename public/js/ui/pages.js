// Pages: the app's places, switched from a capsule in the system's column on
// the right edge (the iPhone Duo's, under its clock; js/ui/viewport.js).
//
// Chats and Menu are columns of the strip (the list; the sidebar). Moments,
// Memories, You and Requests are full pages over them, each a sheet. The capsule stays
// in reach over every page, with the current one in a lighter circle that
// glides to the next; going from page to page swaps them in place (the new
// one fades in over the scrim already there, the old fades away) rather than
// one sliding down and the next rising. It shows where the column is the
// list's or the sidebar's, or a page's; a conversation keeps its own rail,
// and anything opened over a page (a profile, an editor) has the screen.

import { h, icon, reducedMotion } from './dom.js'
import { getBars, onBars } from './viewport.js'
import { state, on } from '../store.js'
import { frontSheet } from '../views/overlay.js'

export const PAGES = [
  { id: 'chats', icon: 'house', label: 'Chats' },
  { id: 'moments', icon: 'people', label: 'Moments' },
  { id: 'memories', icon: 'photo-stack', label: 'Memories' },
  { id: 'you', icon: 'person-circle', label: 'You' },
  { id: 'requests', icon: 'bell', label: 'Requests' },
  { id: 'menu', icon: 'menu', label: 'Menu' }
]

/**
 * goColumn(id): show the strip's column for 'chats' or 'menu'.
 * Returns { setColumn(id | null) } for the shell to say which column has the
 * edge: 'chats', 'menu', or null (a conversation, its details).
 */
export function createPages({ goColumn }) {
  let column = 'chats'
  let page = null // { id, sheet }
  const thumb = h('span', { class: 'page-thumb', 'aria-hidden': 'true' })
  const buttons = new Map()
  const rail = h('nav', { class: 'page-rail', 'aria-label': 'Pages', hidden: true }, thumb)
  for (const p of PAGES) {
    const b = h('button', { class: 'page-item', type: 'button', dataset: { page: p.id }, 'aria-label': p.label, title: p.label },
      icon(p.icon), h('span', { class: 'page-badge', 'aria-hidden': 'true', hidden: true }))
    b.addEventListener('click', () => show(p.id, b))
    buttons.set(p.id, b)
    rail.append(b)
  }
  document.body.append(rail)

  const current = () => page?.id || column
  async function show(id, origin) {
    if (id === current()) {
      // Again: back to its top.
      if (page) page.sheet.body.scrollTo({ top: 0, behavior: reducedMotion() ? 'auto' : 'smooth' })
      return
    }
    const before = page
    if (id === 'chats' || id === 'menu') {
      page = null
      goColumn(id)
      before?.sheet.close()
      paint()
      return
    }
    const swap = Boolean(before)
    let sheet = null
    try { sheet = await openPage(id, { origin, swap }) } catch { return }
    if (!sheet) return
    page = { id, sheet }
    // When it goes (its own Close, the scrim, a drag), the column is the page again.
    sheet.el.addEventListener('sheet-close', () => {
      if (page?.sheet === sheet) { page = null; paint() }
    })
    if (before) before.sheet.swapOut()
    paint()
  }

  async function openPage(id, { origin, swap }) {
    if (id === 'moments') return (await import('../views/moments.js')).openMoments({ origin, page: true, swap })
    if (id === 'memories') return (await import('../views/memories.js')).openMemories({ origin, page: true, swap })
    if (id === 'you') return (await import('../views/moments.js')).openMoments({ userId: state.me?.id, origin, page: true, swap })
    if (id === 'requests') return (await import('../views/people.js')).openRequests({ origin, page: true, swap })
    return null
  }

  // ------------------------------------------------------------ showing it
  let shown = false
  function paint() {
    // Where the controls stand in the edge column, for the list's or the
    // sidebar's column, or over a page — not under anything else opened.
    const front = frontSheet()
    const onPage = Boolean(front && front.classList.contains('page-sheet'))
    const visible = getBars() === 'vertical' && (onPage || (!front && column !== null))
    if (visible !== shown) {
      shown = visible
      rail.hidden = !visible
      document.documentElement.toggleAttribute('data-pages', visible)
      document.documentElement.toggleAttribute('data-page-over', visible && onPage)
    }
    const id = current()
    for (const [pid, b] of buttons) {
      const on = pid === id
      b.classList.toggle('current', on)
      if (on) b.setAttribute('aria-current', 'page')
      else b.removeAttribute('aria-current')
    }
    placeThumb(id)
    paintBadges()
  }
  let placed = false
  function placeThumb(id) {
    const b = buttons.get(id)
    if (!b || rail.hidden) return
    requestAnimationFrame(() => {
      if (!placed) thumb.style.transition = 'none'
      thumb.style.transform = `translateY(${b.offsetTop}px)`
      thumb.style.opacity = '1'
      if (!placed) { void thumb.offsetTop; thumb.style.transition = ''; placed = true }
    })
  }
  function paintBadges() {
    const requests = state.contacts.filter(c => c.state === 'pending_in').length
    badge('requests', requests ? String(requests > 9 ? '9+' : requests) : '')
    badge('moments', freshMoments ? '•' : '')
  }
  function badge(id, text) {
    const b = buttons.get(id)
    const el = b.querySelector('.page-badge')
    el.hidden = !text
    el.textContent = text === '•' ? '' : text
    el.classList.toggle('dot', text === '•')
    const label = PAGES.find(p => p.id === id).label
    b.setAttribute('aria-label', text ? `${label}, ${text === '•' ? 'new' : `${text} waiting`}` : label)
  }
  let freshMoments = false
  window.addEventListener('moments-new', e => { freshMoments = Boolean(e.detail); paintBadges() })
  on('contacts', paintBadges)
  window.addEventListener('overlays-change', paint)
  onBars(paint)

  // Keys: up and down move between the pages, as in a tab list.
  rail.addEventListener('keydown', e => {
    if (!['ArrowUp', 'ArrowDown', 'Home', 'End'].includes(e.key)) return
    const list = [...buttons.values()]
    const i = list.indexOf(document.activeElement)
    if (i < 0) return
    e.preventDefault()
    const next = e.key === 'Home' ? 0 : e.key === 'End' ? list.length - 1 : (i + (e.key === 'ArrowDown' ? 1 : -1) + list.length) % list.length
    list[next].focus()
  })

  paint()
  return {
    setColumn(id) {
      column = id
      paint()
    },
    show,
    get current() { return current() }
  }
}
