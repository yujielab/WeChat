// Sidebar: the first column of the strip. Who you are (opens settings), the
// scopes of the conversation list with their counts, and the actions that
// start something — search and New Chat — on the bars engine like every
// other column.

import { h, icon } from '../ui/dom.js'
import { symbolEffect } from '../ui/symbols.js'
import { state, on, sortedChats } from '../store.js'
import { avatar } from './avatar.js'
import { createBars } from '../ui/bars.js'
import { getBars, onBars } from '../ui/viewport.js'
import { FILTERS } from './chatList.js'

const SCOPE_ICONS = { all: 'bubble', unread: 'unread', people: 'person', groups: 'people' }

export function createSidebar(pane, { onScope, onSettings, onSearch, onCompose }) {
  pane.classList.add('pane-sidebar')
  pane.setAttribute('aria-label', '边栏')

  const meAvatar = h('span', { class: 'side-me-avatar' })
  const meName = h('span', { class: 'side-me-name' })
  const me = h('button', { class: 'side-me', type: 'button' }, meAvatar, meName, h('span', { class: 'chev' }, icon('chevron-right')))
  me.addEventListener('click', () => onSettings())

  const scopes = h('ul', { class: 'side-scopes', 'aria-label': '聊天范围' })
  const rows = new Map()
  for (const [key, f] of Object.entries(FILTERS)) {
    const count = h('span', { class: 'side-count tabular' })
    const button = h('button', { class: 'side-scope', type: 'button', dataset: { scope: key } },
      h('span', { class: 'side-scope-icon' }, icon(SCOPE_ICONS[key] || 'bubble')),
      h('span', { class: 'side-scope-label' }, f.label),
      count)
    button.addEventListener('click', () => {
      symbolEffect(button.querySelector('.side-scope-icon .icon'), 'bounce')
      onScope(key)
    })
    rows.set(key, { button, count })
    scopes.append(h('li', {}, button))
  }

  const title = h('h1', { class: 'large-title side-title' }, 'Cuven')
  const scroll = h('div', { class: 'scroll side-scroll' },
    h('header', { class: 'side-head' }, title),
    me,
    scopes)
  const topbar = h('div', { class: 'side-topbar' })

  // Search and New Chat start something, so they stay in reach when the
  // sidebar has the screen to itself: at the foot of the column, or beside
  // the title with vertical room. Beside the list they're the list's own.
  const bars = createBars({
    label: '边栏操作',
    items: [
      { id: 'search', icon: 'search', title: '搜索', priority: 6, onSelect: () => onSearch() },
      { id: 'compose', icon: 'compose', title: '新聊天', priority: 9, prominent: true, onSelect: () => onCompose() }
    ],
    arrange: axis => {
      if (pane.dataset.layout === 'leading') return { top: [], bottom: [] }
      return axis === 'vertical' ? { top: [], bottom: [['search'], ['compose']] } : { top: [['search'], ['compose']], bottom: [] }
    }
  })
  const rail = h('nav', { class: 'duo-rail side-rail', 'aria-label': '边栏操作' })
  pane.append(scroll, topbar, rail)

  let frame = 0
  function arrangeBars() {
    cancelAnimationFrame(frame)
    frame = requestAnimationFrame(() => {
      const axis = pane.dataset.layout === 'leading' ? 'horizontal' : getBars() || 'vertical'
      pane.dataset.bars = axis
      if (axis === 'vertical') {
        if (bars.top.parentElement !== rail) bars.move(() => rail.append(bars.top, bars.bottom))
        bars.layout('vertical', rail.clientHeight)
      } else {
        if (bars.top.parentElement !== topbar) bars.move(() => { topbar.append(bars.top); bars.bottom.remove() })
        bars.layout('horizontal', { top: topbar.clientWidth, bottom: Infinity })
      }
    })
  }
  new ResizeObserver(arrangeBars).observe(rail)
  new ResizeObserver(arrangeBars).observe(topbar)
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
      button.setAttribute('aria-label', `${FILTERS[key].label}${n ? `，${n} 个` : ''}`)
    }
  }
  on('chats', render)
  render()

  return {
    render,
    setMe(user) {
      meAvatar.replaceChildren(avatar(user?.avatar, user?.display, { size: 52 }))
      meName.textContent = user?.display || '我'
      me.setAttribute('aria-label', `${user?.display || '我'}，设置`)
    },
    setLayout(layout) {
      pane.dataset.layout = layout
      arrangeBars()
    }
  }
}
