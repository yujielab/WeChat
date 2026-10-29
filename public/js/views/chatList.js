// Conversation list: a large-title heading, pinned avatars, rows with swipe
// actions, filters and live search (names, remarks and pinyin), with its
// bars arranged for the display (see ui/bars.js).

import { h, icon, clear, reducedMotion, edge, stagger } from '../ui/dom.js'
import { listTime } from '../ui/format.js'
import { velocityTracker, project, rubberband, spring } from '../ui/spring.js'
import { haptic } from '../ui/haptics.js'
import { cancelPress } from '../ui/press.js'
import { state, on, sortedChats, getDraft, patchRoom, upsertRoom } from '../store.js'
import { api } from '../api.js'
import { avatar } from './avatar.js'
import { openMenu, toast } from './overlay.js'
import { createBars } from '../ui/bars.js'
import { getBars, onBars } from '../ui/viewport.js'

export const FILTERS = {
  all: { label: '全部', test: () => true },
  unread: { label: '未读', test: c => c.unread > 0 },
  people: { label: '私聊', test: c => !c.room },
  groups: { label: '群聊', test: c => c.room }
}

export function createChatList(pane, { onOpen, onBack, onFilter, onCompose, loadContacts }) {
  pane.classList.add('pane-list')
  // Rows swipe themselves; a back swipe starts at the column's leading edge.
  pane.dataset.edgeSwipe = ''
  let selected = null
  let searching = false
  let query = ''
  let openSwipe = null
  let loading = false // connecting / fetching chats: show a skeleton, not "no chats"

  // ------------------------------------------------------------ skeleton
  const status = h('span', { class: 'conn-status', role: 'status', hidden: true })
  const title = h('h1', { class: 'large-title' }, '消息', h('span', { class: 'title-period', 'aria-hidden': 'true' }, '.'))
  const head = h('header', { class: 'list-head' }, h('div', { class: 'list-heading' }, title, status))
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
  const pinLabel = h('div', { class: 'pinned-label', hidden: true }, icon('pin'), '留在身边')
  // Unfolded, one shared capsule marks the open conversation and glides
  // between rows (and along with a row as it reorders) instead of jumping.
  const capsule = h('span', { class: 'row-highlight', 'aria-hidden': 'true' })
  const scroll = h('div', { class: 'scroll list-scroll' }, head, filterTabs, filterNote, pinLabel, pinned, rows, capsule, empty, results)

  const inlineTitle = h('div', { class: 'list-inline-title', 'aria-hidden': 'true' }, '消息')
  const brand = h('div', { class: 'list-brand', 'aria-label': 'Duo' }, h('span', { class: 'list-brand-mark', 'aria-hidden': 'true' }, icon('bubble'), icon('bubble')), h('span', { class: 'list-wordmark' }, 'Duo'), inlineTitle)
  const topbar = h('div', { class: 'list-topbar' }, brand, h('div', { class: 'spacer' }))

  // Bars (Apple HIG, Designing for iPhone Duo). Folded, they run down the
  // trailing edge: Back to the sidebar and filters at the top, search and
  // New Chat at the bottom, where they were on a standard iPhone. As the
  // leading column beside a conversation, the list keeps horizontal bars
  // above itself, and New Chat moves to the conversation's column, as in
  // Mail and Notes. Beside the sidebar it has neither Back nor filters: the
  // sidebar, with its scopes, is right there.
  const bars = createBars({
    label: '聊天列表操作',
    items: [
      { id: 'cancel', icon: 'xmark', title: '取消搜索', primary: true, onSelect: () => exitSearch() },
      { id: 'back', icon: 'chevron-left', title: '边栏', primary: true, onSelect: () => onBack() },
      { id: 'filter', icon: 'filter', title: '筛选', priority: 3, menu: true, onSelect: anchor => openFilterMenu(anchor) },
      { id: 'search', icon: 'search', title: '搜索', priority: 6, onSelect: () => openSearch() },
      { id: 'compose', icon: 'compose', title: '新聊天', priority: 9, prominent: true, onSelect: () => onCompose() }
    ],
    arrange: axis => {
      const nav = pane.dataset.layout === 'trailing' ? [] : [['back'], ['filter']]
      if (axis === 'vertical') {
        return searching ? { top: [['cancel']], bottom: [] } : { top: nav, bottom: [['search'], ['compose']] }
      }
      const composeHere = !(pane.dataset.layout === 'leading' && getBars() === 'vertical')
      return { top: [...nav, ...(composeHere ? [['compose']] : [])], bottom: [] }
    }
  })
  const rail = h('nav', { class: 'duo-rail list-rail', 'aria-label': '聊天列表操作' })

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
  const bottombar = h('div', { class: 'list-bottombar' }, pill, cancel)

  const edgeTop = edge('top')
  const edgeBottom = edge('bottom', true)
  pane.append(scroll, edgeTop, topbar, edgeBottom, bottombar, rail)

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

  let barsFrame = 0
  function arrangeBars() {
    cancelAnimationFrame(barsFrame)
    barsFrame = requestAnimationFrame(() => {
      const axis = pane.dataset.layout === 'leading' ? 'horizontal' : getBars() || 'vertical'
      pane.dataset.bars = axis
      if (axis === 'vertical') {
        if (bars.top.parentElement !== rail) bars.move(() => rail.append(bars.top, bars.bottom))
        bars.layout('vertical', rail.clientHeight)
      } else {
        if (bars.top.parentElement !== topbar) bars.move(() => { topbar.append(bars.top); bars.bottom.remove() })
        bars.layout('horizontal', { top: Math.max(0, topbar.clientWidth - brand.offsetWidth - 16), bottom: Infinity })
      }
    })
  }
  new ResizeObserver(arrangeBars).observe(rail)
  new ResizeObserver(arrangeBars).observe(topbar)
  onBars(arrangeBars)

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
      pane.classList.toggle('collapsed', y > 76)
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
    r.readBtn = h('button', { class: 'row-action blue', type: 'button' })
    r.pinBtn = h('button', { class: 'row-action yellow', type: 'button' })
    r.hideBtn = h('button', { class: 'row-action red', type: 'button' }, icon('trash'), '删除')
    const li = h('li', { class: 'row', dataset: { id: c.id } },
      h('div', { class: 'row-actions left' }, r.readBtn, r.pinBtn),
      h('div', { class: 'row-actions right' }, r.hideBtn),
      r.inner)
    li._r = r
    r.inner.addEventListener('click', () => {
      if (li._swiped) return
      onOpen(li.dataset.id)
    })
    r.inner.addEventListener('keydown', e => {
      if (e.key === 'Enter' || e.key === ' ') {
        e.preventDefault()
        onOpen(li.dataset.id)
      }
    })
    r.readBtn.addEventListener('click', () => actRead(li.dataset.id))
    r.pinBtn.addEventListener('click', () => actPin(li.dataset.id))
    r.hideBtn.addEventListener('click', () => actHide(li.dataset.id))
    attachSwipe(li)
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
    r.flag.replaceChildren(...(c.muted ? [icon('bell-slash')] : []))
    r.time.textContent = listTime(c.ts)
    r.preview.replaceChildren(...preview(c))
    r.unread.hidden = !c.unread
    r.unread.textContent = c.unread > 99 ? '99+' : String(c.unread || '')
    r.inner.setAttribute('aria-label', label(c))
    r.inner.setAttribute('aria-current', c.id === selected ? 'true' : 'false')
    r.readBtn.replaceChildren(icon(c.unread ? 'check' : 'unread'), c.unread ? '已读' : '未读')
    r.pinBtn.replaceChildren(icon(c.pinned ? 'pin-slash' : 'pin'), c.pinned ? '取消置顶' : '置顶')
  }

  function buildPin(c) {
    const b = h('button', { class: 'pin', type: 'button', role: 'listitem', dataset: { id: c.id } })
    b.addEventListener('click', () => onOpen(b.dataset.id))
    b.addEventListener('contextmenu', e => {
      e.preventDefault()
      pinMenu(b, b.dataset.id)
    })
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

  function pinMenu(anchor, id) {
    const c = state.chats.get(id)
    if (!c) return
    openMenu(anchor, [[
      { label: '取消置顶', icon: 'pin-slash', onSelect: () => actPin(id) },
      { label: c.unread ? '标为已读' : '标为未读', icon: c.unread ? 'check' : 'unread', onSelect: () => actRead(id) }
    ]])
  }

  // ------------------------------------------------------------ render
  function render() {
    updateFilters()
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
    const firstPins = pinned.children.length === 0 && rowEls.size === 0 && !reducedMotion()
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
    const firstFill = rowEls.size === 0 && !reducedMotion()
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
    empty.hidden = !noChats
    empty.classList.toggle('skeleton', noChats && loading)
    if (noChats && loading) {
      if (!empty.querySelector('.sk-row')) empty.replaceChildren(skeleton())
    } else if (noChats) {
      const action = h('button', { class: 'empty-compose solid-press', type: 'button' }, icon(state.filter === 'all' ? 'compose' : 'bubble'), state.filter === 'all' ? '发起新聊天' : '查看全部聊天')
      action.addEventListener('click', () => state.filter === 'all' ? onCompose() : selectFilter('all'))
      const emptyTitle = state.filter === 'all' ? '从一句你好开始' : state.filter === 'unread' ? '都看过了，真好' : `还没有${filter.label}`
      empty.replaceChildren(
        h('div', { class: 'empty-art', 'aria-hidden': 'true' }, h('span', { class: 'empty-bubble' }, icon('bubble')), h('span', { class: 'empty-spark' }, icon(state.filter === 'unread' ? 'check' : 'brush'))),
        h('h2', {}, emptyTitle), action
      )
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

  // ------------------------------------------------------------ swipe actions
  function closeSwipe(except) {
    if (openSwipe && openSwipe !== except) {
      const li = openSwipe
      openSwipe = null
      settle(li, 0, 0)
    }
  }

  function settle(li, target, velocity) {
    const inner = li._r.inner
    const from = li._x || 0
    li._anim?.stop()
    li._anim = spring({
      from,
      to: target,
      velocity,
      damping: target === 0 ? 1 : 0.86,
      response: 0.32,
      onUpdate: x => {
        li._x = x
        inner.style.transform = x ? `translate3d(${x}px,0,0)` : ''
      }
    })
    if (target !== 0) openSwipe = li
    else li._anim.done.then(done => { if (done && !li._x) li.classList.remove('swiping') })
  }

  function attachSwipe(li) {
    const inner = li._r.inner
    inner.style.touchAction = 'pan-y'
    let g = null
    inner.addEventListener('pointerdown', e => {
      if (e.button > 0) return
      closeSwipe(li)
      li._anim?.stop()
      g = { id: e.pointerId, x0: e.clientX, y0: e.clientY, start: li._x || 0, active: false, vt: velocityTracker(), crossed: false }
      li._swiped = false
    })
    inner.addEventListener('pointermove', e => {
      if (!g || e.pointerId !== g.id) return
      const dx = e.clientX - g.x0
      const dy = e.clientY - g.y0
      if (!g.active) {
        if (Math.abs(dy) > 10 && Math.abs(dy) > Math.abs(dx)) {
          g = null
          return
        }
        if (Math.abs(dx) < 10) return
        g.active = true
        li._swiped = true
        li.classList.add('swiping')
        cancelPress()
        try { inner.setPointerCapture(e.pointerId) } catch {}
      }
      g.vt.add(e.clientX, 0)
      const leftW = 156
      const rightW = li.offsetWidth * 0.9
      let x = g.start + dx
      if (x > leftW) x = leftW + rubberband(x - leftW, li.offsetWidth)
      if (x < -rightW) x = -rightW + rubberband(x + rightW, li.offsetWidth)
      li._x = x
      inner.style.transform = `translate3d(${x}px,0,0)`
      const full = x < -li.offsetWidth * 0.55
      if (full !== g.crossed) {
        g.crossed = full
        haptic()
      }
    })
    const end = e => {
      if (!g || e.pointerId !== g.id) return
      const was = g
      g = null
      if (!was.active) return
      setTimeout(() => { li._swiped = false }, 50)
      const v = was.vt.velocity().x
      const x = li._x || 0
      const p = x + project(v)
      if (x < -li.offsetWidth * 0.55) {
        settle(li, -li.offsetWidth, v)
        actHide(li.dataset.id)
        return
      }
      if (p > 100) settle(li, 156, v)
      else if (p < -60) settle(li, -78, v)
      else settle(li, 0, v)
    }
    inner.addEventListener('pointerup', end)
    inner.addEventListener('pointercancel', end)
  }

  async function actRead(id) {
    closeSwipe()
    const c = state.chats.get(id)
    if (!c || !c.unread) return
    patchRoom(id, { unread: 0 })
    try {
      await api.post(`/api/room/${id}/read`, { ts: Date.now() })
    } catch (err) {
      toast(err.message, { type: 'error' })
    }
  }

  async function actPin(id) {
    closeSwipe()
    const c = state.chats.get(id)
    if (!c) return
    const on = !c.pinned
    patchRoom(id, { pinned: on })
    try {
      await api.post(`/api/room/${id}/flags`, { pinned: on ? 1 : 0 })
    } catch (err) {
      patchRoom(id, { pinned: !on })
      toast(err.message, { type: 'error' })
    }
  }

  async function actHide(id) {
    openSwipe = null
    const el = rowEls.get(id)
    state.chats.delete(id)
    if (el && !reducedMotion()) {
      el.style.transition = 'opacity 180ms ease-out'
      el.style.opacity = '0'
      await new Promise(r => setTimeout(r, 180))
    }
    rowEls.delete(id)
    el?.remove()
    render()
    try {
      await api.post(`/api/room/${id}/flags`, { hidden: 1 })
    } catch (err) {
      toast(err.message, { type: 'error' })
    }
  }

  // ------------------------------------------------------------ search
  input.addEventListener('focus', async () => {
    if (searching) return
    searching = true
    pane.classList.add('searching')
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

  // With vertical bars, Search is a button; the field opens above the list
  // and Close takes the top of the column until the search ends.
  function openSearch() {
    pane.classList.add('search-open')
    input.focus()
  }

  function exitSearch() {
    searching = false
    query = ''
    input.value = ''
    input.blur()
    pane.classList.remove('searching', 'search-open')
    arrangeBars()
    head.hidden = filterTabs.hidden = rows.hidden = false
    results.hidden = true
    clear(results)
    render()
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
      if (!recent.length) results.append(h('div', { class: 'search-intro' }, icon('search'), h('h2', {}, '找一位朋友，聊点什么'), h('p', {}, '输入用户名、昵称或消息内容')))
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
      status.replaceChildren(...(spinner ? [h('span', { class: 'spinner' })] : []), text || '')
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
    openSearch,
    focusSearch() {
      input.focus()
    }
  }
}
