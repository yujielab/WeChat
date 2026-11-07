// Each message's own time, when you ask for it (ui/chat-time.js has the
// marks): drag the conversation to the left and every message on screen
// shows when it was sent at the right, fading in as it goes — your messages
// slide aside for it — and let go and it settles back. Only what is on
// screen gets a time, nothing is laid out again (it all moves by
// transform), and the page doesn't scroll sideways. With a mouse, the time of
// the message under the pointer (or holding the keyboard's focus) stands
// beside it.

import { h, reducedMotion } from '../ui/dom.js'

const START = 12 // px of sideways drag before times begin to show
const MAX = 64 // px they slide at most
const SETTLE = 320 // ms back home

/**
 * Swipe-to-see-times on `scroller`, drawing in `host`; `content` is the
 * column the messages stand in (its right edge is where the times go).
 *   rows()      — the messages: [{ el, time, out }] (el: the bubble)
 *   enabled(e)  — may a touch here start it
 *   onStart()   — it began: the long press and other gestures stand aside
 *   onEnd()     — it ended (a click after it is not a tap)
 * Your messages slide aside; theirs stay where they are unless their time
 * wouldn't fit beside them, and then move just enough.
 */
export function attachTimeReveal(scroller, { content, host, rows, enabled = () => true, onStart, onEnd }) {
  let drag = null
  let shown = null // { layer, items: [{ row, out, right, w }], edge }
  let clearTimer = 0

  function build() {
    clearTimeout(clearTimer)
    shown?.layer.remove()
    const box = host.getBoundingClientRect()
    const view = scroller.getBoundingClientRect()
    const edge = content.getBoundingClientRect().right
    const items = []
    const layer = h('div', { class: 'time-reveal', 'aria-hidden': 'true' })
    for (const { el, time, out } of rows()) {
      const r = el.getBoundingClientRect()
      if (!r.height || r.bottom < view.top || r.top > view.bottom) continue // only what's on screen
      const t = h('span', { class: 'time-reveal-t' }, time)
      t.style.top = `${Math.round(r.top + r.height / 2 - box.top - 9)}px`
      t.style.right = `${Math.round(box.right - edge)}px`
      layer.append(t)
      items.push({ row: el.closest('.m'), out, right: r.right, t })
    }
    host.append(layer)
    for (const it of items) it.w = it.t.offsetWidth
    shown = { layer, items, edge }
  }

  function show(d) {
    if (!shown) return
    const { layer, items, edge } = shown
    layer.style.transform = `translateX(${MAX - d}px)`
    layer.style.opacity = String(Math.min(1, d / MAX))
    for (const { row, out, right, w } of items) {
      // where the time's left edge is now, and what must clear it
      const shift = out ? d : Math.max(0, Math.min(d, right - (edge - w + MAX - d) + 8))
      row.style.transform = shift ? `translateX(${-shift}px)` : ''
    }
  }

  function settle() {
    if (!shown) return
    const moving = !reducedMotion()
    const ease = `${SETTLE}ms cubic-bezier(.2, .9, .25, 1)`
    const { layer, items } = shown
    for (const { row } of items) row.style.transition = moving ? `transform ${ease}` : 'none'
    layer.style.transition = moving ? `transform ${ease}, opacity ${SETTLE * 0.7}ms ease-out` : 'none'
    show(0)
    layer.style.transform = `translateX(${MAX}px)`
    layer.style.opacity = '0'
    const gone = shown
    clearTimer = setTimeout(() => {
      for (const { row } of gone.items) row.style.transition = ''
      gone.layer.remove()
      if (shown === gone) shown = null
    }, moving ? SETTLE + 40 : 0)
  }

  scroller.addEventListener('pointerdown', e => {
    if (e.pointerType === 'mouse' || e.button > 0 || !e.isPrimary || !enabled(e)) return
    drag = { id: e.pointerId, x: e.clientX, y: e.clientY, active: false }
  }, { passive: true })

  scroller.addEventListener('pointermove', e => {
    if (!drag || e.pointerId !== drag.id) return
    const dx = e.clientX - drag.x
    const dy = e.clientY - drag.y
    if (!drag.active) {
      if (Math.abs(dy) > 10 && Math.abs(dy) > Math.abs(dx)) { drag = null; return } // a scroll
      if (dx > -START || Math.abs(dx) < Math.abs(dy) * 1.5) return // not (yet) a leftward drag
      drag.active = true
      onStart?.()
      build()
      for (const { row } of shown.items) row.style.transition = 'none'
      shown.layer.style.transition = 'none'
    }
    show(Math.max(0, Math.min(MAX, -dx - START)))
  }, { passive: true })

  const end = e => {
    if (!drag || (e && e.pointerId !== drag.id)) return
    const { active } = drag
    drag = null
    if (!active) return
    settle()
    onEnd?.()
  }
  scroller.addEventListener('pointerup', end)
  scroller.addEventListener('pointercancel', end)

  return { get active() { return Boolean(drag?.active) } }
}

/**
 * With a mouse: the time of the message under the pointer stands beside it
 * (on the open side of the bubble), after a moment; keyboard focus inside a
 * message shows it too.
 */
export function attachTimeHover(scroller, { host, rowOf }) {
  const label = h('span', { class: 'time-hover', 'aria-hidden': 'true' })
  let shownFor = null
  let timer = 0
  const hide = () => {
    clearTimeout(timer)
    shownFor = null
    label.classList.remove('on')
  }
  const show = (node, delay) => {
    if (shownFor === node) return
    clearTimeout(timer)
    shownFor = node
    timer = setTimeout(() => {
      const row = node.isConnected && rowOf(node)
      if (!row) return hide()
      if (!label.isConnected) host.append(label)
      label.textContent = row.time
      const box = host.getBoundingClientRect()
      const r = row.el.getBoundingClientRect()
      const w = label.offsetWidth
      label.style.top = `${Math.round(r.top + r.height / 2 - box.top - 9)}px`
      label.style.left = `${Math.round(row.out ? r.left - box.left - w - 10 : r.right - box.left + 10)}px`
      label.classList.add('on')
    }, delay)
  }
  scroller.addEventListener('pointerover', e => {
    if (e.pointerType !== 'mouse') return
    const node = e.target.closest?.('.m')
    if (node) show(node, 350)
    else hide()
  })
  scroller.addEventListener('pointerleave', hide)
  scroller.addEventListener('scroll', hide, { passive: true })
  scroller.addEventListener('focusin', e => {
    const node = e.target.closest?.('.m')
    if (node) show(node, 0)
  })
  scroller.addEventListener('focusout', e => { if (!scroller.contains(e.relatedTarget)) hide() })
  return { hide }
}
