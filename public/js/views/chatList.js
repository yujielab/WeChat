// Conversation list: a large-title heading, pinned avatars, rows with swipe
// actions, filters and live search (names, remarks and pinyin), with its
// bars arranged for the display (see ui/bars.js).

import { h, icon, clear, reducedMotion, edge, stagger } from '../ui/dom.js'
import { symbolEffect } from '../ui/symbols.js'
import { listTime } from '../ui/format.js'
import { velocityTracker, project, rubberband, spring } from '../ui/spring.js'
import { haptic } from '../ui/haptics.js'
import { cancelPress } from '../ui/press.js'
import { state, on, sortedChats, getDraft, patchRoom, upsertRoom } from '../store.js'
import { api } from '../api.js'
import { avatar } from './avatar.js'
import { openMenu, toast } from './overlay.js'
import { createBars } from '../ui/bars.js'

export const FILTERS = {
  all: { label: '全部', test: () => true },
  unread: { label: '未读', test: c => c.unread > 0 },
  people: { label: '私聊', test: c => !c.room },
  groups: { label: '群聊', test: c => c.room }
}

export function createChatList(pane, { onOpen, onBack, onFilter, onCompose, onSettings, loadContacts }) {
  pane.classList.add('pane-list')
  // Rows swipe themselves; a back swipe starts at the column's leading edge.
  pane.dataset.edgeSwipe = ''
  let selected = null
  let searching = false
  let query = ''
  let openSwipe = null
  let loading = false // connecting / fetching chats: show a skeleton, not "no chats"
  let shownArt = null // the filter whose empty state is on screen
  let signalEffect = null

  // ------------------------------------------------------------ skeleton
  const status = h('span', { class: 'conn-status', role: 'status', hidden: true })
  const title = h('h1', { class: 'large-title' }, '消息')
  // Unfolded, the window keeps to the list and the conversation, so who you
  // are (and settings) sits at the end of the list's heading.
  const me = h('button', { class: 'list-me', type: 'button', 'aria-label': '设置' })
  me.addEventListener('click', () => onSettings?.(me))
  const head = h('header', { class: 'list-head' }, h('div', { class: 'list-heading' }, title, status, me))
  const filterThumb = h('span', { class: 'filter-thumb', 'aria-hidden': 'true' })
  const filterTabs = h('div', { class: 'list-filters', role: 'group', 'aria-label': '筛选聊天' }, filterThumb)
  const filterButtons = new Map()
  Object.entries(FILTERS).forEach(([key, f]) => {
    const button = h('button', { class: 'filter-tab', type: 'button', 'aria-pressed': key === state.filter ? 'true' : 'false', dataset: { filter: key } }, f.label)
    button.addEventListener('click', () => selectFilter(key))
    button.addEventListener('keydown', e => {
      if (!['ArrowLeft', 'ArrowRight', 'Home', 'End'].includes(e.key)) return
      e.preventDefault()
      const keys = [...filterButtons.keys()]
      const i = keys.indexOf(key)
      const next = e.key === 'Home' ? 0 : e.key === 'End' ? keys.length - 1 : (i + (e.key === 'ArrowRight' ? 1 : -1) + keys.length) % keys.length
      filterButtons.get(keys[next]).focus()
      selectFilter(keys[next])
    })
    filterButtons.set(key, button)
    filterTabs.append(button)
  })
  const filterNote = h('div', { class: 'filter-note', hidden: true })
  const pinned = h('div', { class: 'pinned', role: 'list', 'aria-label': '置顶聊天', hidden: true })
  const rows = h('ul', { class: 'rows', 'aria-label': '聊天' })
  const empty = h('div', { class: 'list-empty', hidden: true })
  const results = h('div', { class: 'search-results', hidden: true })
  const pinLabel = h('div', { class: 'pinned-label', hidden: true }, icon('pin'), '置顶')
  // Unfolded, one shared capsule marks the open conversation and glides
  // between rows (and along with a row as it reorders) instead of jumping.
  const capsule = h('span', { class: 'row-highlight', 'aria-hidden': 'true' })
  const scroll = h('div', { class: 'scroll list-scroll' }, head, filterTabs, filterNote, pinLabel, pinned, rows, capsule, empty, results)

  const inlineTitle = h('div', { class: 'list-inline-title', 'aria-hidden': 'true' }, '消息')
  const topbar = h('div', { class: 'list-topbar' }, inlineTitle, h('div', { class: 'spacer' }))

  // One bar of capsules at the foot of the list, in reach of the thumb:
  // folded, Back to the sidebar leads; unfolded, the sidebar's scopes are
  // the filter menu instead. The search field takes the middle, New Chat
  // ends it. While searching, the field and Cancel have the bar to
  // themselves.
  const bars = createBars({
    label: '聊天列表操作',
    items: [
      { id: 'back', icon: 'chevron-left', title: '边栏', primary: true, onSelect: () => onBack() },
      { id: 'filter', icon: 'filter', title: '筛选', priority: 3, menu: true, onSelect: anchor => openFilterMenu(anchor) },
      { id: 'compose', icon: 'compose', title: '新聊天', priority: 9, prominent: true, onSelect: () => onCompose() }
    ],
    arrange: () => {
      // While searching the bar keeps its items; they fold away (list.css)
      // so the field can grow over their room and give it back on Cancel.
      // Folded, the filter tabs show and Back leads to the sidebar;
      // unfolded, the filter is a menu.
      const nav = pane.dataset.layout === 'single' ? ['back'] : ['filter']
      return { top: [], bottom: [...(nav.length ? [nav] : []), ['compose']] }
    }
  })

  const input = h('input', {
    type: 'search',
    placeholder: '搜索聊天、联系人',
    'aria-label': '搜索聊天和联系人',
    enterkeyhint: 'search',
    autocomplete: 'off',
    autocorrect: 'off',
    autocapitalize: 'off',
    spellcheck: false
  })
  const pill = h('label', { class: 'glass search-pill' }, icon('search'), input)
  const cancel = h('button', { class: 'glass glass-btn search-cancel', type: 'button', 'aria-label': '取消搜索' }, icon('xmark'))
  const bottombar = h('nav', { class: 'list-bottombar dock', 'aria-label': '聊天列表操作' }, bars.bottom, pill, cancel)

  const edgeTop = edge('top')
  const edgeBottom = edge('bottom', true)
  pane.append(scroll, edgeTop, topbar, edgeBottom, bottombar)

  function openFilterMenu(anchor) {
    openMenu(anchor, [
      Object.entries(FILTERS).map(([key, f]) => ({
        label: f.label,
        checked: state.filter === key,
        onSelect: () => {
          selectFilter(key)
        }
      }))
    ], { title: '筛选' })
  }

  // The search field keeps at least 120px of the bar, and one more gap beside it.
  let barsFrame = 0
  function arrangeBars() {
    cancelAnimationFrame(barsFrame)
    barsFrame = requestAnimationFrame(() => bars.layout({ bottom: Math.max(0, bottombar.clientWidth - 120 - 8) }))
  }
  new ResizeObserver(arrangeBars).observe(bottombar)

  function selectFilter(key) {
    if (!FILTERS[key]) return
    closeSwipe()
    if (searching) exitSearch()
    state.filter = key
    render()
    onFilter?.(key)
  }

  function positionFilterThumb() {
    const current = filterButtons.get(state.filter) || filterButtons.get('all')
    if (!current || !filterTabs.offsetWidth) return
    filterThumb.style.width = `${current.offsetWidth}px`
    filterThumb.style.transform = `translateX(${current.offsetLeft}px)`
    filterTabs.classList.add('ready')
  }

  let statusText = ''
  function updateFilters() {
    for (const [key, button] of filterButtons) button.setAttribute('aria-pressed', key === state.filter ? 'true' : 'false')
    positionFilterThumb()
    // Unfolded, the filter lives in the menu: its button and the inline title
    // carry the active choice instead of a row of tabs.
    const active = FILTERS[state.filter] && state.filter !== 'all' ? FILTERS[state.filter].label : ''
    bars.set('filter', { title: active ? `筛选：${active}` : '筛选', state: { active: Boolean(active) } })
    inlineTitle.textContent = `${statusText ? `消息（${statusText}）` : '消息'}${active ? ` · ${active}` : ''}`
  }
  new ResizeObserver(positionFilterThumb).observe(filterTabs)

  // ------------------------------------------------------------ scroll chrome
  let ticking = false
  scroll.addEventListener('scroll', () => {
    if (ticking) return
    ticking = true
    requestAnimationFrame(() => {
      ticking = false
      const y = scroll.scrollTop
      // The inline title takes over once the large one has scrolled under the top bar.
      pane.classList.toggle('collapsed', title.getBoundingClientRect().bottom < topbar.getBoundingClientRect().bottom)
      edgeTop.classList.toggle('on', y > 2)
      closeSwipe()
    })
  }, { passive: true })

  new ResizeObserver(([entry]) => {
    pane.dataset.width = entry.contentRect.width < 380 ? 'narrow' : 'wide'
  }).observe(pane)

  // ------------------------------------------------------------ rows
  const rowEls = new Map()

  function preview(c) {
    const draft = state.open === c.id ? '' : getDraft(c.id)
    if (draft) return [h('span', { class: 'draft' }, '[草稿] '), draft.replace(/\s+/g, ' ')]
    const last = c.last
    if (!last) return [c.room ? `${c.count || ''}${c.count ? ' 位成员' : ''}` : '']
    if (last.status === 'failed') return [h('span', { class: 'failed' }, '[未发送] '), last.text]
    if (last.status === 'sending') return ['发送中… ', last.text]
    return [last.text || '']
  }

  function label(c) {
    const parts = [c.name]
    if (c.kind === 'dm' && c.online) parts.push('在线')
    if (c.unread) parts.push(`${c.unread} 条未读`)
    if (c.last?.text) parts.push(c.last.text)
    if (c.ts) parts.push(listTime(c.ts))
    return parts.join('，')
  }

  function buildRow(c) {
    const r = {}
    r.dot = h('span', { class: 'row-dot', 'aria-hidden': 'true' })
    r.name = h('span', { class: 'row-name' })
    r.flag = h('span', { class: 'row-flag', 'aria-hidden': 'true' })
    r.time = h('span', { class: 'row-time' })
    r.preview = h('div', { class: 'row-preview' })
    r.unread = h('span', { class: 'row-count', hidden: true })
    r.avatar = avatar(c.avatar, c.name, { room: c.room })
    r.avWrap = h('span', { class: 'av-wrap' }, r.avatar, h('span', { class: 'pres', 'aria-hidden': 'true' }))
    r.inner = h('div', { class: 'row-inner', role: 'button', tabindex: '0' },
      r.dot,
      r.avWrap,
      h('div', { class: 'row-main' },
        h('div', { class: 'row-top' }, r.name, r.flag, h('span', { class: 'grow' }), r.time, h('span', { class: 'row-chevron' }, icon('chevron-right'))),
        h('div', { class: 'row-bottom' }, r.preview, r.unread)))
    r.hideBtn = h('button', { class: 'row-action', type: 'button', tabindex: '-1' }, h('span', { class: 'row-action-label' }, icon('trash'), '删除'))
    r.actions = h('div', { class: 'row-actions' }, r.hideBtn)
    const li = h('li', { class: 'row', dataset: { id: c.id } }, r.actions, r.inner)
    li._r = r
    r.inner.addEventListener('click', () => {
      // A tap that closed an open row, the end of a swipe or of a hold, opens nothing.
      const why = li._suppress
      li._suppress = null
      if (why === 'close') return settle(li, 0)
      if (why) return
      closeSwipe()
      onOpen(li.dataset.id)
    })
    r.inner.addEventListener('keydown', e => {
      if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault()
        closeSwipe()
        onOpen(li.dataset.id)
      }
    })
    r.hideBtn.addEventListener('click', () => {
      if (li._deleting) return
      li._deleting = true
      actHide(li.dataset.id)
    })
    attachSwipe(li, holdToOpen(r.inner, (at, how) => rowMenu(li, at, how), li))
    return li
  }

  function updateRow(li, c) {
    const r = li._r
    li.classList.toggle('unread', c.unread > 0)
    li.classList.toggle('muted', Boolean(c.muted))
    li.classList.toggle('selected', c.id === selected)
    li.classList.toggle('online', c.kind === 'dm' && Boolean(c.online))
    if (r._avatar !== c.avatar || r._name !== c.name) {
      r._avatar = c.avatar; r._name = c.name
      r.avatar.replaceWith(r.avatar = avatar(c.avatar, c.name, { room: c.room }))
    }
    r.name.textContent = c.name
    const muted = Boolean(c.muted)
    if (r._muted !== muted) {
      // Muting or unmuting a conversation in view: its flag appears or goes.
      const shown = r._muted !== undefined
      r._muted = muted
      if (muted) {
        r.flag.replaceChildren(icon('bell-slash'))
        if (shown) symbolEffect(r.flag.firstChild, 'appear')
      } else if (shown && r.flag.firstChild) {
        const flag = r.flag.firstChild
        symbolEffect(flag, 'disappear').done.then(() => { if (!r._muted) flag.remove() })
      } else r.flag.replaceChildren()
    }
    r.time.textContent = listTime(c.ts)
    r.preview.replaceChildren(...preview(c))
    r.unread.hidden = !c.unread
    r.unread.textContent = c.unread > 99 ? '99+' : String(c.unread || '')
    r.inner.setAttribute('aria-label', label(c))
    r.inner.setAttribute('aria-current', c.id === selected ? 'true' : 'false')
  }

  function buildPin(c) {
    const b = h('button', { class: 'pin', type: 'button', role: 'listitem', dataset: { id: c.id } })
    b.addEventListener('click', () => {
      if (b._suppress) { b._suppress = null; return }
      onOpen(b.dataset.id)
    })
    holdToOpen(b, (at, how) => rowMenu(b, at, how))
    return b
  }

  function updatePin(b, c) {
    b.classList.toggle('unread', c.unread > 0)
    b.classList.toggle('selected', c.id === selected)
    b.setAttribute('aria-label', label(c))
    const badge = c.unread ? h('span', { class: ['badge', c.muted && 'muted'] }, c.unread > 99 ? '99+' : String(c.unread)) : null
    if (b._name !== c.name || !b.firstChild) {
      b._name = c.name
      b.replaceChildren(avatar(c.avatar, c.name, { room: c.room }), h('span', { class: 'pin-name' }, c.name))
    }
    b.querySelector('.badge')?.remove()
    if (badge) b.append(badge)
  }

  // ------------------------------------------------------------ hold for a menu
  // Holding a conversation (a row or a pinned one) opens what can be done
  // with it — what used to hide behind a swipe to the right. So does a right
  // click, or the menu key on a focused row.
  const HOLD_MS = 460
  /** owner: what keeps the hold's state (the row, for a row's content). */
  function holdToOpen(el, open, owner = el) {
    let t = null
    const cancel = () => {
      if (!t) return
      clearTimeout(t.timer)
      t = null
    }
    el.addEventListener('pointerdown', e => {
      cancel()
      owner._held = false
      // A mouse has its right button; holding it down is still a click.
      if (e.button > 0 || e.pointerType === 'mouse') return
      t = {
        id: e.pointerId, x: e.clientX, y: e.clientY,
        timer: setTimeout(() => {
          t = null
          owner._held = true
          owner._suppress = 'hold'
          cancelPress()
          haptic()
          open(el, { touch: true })
        }, HOLD_MS)
      }
    })
    el.addEventListener('pointermove', e => {
      if (t && e.pointerId === t.id && Math.hypot(e.clientX - t.x, e.clientY - t.y) > 8) cancel()
    })
    el.addEventListener('pointerup', cancel)
    el.addEventListener('pointercancel', cancel)
    el.addEventListener('contextmenu', e => {
      e.preventDefault()
      // A touch held this long already opened it (some browsers then send
      // a contextmenu of their own).
      if (owner._held) return
      cancel()
      const keyboard = e.button !== 2 && !e.pointerType
      open(keyboard ? el : { x: e.clientX, y: e.clientY, w: 0, h: 0 }, { touch: !keyboard })
    })
    return { cancel }
  }

  function rowMenu(el, at, { touch = false } = {}) {
    const id = el.dataset.id
    const c = state.chats.get(id)
    if (!c) return
    if (openSwipe) closeSwipe()
    el.classList.add('menu-open')
    openMenu(at, [
      [
        { label: c.unread ? '标为已读' : '标为未读', icon: c.unread ? 'check' : 'unread', onSelect: () => actRead(id) },
        { label: c.pinned ? '取消置顶' : '置顶', icon: c.pinned ? 'pin-slash' : 'pin', onSelect: () => actPin(id) },
        { label: c.muted ? '取消免打扰' : '消息免打扰', icon: c.muted ? 'bell' : 'bell-slash', onSelect: () => actMute(id) }
      ],
      [{ label: '删除聊天', icon: 'trash', destructive: true, onSelect: () => actHide(id) }]
    ], { title: c.name, focusFirst: !touch, onClose: () => el.classList.remove('menu-open') })
  }

  // ------------------------------------------------------------ render
  function render() {
    updateFilters()
    if (openSwipe && !openSwipe.isConnected) openSwipe = null
    if (searching) return renderResults()
    const filter = FILTERS[state.filter] || FILTERS.all
    const all = sortedChats().filter(filter.test)
    const showPins = state.filter === 'all'
    const pins = showPins ? all.filter(c => c.pinned).slice(0, 12) : []
    const list = showPins ? all.filter(c => !c.pinned) : all

    filterNote.hidden = true

    // Pinned grid
    pinned.hidden = pins.length === 0
    pinLabel.hidden = pinned.hidden
    const pinEls = new Map([...pinned.children].map(el => [el.dataset.id, el]))
    // A launch restored from the cache is already in place; it doesn't rise in again.
    const firstPins = pinned.children.length === 0 && rowEls.size === 0 && !reducedMotion() && !state.restored
    const pinOrder = pins.map((c, i) => {
      const fresh = !pinEls.has(c.id)
      const el = pinEls.get(c.id) || buildPin(c)
      if (fresh && firstPins) enter(el, i)
      pinEls.delete(c.id)
      updatePin(el, c)
      return el
    })
    pinEls.forEach(el => el.remove())
    pinOrder.forEach((el, i) => {
      if (pinned.children[i] !== el) pinned.insertBefore(el, pinned.children[i] || null)
    })

    // Rows with FLIP reordering
    const before = new Map()
    const firstFill = rowEls.size === 0 && !reducedMotion() && !state.restored
    const animate = !reducedMotion() && rowEls.size > 0
    if (animate) {
      const top = scroll.getBoundingClientRect().top
      const bottom = top + scroll.clientHeight
      for (const [id, el] of rowEls) {
        const r = el.getBoundingClientRect()
        if (r.bottom > top && r.top < bottom) before.set(id, r.top)
      }
    }
    const keep = new Set(list.map(c => c.id))
    for (const [id, el] of rowEls) {
      if (!keep.has(id)) {
        el.remove()
        rowEls.delete(id)
      }
    }
    list.forEach((c, i) => {
      let el = rowEls.get(c.id)
      if (!el) {
        el = buildRow(c)
        rowEls.set(c.id, el)
        // The first screenful rises in one row after another.
        if (firstFill && i < 14) enter(el, i + pins.length)
      }
      updateRow(el, c)
      if (rows.children[i] !== el) rows.insertBefore(el, rows.children[i] || null)
    })
    if (animate && before.size) {
      for (const [id, oldTop] of before) {
        const el = rowEls.get(id)
        if (!el) continue
        const dy = oldTop - el.getBoundingClientRect().top
        if (Math.abs(dy) < 1) continue
        el.classList.remove('moving')
        el.style.transform = `translateY(${dy}px)`
        requestAnimationFrame(() => {
          el.classList.add('moving')
          el.style.transform = ''
          el.addEventListener('transitionend', () => el.classList.remove('moving'), { once: true })
        })
      }
    }

    placeHighlight()

    const noChats = list.length === 0 && pins.length === 0
    const emptyArt = noChats && !loading ? state.filter : null
    const newArt = emptyArt !== null && (empty.hidden || emptyArt !== shownArt)
    shownArt = emptyArt
    empty.hidden = !noChats
    empty.classList.toggle('skeleton', noChats && loading)
    if (noChats && loading) {
      if (!empty.querySelector('.sk-row')) empty.replaceChildren(skeleton())
    } else if (noChats) {
      const action = h('button', { class: 'empty-compose solid-press', type: 'button' }, state.filter === 'all' ? '新聊天' : '显示全部')
      action.addEventListener('click', () => state.filter === 'all' ? onCompose() : selectFilter('all'))
      const emptyTitle = state.filter === 'all' ? '没有聊天' : state.filter === 'unread' ? '没有未读消息' : `没有${filter.label}`
      empty.replaceChildren(h('div', { class: 'empty-art', 'aria-hidden': 'true' }, icon('bubble')), h('h2', {}, emptyTitle), action)
      // Its symbol draws on when it comes into view, not on every refresh.
      if (newArt) symbolEffect(empty.querySelector('.empty-art .icon'), 'draw-on')
    }
  }

  let highlightFrame = 0
  function placeHighlight({ instant = false } = {}) {
    cancelAnimationFrame(highlightFrame)
    highlightFrame = requestAnimationFrame(() => {
      const el = selected && rowEls.get(selected)
      const show = Boolean(el?.isConnected && !rows.hidden && pane.dataset.layout === 'leading')
      capsule.classList.toggle('on', show)
      if (!show) {
        capsule.classList.remove('ready')
        return
      }
      // Measured after any FLIP has set the row back to its final place.
      const top = el.offsetTop
      if (instant || !capsule.classList.contains('ready')) capsule.classList.remove('ready')
      capsule.style.transform = `translate3d(0, ${top}px, 0)`
      capsule.style.height = `${el.offsetHeight}px`
      if (!capsule.classList.contains('ready')) requestAnimationFrame(() => capsule.classList.add('ready'))
    })
  }
  new ResizeObserver(() => placeHighlight({ instant: true })).observe(rows)

  function enter(el, i) {
    el.style.setProperty('--s', String(i))
    el.classList.add('row-in')
    el.addEventListener('animationend', function done(e) {
      if (e.target !== el) return
      el.classList.remove('row-in')
      el.removeEventListener('animationend', done)
    })
  }

  // Placeholder rows built from the real row classes, so they always match
  // the list's geometry.
  function skeleton() {
    const widths = [[34, 78], [46, 62], [28, 84], [40, 54], [32, 70], [44, 66]]
    return h('ul', { class: 'rows', 'aria-hidden': 'true' }, widths.map(([a, b]) =>
      h('li', { class: 'row sk-row' },
        h('div', { class: 'row-inner' },
          h('span', { class: 'row-dot' }),
          h('span', { class: 'avatar sk' }),
          h('div', { class: 'row-main' },
            h('span', { class: 'sk sk-line', style: { width: `${a}%` } }),
            h('span', { class: 'sk sk-line', style: { width: `${b}%` } }))))))
  }

  // ------------------------------------------------------------ swipe to delete
  // A row swipes to the left to show Delete; let go past the middle of the
  // row and it is deleted at once. Nothing hides on the other side, so a
  // swipe to the right on a closed row is left to the column (Back).
  // The row follows the finger and settles from wherever it is, with the
  // finger's speed, so a touch catches it mid-flight. Anything else — a tap
  // on it or elsewhere, a scroll, another row, Escape, the app losing focus
  // — puts an open row back; a gesture the system takes over settles where
  // the row is and never deletes.
  const ACTION_W = 78
  const fullAt = li => li.offsetWidth * 0.55
  let drag = null // the row under the finger: { li, cancel }

  function place(li, x) {
    li._x = x
    li._r.inner.style.transform = x ? `translate3d(${x}px,0,0)` : ''
    // Delete is only as wide as what's uncovered, so none of it shows
    // around the row's rounded corners.
    li._r.actions.style.width = x < 0 ? `${-x}px` : '0px'
    li.classList.toggle('swiping', x !== 0 || drag?.li === li)
    li.classList.toggle('full', x < -fullAt(li))
  }

  function settle(li, target, velocity = 0) {
    li._anim?.stop()
    if (target === 0 && openSwipe === li) openSwipe = null
    if (target !== 0) {
      closeSwipe(li)
      openSwipe = li
    }
    li._anim = spring({
      from: li._x || 0,
      to: target,
      velocity,
      damping: target === 0 || target < -ACTION_W ? 1 : 0.86,
      response: target === 0 ? 0.3 : 0.32,
      onUpdate: x => place(li, x)
    })
    return li._anim.done
  }

  function closeSwipe(except) {
    if (openSwipe && openSwipe !== except) settle(openSwipe, 0)
  }

  function attachSwipe(li, hold) {
    const inner = li._r.inner
    inner.style.touchAction = 'pan-y'
    let g = null
    inner.addEventListener('pointerdown', e => {
      if (e.button > 0 || li._deleting || g) return
      // A touch while another row is open only puts that one back.
      const other = Boolean(openSwipe && openSwipe !== li)
      closeSwipe(li)
      li._anim?.stop()
      const start = li._x || 0
      g = { id: e.pointerId, x0: e.clientX, y0: e.clientY, start, active: false, vt: velocityTracker(), crossed: start < -fullAt(li) }
      li._suppress = other ? 'other' : start !== 0 ? 'close' : null
    })
    inner.addEventListener('pointermove', e => {
      if (!g || e.pointerId !== g.id) return
      let dx = e.clientX - g.x0
      const dy = e.clientY - g.y0
      if (!g.active) {
        if (Math.abs(dy) > 10 && Math.abs(dy) > Math.abs(dx)) {
          // A scroll: an open row goes back.
          if (g.start) settle(li, 0)
          g = null
          return
        }
        if (Math.abs(dx) < 10) return
        if (dx > 0 && g.start === 0) {
          g = null
          return
        }
        g.active = true
        // Follow from here, without a jump of the slop.
        g.x0 += Math.sign(dx) * 10
        dx = e.clientX - g.x0
        hold.cancel()
        cancelPress()
        li._suppress = 'swipe'
        drag = { li, cancel: () => finish(e, true) }
        try { inner.setPointerCapture(e.pointerId) } catch {}
      }
      g.vt.add(e.clientX, 0)
      const w = li.offsetWidth
      let x = g.start + dx
      if (x > 0) x = rubberband(x, w, 0.3)
      if (x < -w * 0.9) x = -w * 0.9 + rubberband(x + w * 0.9, w)
      place(li, x)
      const full = x < -fullAt(li)
      if (full !== g.crossed) {
        g.crossed = full
        haptic()
      }
    })
    function finish(e, cancelled) {
      if (!g || (e.pointerId !== undefined && e.pointerId !== g.id)) return
      const was = g
      g = null
      if (drag?.li === li) drag = null
      if (!was.active) {
        // Caught mid-flight and let go where it was: on to the nearer rest.
        if (was.start !== 0 && was.start !== -ACTION_W && !li._deleting) settle(li, was.start < -ACTION_W / 2 ? -ACTION_W : 0)
        return
      }
      try { inner.releasePointerCapture(was.id) } catch {}
      const x = li._x || 0
      const v = cancelled ? 0 : was.vt.velocity().x
      if (!cancelled && x < -fullAt(li)) {
        li._deleting = true
        // Delete fills the row as it goes, then the row folds away.
        settle(li, -li.offsetWidth, v).then(() => actHide(li.dataset.id, { swiped: true }))
        return
      }
      const p = x + project(v)
      settle(li, p < -ACTION_W / 2 ? -ACTION_W : 0, v)
    }
    inner.addEventListener('pointerup', e => finish(e, false))
    inner.addEventListener('pointercancel', e => finish(e, true))
    // Only the row's own capture: taking it over from the text under the
    // finger makes that text lose its (and the event bubbles up here).
    inner.addEventListener('lostpointercapture', e => { if (e.target === inner) finish(e, true) })
  }

  // Outside the open row, any touch puts it back; so does Escape, and the app
  // going to the background mid-swipe lets the row settle.
  // (A touch on another row is that row's to handle: it only closes this one.)
  document.addEventListener('pointerdown', e => {
    if (openSwipe && !openSwipe.contains(e.target) && !rows.contains(e.target)) closeSwipe()
  }, true)
  pane.addEventListener('keydown', e => {
    if (e.key === 'Escape' && openSwipe) {
      e.stopPropagation()
      closeSwipe()
    }
  })
  const letGo = () => drag?.cancel()
  window.addEventListener('blur', letGo)
  document.addEventListener('visibilitychange', letGo)

  async function actRead(id) {
    const c = state.chats.get(id)
    if (!c) return
    // Read: up to now. Unread: marked by hand, until it's read or something new comes.
    const marking = !c.unread
    patchRoom(id, marking ? { unread: 1, marked: true } : { unread: 0, marked: false })
    try {
      if (marking) await api.post(`/api/room/${id}/flags`, { unread: 1 })
      else await api.post(`/api/room/${id}/read`, { ts: Date.now() })
    } catch (err) {
      patchRoom(id, { unread: c.unread, marked: c.marked })
      toast(err.message, { type: 'error' })
    }
  }

  async function actPin(id) {
    await setFlag(id, 'pinned')
  }

  async function actMute(id) {
    await setFlag(id, 'muted')
  }

  async function setFlag(id, name) {
    const c = state.chats.get(id)
    if (!c) return
    const on = !c[name]
    patchRoom(id, { [name]: on })
    try {
      await api.post(`/api/room/${id}/flags`, { [name]: on ? 1 : 0 })
    } catch (err) {
      patchRoom(id, { [name]: !on })
      toast(err.message, { type: 'error' })
    }
  }

  async function actHide(id, { swiped = false } = {}) {
    const el = rowEls.get(id)
    if (el && openSwipe === el) openSwipe = null
    // Kept on the server while the row goes.
    const saved = api.post(`/api/room/${id}/flags`, { hidden: 1 }).then(() => null, err => err)
    if (el && !reducedMotion()) {
      // The row folds away (swiped, Delete fills it as it goes) and the ones
      // below close the gap.
      el._deleting = true
      el.style.height = `${el.offsetHeight}px`
      void el.offsetHeight
      el.classList.add('removing', swiped ? 'swiped' : 'held')
      el.style.height = '0px'
      await new Promise(r => setTimeout(r, 240))
    }
    patchRoom(id, { hidden: true })
    const err = await saved
    if (err) {
      patchRoom(id, { hidden: false })
      toast(err.message, { type: 'error' })
    }
  }

  // ------------------------------------------------------------ search
  // Searching starts from the top of the results; Cancel puts the list back
  // where it was.
  let listScroll = 0
  input.addEventListener('focus', async () => {
    if (searching) return
    searching = true
    listScroll = scroll.scrollTop
    pane.classList.add('searching')
    bars.bottom.inert = true
    head.hidden = filterTabs.hidden = pinLabel.hidden = pinned.hidden = rows.hidden = empty.hidden = filterNote.hidden = true
    results.hidden = false
    placeHighlight()
    arrangeBars()
    renderResults()
  })
  input.addEventListener('input', () => {
    query = input.value.trim()
    renderResults()
  })
  input.addEventListener('keydown', e => {
    if (e.key === 'Escape') exitSearch()
    if (e.key === 'Enter') results.querySelector('.contact-row')?.click()
  })
  cancel.addEventListener('click', exitSearch)

  /** Search from elsewhere (the sidebar): the field at the foot of the list. */
  function openSearch() {
    input.focus()
  }

  function exitSearch() {
    searching = false
    query = ''
    input.value = ''
    input.blur()
    pane.classList.remove('searching')
    bars.bottom.inert = false
    arrangeBars()
    head.hidden = filterTabs.hidden = rows.hidden = false
    results.hidden = true
    clear(results)
    render()
    scroll.scrollTop = listScroll
  }

  function highlight(text, q) {
    const i = q ? text.toLowerCase().indexOf(q.toLowerCase()) : -1
    if (i < 0) return [text]
    return [text.slice(0, i), h('mark', {}, text.slice(i, i + q.length)), text.slice(i + q.length)]
  }

  function resultRow({ name, avatar: av, room, sub, onClick }) {
    const b = h('button', { class: 'contact-row', type: 'button' },
      avatar(av, name, { room, size: 40 }),
      h('div', { class: 'grow' }, h('div', { class: 'name' }, highlight(name, query)), sub ? h('div', { class: 'sub' }, sub) : null))
    b.addEventListener('click', () => { exitSearch(); onClick() })
    return b
  }

  async function openDM(user) {
    try {
      const r = await api.post('/api/dm', { user: user.id })
      upsertRoom(r.room)
      onOpen(r.room.id)
    } catch (err) {
      toast(err.message, { type: 'error' })
    }
  }

  let searchSeq = 0
  async function renderResults() {
    clear(results)
    const q = query
    const rooms = sortedChats()
    if (!q) {
      const recent = rooms.slice(0, 10)
      if (recent.length) {
        results.append(h('div', { class: 'section-title' }, '最近'))
        for (const c of recent) results.append(resultRow({ name: c.name, avatar: c.avatar, room: c.kind === 'group', sub: c.last?.text, onClick: () => onOpen(c.id) }))
      }
      return
    }
    const lc = q.toLowerCase()
    const roomHits = rooms.filter(c => c.name.toLowerCase().includes(lc) || c.last?.text?.toLowerCase().includes(lc)).slice(0, 20)
    const contactHits = state.contacts.filter(c => c.display?.toLowerCase().includes(lc) || c.username?.toLowerCase().includes(lc))
    if (roomHits.length) {
      results.append(h('div', { class: 'section-title' }, '会话'))
      for (const c of roomHits) results.append(resultRow({ name: c.name, avatar: c.avatar, room: c.kind === 'group', sub: c.last?.text, onClick: () => onOpen(c.id) }))
    }
    if (contactHits.length) {
      results.append(h('div', { class: 'section-title' }, '联系人'))
      for (const c of contactHits) results.append(resultRow({ name: c.display, avatar: c.avatar, room: false, sub: '@' + c.username, onClick: () => openDM(c) }))
    }
    const seq = ++searchSeq
    try {
      const r = await api.get(`/api/users/search?q=${encodeURIComponent(q)}`)
      if (seq !== searchSeq || query !== q) return
      const known = new Set([...contactHits.map(c => c.id), state.me.id])
      const others = r.users.filter(u => !known.has(u.id))
      if (others.length) {
        results.append(h('div', { class: 'section-title' }, '找人'))
        for (const u of others) results.append(resultRow({ name: u.display, avatar: u.avatar, room: false, sub: '@' + u.username, onClick: () => openDM(u) }))
      }
    } catch {}
    if (!results.children.length) results.append(h('div', { class: 'list-empty' }, h('h2', {}, '无结果'), `没有找到“${q}”`))
  }

  // ------------------------------------------------------------ public
  on('chats', () => render())
  on('contacts', () => { if (searching) renderResults() })

  return {
    render,
    setSelected(id) {
      selected = id
      for (const [cid, el] of rowEls) {
        el.classList.toggle('selected', cid === id)
        el._r.inner.setAttribute('aria-current', cid === id ? 'true' : 'false')
      }
      for (const el of pinned.children) el.classList.toggle('selected', el.dataset.id === id)
      placeHighlight()
    },
    setStatus({ text, spinner = false, warn = false } = {}) {
      if (loading !== spinner) {
        loading = spinner
        if (!searching) render()
      }
      status.hidden = !text
      status.classList.toggle('warn', warn)
      // Connecting: the Wi-Fi symbol's bars light in turn until it connects.
      const signal = spinner ? status.querySelector('.i-wifi') || icon('wifi') : null
      status.replaceChildren(...(signal ? [signal] : []), text || '')
      if (signal && !signalEffect) signalEffect = symbolEffect(signal, 'variable-color')
      if (!signal) {
        signalEffect?.stop()
        signalEffect = null
      }
      statusText = text || ''
      updateFilters()
    },
    setLayout(layout) {
      pane.dataset.layout = layout
      placeHighlight({ instant: true })
      arrangeBars()
      requestAnimationFrame(positionFilterThumb)
    },
    setFilter: selectFilter,
    setMe(user) {
      me.replaceChildren(avatar(user?.avatar, user?.display, { size: 36 }))
      me.setAttribute('aria-label', `${user?.display || '我'}，设置`)
    },
    openSearch,
    focusSearch() {
      input.focus()
    }
  }
}
