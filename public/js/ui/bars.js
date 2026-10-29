// Toolbar items laid out the iPhone Duo way (Apple HIG, "Vertical controls").
// One item model renders either as a column on the trailing edge or as
// standard top / bottom bars, so the same actions keep the same relative
// order in every pose:
//  * every item has a symbol and a title; the title names it in the
//    overflow menu, to assistive technology and as a tooltip;
//  * primary navigation (Back, Close) leads, prominent actions follow, and
//    the remaining items keep their groups; spacing comes from the groups;
//  * when there isn't room, items move into the one overflow menu — the only
//    place the ellipsis appears — from the bottom up unless a priority says
//    otherwise, and items showing a badge stay visible longer.

import { h, icon } from './dom.js'
import { symbolEffect } from './symbols.js'
import { openMenu } from '../views/overlay.js'

const BUTTON = 44
const GROUP_PAD = 4
const ITEM_GAP = 2
const GROUP_GAP = 10
const SECTION_GAP = 20
const BADGE_BOOST = 10

/**
 * items: [{ id, icon, title, priority = 0, primary, prominent, menu, toggle, badge: () => text, onSelect(anchor) }]
 * arrange(axis) → { top: [[id, …], …], bottom: [[id, …], …] }; ids left out don't show on that axis.
 */
