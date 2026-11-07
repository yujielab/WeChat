// Sidebar: the first column of the strip. Who you are (opens settings), the
// scopes of the conversation list with their counts, and Search on the
// bars engine like every other column.

import { h, icon } from '../ui/dom.js'
import { state, on, sortedChats } from '../store.js'
import { avatar } from './avatar.js'
import { createBars, railed } from '../ui/bars.js'
import { onBars } from '../ui/viewport.js'
import { FILTERS } from './chatList.js'

const SCOPE_ICONS = { all: 'bubble', unread: 'unread', people: 'person', groups: 'people' }

export function createSidebar(pane, { onScope, onSettings, onSearch }) {
  pane.classList.add('pane-sidebar')
  pane.setAttribute('aria-label', 'Sidebar')

  const meAvatar = h('span', { class: 'side-me-avatar' })
  const meName = h('span', { class: 'side-me-name' })
  const me = h('button', { class: 'side-me', type: 'button' }, meAvatar, meName, h('span', { class: 'chev' }, icon('chevron-right')))
  me.addEventListener('click', () => onSettings(me))

  const scopes = h('ul', { class: 'side-scopes', 'aria-label': 'Chats' })
  const rows = new Map()
  for (const [key, f] of Object.entries(FILTERS)) {
    const count = h('span', { class: 'side-count tabular' })
    const button = h('button', { class: 'side-scope', type: 'button', dataset: { scope: key } },
      h('span', { class: 'side-scope-icon' }, icon(SCOPE_ICONS[key] || 'bubble')),
      h('span', { class: 'side-scope-label' }, f.label),
      count)
    button.addEventListener('click', () => onScope(key))
    rows.set(key, { button, count })
    scopes.append(h('li', {}, button))
  }

  // Moments (views/moments.js), with a dot while friends have shared something new.
  const momentsDot = h('span', { class: 'moments-dot', 'aria-hidden': 'true' })
  const moments = h('button', { class: 'side-link side-moments', type: 'button' },
    h('span', { class: 'side-scope-icon' }, icon('photo')), h('span', { class: 'side-scope-label' }, 'Moments'), momentsDot)
  moments.addEventListener('click', async () => (await import('./moments.js')).openMoments({ origin: moments }))
  window.addEventListener('moments-new', e => moments.classList.toggle('fresh', Boolean(e.detail)))
  // Memories (views/memories.js): the photos and videos shared in your chats.
  const memories = h('button', { class: 'side-link side-memories', type: 'button' },
    h('span', { class: 'side-scope-icon' }, icon('photo-stack')), h('span', { class: 'side-scope-label' }, 'Memories'))
  memories.addEventListener('click', async () => (await import('./memories.js')).openMemories({ origin: memories }))
  const title = h('h1', { class: 'large-title side-title' }, 'Home')
  const scroll = h('div', { class: 'scroll side-scroll' },
    h('header', { class: 'side-head' }, title),
    me,
    scopes,
    h('ul', { class: 'side-scopes side-more', 'aria-label': 'Discover' }, h('li', {}, moments), h('li', {}, memories)))
  // Search and New Chat start something, so they stay in reach at the foot
  // of the sidebar when it has the screen to itself. Beside the list they
  // are the list's own. Where the system keeps its column on the right edge
  // (the Duo) they stand in a rail there.
  const bars = createBars({
    label: 'Sidebar actions',
    items: [
      { id: 'search', icon: 'search', title: 'Search', priority: 6, onSelect: () => onSearch() }
    ],
    arrange: () => (pane.dataset.layout === 'leading' ? { top: [], bottom: [] } : { top: [], bottom: [['search']] })
  })
  const bottombar = h('nav', { class: 'side-bottombar dock', 'aria-label': 'Sidebar actions' }, bars.bottom)
  const rail = h('nav', { class: 'duo-rail side-rail', 'aria-label': 'Sidebar actions' })
  pane.append(scroll, bottombar, rail)

  let frame = 0
  function arrangeBars() {
    cancelAnimationFrame(frame)
    frame = requestAnimationFrame(() => {
      const vertical = railed(pane)
      pane.dataset.bars = vertical ? 'vertical' : 'horizontal'
      if (vertical) {
        if (bars.top.parentElement !== rail) bars.move(() => rail.append(bars.top, bars.bottom))
        bars.layout('vertical', rail.clientHeight)
      } else {
        if (bars.bottom.parentElement !== bottombar) bars.move(() => { bottombar.append(bars.bottom); bars.top.remove() })
        bars.layout('horizontal', { bottom: bottombar.clientWidth })
      }
    })
  }
  new ResizeObserver(arrangeBars).observe(bottombar)
  new ResizeObserver(arrangeBars).observe(rail)
  onBars(arrangeBars)

  function render() {
    // Only unread conversations are worth a number.
    const unread = sortedChats().filter(FILTERS.unread.test).length
    for (const [key, { button, count }] of rows) {
      const n = key === 'unread' ? unread : 0
      count.textContent = n ? String(n) : ''
      count.hidden = !n
      const current = key === state.filter
      button.classList.toggle('current', current)
      if (current) button.setAttribute('aria-current', 'true')
      else button.removeAttribute('aria-current')
      button.setAttribute('aria-label', `${FILTERS[key].label}${n ? `, ${n}` : ''}`)
    }
  }
  on('chats', render)
  render()

  return {
    render,
    setMe(user) {
      meAvatar.replaceChildren(avatar(user?.avatar, user?.display, { size: 52 }))
      meName.textContent = user?.display || 'Me'
      me.setAttribute('aria-label', `${user?.display || 'Me'}, settings`)
    },
    setLayout(layout) {
      pane.dataset.layout = layout
      arrangeBars()
    }
  }
}