export function createBars({ label, items, arrange }) {
  const byId = new Map()
  const order = []
  for (const item of items) {
    const button = h('button', {
      class: ['glass', 'glass-btn', 'bar-item', item.prominent && 'prominent', item.primary && 'primary'],
      type: 'button',
      title: item.title,
      dataset: { item: item.id },
      'aria-haspopup': item.menu ? 'menu' : undefined
    }, icon(item.icon), h('span', { class: 'bar-badge tabular', 'aria-hidden': 'true', hidden: true }))
    button.addEventListener('click', () => {
      // Actions acknowledge the tap with a bounce; navigation answers by moving.
      if (!item.primary) symbolEffect(button.querySelector('.icon'), 'bounce')
      item.onSelect?.(button)
    })
    byId.set(item.id, { ...item, button, state: {} })
    order.push(item.id)
  }

  const more = h('button', {
    class: 'glass glass-btn bar-item bar-more', type: 'button', title: '更多', 'aria-label': '更多', 'aria-haspopup': 'menu', hidden: true
  }, icon('ellipsis'))
  const top = h('div', { class: 'bar-section bar-top', role: 'group', 'aria-label': `${label}（上）` })
  const bottom = h('div', { class: 'bar-section bar-bottom', role: 'group', 'aria-label': `${label}（下）` })
  let axis = 'vertical'
  let hidden = new Set()
  let menu = null

  more.addEventListener('click', () => {
    if (menu && !menu.closed) return menu.close()
    const overflow = order.filter(id => hidden.has(id)).map(id => byId.get(id))
    menu = openMenu(more, [overflow.map(item => ({
      label: item.title + (badgeText(item) ? `（${badgeText(item)}）` : ''),
      icon: item.icon,
      checked: item.toggle ? Boolean(item.state.active) : undefined,
      toggle: item.toggle,
      disabled: item.state.disabled,
      onSelect: () => item.onSelect?.(more)
    }))], { title: label })
  })

  const badgeText = item => (item.badge?.() || '')
  const weight = item => (item.primary ? Infinity : (item.priority || 0) + (badgeText(item) ? BADGE_BOOST : 0))
  const groupLength = n => (n > 1 ? GROUP_PAD * 2 + n * BUTTON + (n - 1) * ITEM_GAP : BUTTON)
  const sectionLength = groups => {
    const sizes = groups.map(g => g.length).filter(Boolean)
    return sizes.reduce((sum, n) => sum + groupLength(n), 0) + Math.max(0, sizes.length - 1) * GROUP_GAP
  }

  /** Visible groups for a section, with the overflow button placed per HIG. */
  function visibleGroups(groups, withMore, where) {
    const out = groups.map(g => g.filter(id => !hidden.has(id))).filter(g => g.length)
    if (!withMore) return out
    if (where === 'after-primary') {
      const lead = out.length && out[0].every(id => byId.get(id)?.primary) ? 1 : 0
      out.splice(lead, 0, ['@more'])
    } else out.push(['@more'])
    return out
  }

  /**
   * Lay the items out for an axis. room: the main-axis length available —
   * one number for the vertical column, or { top, bottom } for horizontal bars.
   */
  // When the focused item moves into the overflow menu, focus moves to the
  // menu's button, and comes back if the item does.
  let parked = null
  let lastSignature = ''
  function layout(nextAxis, room) {
    const active = document.activeElement
    const focused = [...byId.values()].find(item => item.button === active)
    const moreFocused = active === more
    axis = nextAxis
    const plan = arrange(axis) || { top: [], bottom: [] }
    const listed = [...plan.top.flat(), ...plan.bottom.flat()].filter(id => byId.has(id))
    hidden = new Set()
    const fits = () => {
      const anyHidden = hidden.size > 0
      if (axis === 'vertical') {
        const t = sectionLength(visibleGroups(plan.top, anyHidden, 'after-primary'))
        const b = sectionLength(visibleGroups(plan.bottom, false))
        return t + b + (t && b ? SECTION_GAP : 0) <= room
      }
      return sectionLength(visibleGroups(plan.top, anyHidden, 'end')) <= (room?.top ?? Infinity) &&
        sectionLength(visibleGroups(plan.bottom, false)) <= (room?.bottom ?? Infinity)
    }
    // Overflow from the bottom up: the lowest weight goes first, and among
    // equals the one listed last. Primary navigation never overflows.
    const candidates = listed
      .map((id, index) => ({ id, index, weight: weight(byId.get(id)) }))
      .filter(c => c.weight !== Infinity)
      .sort((a, b) => a.weight - b.weight || b.index - a.index)
    for (const c of candidates) {
      if (fits()) break
      hidden.add(c.id)
    }
    const topGroups = visibleGroups(plan.top, hidden.size > 0, axis === 'vertical' ? 'after-primary' : 'end')
    const bottomGroups = visibleGroups(plan.bottom, false)
    // Unchanged arrangements leave the DOM (and an open overflow menu) alone.
    const signature = JSON.stringify([axis, topGroups, bottomGroups, listed])
    if (signature === lastSignature) return
    lastSignature = signature
    render(top, topGroups)
    render(bottom, bottomGroups)
    for (const id of order) {
      const item = byId.get(id)
      item.button.hidden = !listed.includes(id) || hidden.has(id)
    }
    more.hidden = hidden.size === 0
    top.dataset.axis = bottom.dataset.axis = axis
    if (menu && !menu.closed) menu.close()
    // Moving an element between groups drops its focus; put it back, or on
    // the overflow button if the item moved into the menu.
    if (focused) {
      if (!focused.button.hidden) focused.button.focus({ preventScroll: true })
      else if (!more.hidden) {
        parked = focused
        more.focus({ preventScroll: true })
      }
    } else if (moreFocused) {
      if (parked && !parked.button.hidden) {
        parked.button.focus({ preventScroll: true })
        parked = null
      } else if (!more.hidden) more.focus({ preventScroll: true })
    }
  }

  function render(section, groups) {
    const wanted = groups.map(ids => {
      const lead = ids.every(id => id !== '@more' && byId.get(id)?.primary)
      const group = h('div', { class: ['bar-group', ids.length > 1 && 'capsule', lead && 'lead'] })
      for (const id of ids) group.append(id === '@more' ? more : byId.get(id).button)
      return group
    })
    section.replaceChildren(...wanted)
  }

  function refresh() {
    for (const item of byId.values()) {
      const text = badgeText(item)
      const badge = item.button.querySelector('.bar-badge')
      badge.hidden = !text
      badge.textContent = text
      item.button.setAttribute('aria-label', text ? `${item.title}，${text}` : item.title)
      item.button.classList.toggle('active', Boolean(item.state.active))
      item.button.disabled = Boolean(item.state.disabled)
      if (item.toggle) item.button.setAttribute('aria-pressed', String(Boolean(item.state.active)))
    }
  }
  refresh()

  return {
    top,
    bottom,
    layout,
    refresh,
    /** Update an item's title or state ({ active, disabled }) without rebuilding it. */
    set(id, { title, state } = {}) {
      const item = byId.get(id)
      if (!item) return
      if (title) { item.title = title; item.button.title = title }
      if (state) item.state = { ...item.state, ...state }
      refresh()
    },
    button: id => byId.get(id)?.button,
    /** Run a DOM move of the sections (an axis change) without losing focus. */
    move(change) {
      const active = document.activeElement
      const inside = active && (top.contains(active) || bottom.contains(active))
      change()
      if (inside && active.isConnected && document.activeElement !== active) active.focus({ preventScroll: true })
    },
    get axis() { return axis },
    get overflow() { return order.filter(id => hidden.has(id)) },
    /** Main-axis length the current arrangement needs if nothing overflows. */
    lengths(forAxis) {
      const plan = arrange(forAxis) || { top: [], bottom: [] }
      return { top: sectionLength(plan.top), bottom: sectionLength(plan.bottom) }
    }
  }
}
