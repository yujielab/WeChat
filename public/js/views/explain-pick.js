// Picking words out of a message to search and explain them (views/explain.js).
//
// Touch: double-tap a message, yours or theirs, to start picking — the word
// under your finger is taken and handles stand at its ends. Then slide to
// pick: from anywhere in the message to anywhere (whole words, or single
// characters in Chinese and Japanese), or drag a handle to move just that
// end; a tap takes one word. Nothing is asked until you tap Explain; a touch
// anywhere else stops picking. The message doesn't scroll the page while you
// pick, and the long-press menu and swipe-to-reply stand aside.
// With a mouse, or the menu's Select Text, words are selected the usual way
// and the same Explain button stands by the selection.

import { h, icon, reducedMotion } from '../ui/dom.js'
import { haptic } from '../ui/haptics.js'
import { segmentsOf, wordAt, pickSpan, dragEdge, pickedText } from '../ui/text-pick.js'

const DOUBLE_TAP = 340 // ms from the first tap's lift to the second touch
const NEAR = 30 // px between the two taps
const TAP_MOVE = 10 // px a tap may wander
const SLIDE = 9 // px before a slide counts
const HANDLE = 24 // px around a handle that a slide takes hold of
const ON_HANDLE = 10 // px: a tap this close to a handle is on it (and changes nothing)
const SKIP = '.m-meta, .sr-only, .pick-marks'

// ------------------------------------------------------------ the text

/** A bubble's visible words: the text and the text nodes it is made of. */
function readText(bub) {
  const nodes = []
  let text = ''
  const walker = document.createTreeWalker(bub, NodeFilter.SHOW_TEXT, {
    acceptNode: n => (n.parentElement?.closest(SKIP) ? NodeFilter.FILTER_REJECT : NodeFilter.FILTER_ACCEPT)
  })
  for (let n = walker.nextNode(); n; n = walker.nextNode()) {
    nodes.push({ node: n, start: text.length })
    text += n.data
  }
  return { text, nodes }
}

function rangeOf({ nodes }, start, end) {
  const at = i => {
    for (let k = nodes.length - 1; k >= 0; k--) if (i >= nodes[k].start) return [nodes[k].node, Math.min(i - nodes[k].start, nodes[k].node.length)]
    return [nodes[0].node, 0]
  }
  const r = document.createRange()
  r.setStart(...at(start))
  r.setEnd(...at(end))
  return r
}

// Where each character sits, measured once when picking starts (in the
// bubble's own layout pixels, so a scroll or a scaled page doesn't matter).
function measure(bub, read) {
  const box = bub.getBoundingClientRect()
  const scale = box.width / (bub.offsetWidth || box.width || 1) || 1
  const chars = []
  const { text } = read
  for (let i = 0; i < text.length;) {
    const len = text.codePointAt(i) > 0xffff ? 2 : 1
    const r = rangeOf(read, i, i + len).getBoundingClientRect()
    if (r.width > 0 && r.height > 0) {
      chars.push({ i, left: (r.left - box.left) / scale, right: (r.right - box.left) / scale, top: (r.top - box.top) / scale, bottom: (r.bottom - box.top) / scale })
    }
    i += len
  }
  return chars
}

/** The character under a point (layout px in the bubble): on the nearest line, the nearest one along it. */
export function charUnder(chars, x, y) {
  if (!chars.length) return -1
  let line = null
  let best = Infinity
  for (const c of chars) {
    const d = y < c.top ? c.top - y : y > c.bottom ? y - c.bottom : 0
    if (d < best - 0.5) { best = d; line = c.top }
  }
  let pick = -1
  let near = Infinity
  for (const c of chars) {
    if (Math.abs(c.top - line) > 2) continue
    const d = x < c.left ? c.left - x : x >= c.right ? x - c.right + 0.01 : 0
    if (d < near) { near = d; pick = c.i }
  }
  return pick
}

// ------------------------------------------------------------ the marks

/** Soft rounded marks over what is picked, one per line (and, while
 *  picking, a handle at each end). Returns the lines, in the bubble's
 *  layout pixels. */
export function markRange(bub, read, span, { handles = false } = {}) {
  let layer = bub.querySelector(':scope > .pick-marks')
  if (!span || span.end <= span.start) { layer?.remove(); return [] }
  if (!layer) {
    layer = h('span', { class: 'pick-marks', 'aria-hidden': 'true' })
    bub.append(layer)
  }
  const box = bub.getBoundingClientRect()
  const scale = box.width / (bub.offsetWidth || box.width || 1) || 1
  const lines = []
  for (const r of rangeOf(read, span.start, span.end).getClientRects()) {
    if (r.width < 0.5) continue
    const rect = { left: (r.left - box.left) / scale - bub.clientLeft, right: (r.right - box.left) / scale - bub.clientLeft, top: (r.top - box.top) / scale - bub.clientTop, bottom: (r.bottom - box.top) / scale - bub.clientTop }
    const same = lines.find(l => Math.abs(l.top - rect.top) < 4 || (rect.top < l.bottom - 2 && rect.bottom > l.top + 2))
    if (same) {
      same.left = Math.min(same.left, rect.left); same.right = Math.max(same.right, rect.right)
      same.top = Math.min(same.top, rect.top); same.bottom = Math.max(same.bottom, rect.bottom)
    } else lines.push(rect)
  }
  const marks = lines.map(l => {
    const el = h('span', { class: 'pick-mark' })
    Object.assign(el.style, { left: `${l.left - 2}px`, top: `${l.top}px`, width: `${l.right - l.left + 4}px`, height: `${l.bottom - l.top}px` })
    return el
  })
  if (handles && lines.length) {
    const first = lines[0]
    const last = lines.at(-1)
    for (const [end, x, l] of [['start', first.left - 2, first], ['end', last.right + 2, last]]) {
      const el = h('span', { class: ['pick-handle', end] })
      Object.assign(el.style, { left: `${x}px`, top: `${l.top}px`, height: `${l.bottom - l.top}px` })
      marks.push(el)
    }
  }
  layer.classList.toggle('is-picking', handles)
  layer.replaceChildren(...marks)
  return lines
}

export const clearMarks = bub => bub?.querySelector(':scope > .pick-marks')?.remove()

// ------------------------------------------------------------ touch

/** The Explain button: a glass capsule that stands by what is picked. */
function explainButton(onClick) {
  const el = h('button', { class: 'explain-pill', type: 'button', 'aria-label': 'Search and explain' }, icon('sparkles'), h('span', {}, 'Explain'))
  // keep a selection: pressing the button mustn't clear it first
  el.addEventListener('pointerdown', e => e.preventDefault())
  el.addEventListener('click', onClick)
  return el
}

/** Place the button by `rect` (client px): above it, or below where there
 *  is no room — or, given `around` (the whole message), clear of all of it,
 *  so every word stays free to touch. */
function placeButton(el, rect, { below = false, around = null } = {}) {
  const w = el.offsetWidth || 96
  const hgt = el.offsetHeight || 36
  const left = Math.max(8, Math.min(innerWidth - w - 8, rect.left + rect.width / 2 - w / 2))
  const fits = top => top >= 8 && top + hgt <= innerHeight - 8
  const over = r => r.top - hgt - 14
  const under = r => r.bottom + 14
  const tries = [...(around ? [over(around), under(around)] : []), ...(below ? [under(rect), over(rect)] : [over(rect), under(rect)])]
  const top = tries.find(fits) ?? Math.max(8, Math.min(innerHeight - hgt - 8, tries[0]))
  Object.assign(el.style, { left: `${left}px`, top: `${top}px` })
}

/**
 * Double-tap to pick, slide to choose, Explain to ask, on the messages in `scroller`.
 *   enabled(bub, node) — may this bubble be picked from
 *   onStart()          — a touch in a picking message: the long press and swipe stand aside
 *   onPick({ text, context, bub, node, clear }) — Explain was tapped
 */
export function attachPick(scroller, { enabled, onStart, onPick }) {
  let tap = null // the first tap: { bub, x, y, down, up }
  let sel = null // picking: { bub, node, read, segs, chars, span, lines }
  let drag = null // a touch in the picking message: { id, kind, anchor, fixed, x, y, moved }
  let armed = null
  let armTimer = 0
  let swallow = false
  let button = null
  let frame = 0

  const disarm = () => {
    clearTimeout(armTimer)
    armed?.classList.remove('is-pick-armed')
    armed = null
  }
  // Until the second tap may come, this bubble doesn't scroll the page, so
  // a slide straight on from it picks words instead.
  const arm = bub => {
    disarm()
    armed = bub
    bub.classList.add('is-pick-armed')
    armTimer = setTimeout(disarm, DOUBLE_TAP + 40)
  }

  const pickable = e => {
    if (e.pointerType === 'mouse' || e.button > 0 || !e.isPrimary) return null
    const bub = e.target.closest?.('.bubble.text')
    if (!bub || bub.dataset.selecting != null) return null
    const node = bub.closest('.m')
    return node && enabled(bub, node) ? { bub, node } : null
  }
  const local = (bub, ev) => {
    const b = bub.getBoundingClientRect()
    const scale = b.width / (bub.offsetWidth || b.width || 1) || 1
    return [(ev.clientX - b.left) / scale, (ev.clientY - b.top) / scale]
  }

  // ---- the selection's look: marks, handles, and the Explain button
  function draw() {
    sel.lines = markRange(sel.bub, sel.read, sel.span, { handles: true })
  }
  function showButton() {
    if (!sel) return
    if (!button) {
      button = explainButton(confirm)
      document.body.append(button)
    }
    const text = pickedText(sel.read.text, sel.span)
    button.setAttribute('aria-label', `Search and explain “${text}”`)
    button.classList.remove('is-away')
    place()
  }
  const hideButton = () => button?.classList.add('is-away')
  function place() {
    frame = 0
    if (!sel || !button) return
    if (!sel.bub.isConnected) return stop()
    const b = sel.bub.getBoundingClientRect()
    const scale = b.width / (sel.bub.offsetWidth || b.width || 1) || 1
    const ls = sel.lines?.length ? sel.lines : [{ left: 0, right: sel.bub.offsetWidth, top: 0, bottom: sel.bub.offsetHeight }]
    const x0 = Math.min(...ls.map(l => l.left)), x1 = Math.max(...ls.map(l => l.right))
    const ox = b.left + sel.bub.clientLeft * scale, oy = b.top + sel.bub.clientTop * scale
    placeButton(button, { left: ox + x0 * scale, width: (x1 - x0) * scale, top: oy + ls[0].top * scale, bottom: oy + ls.at(-1).bottom * scale }, { around: b })
  }
  const replace = () => { if (sel && !frame) frame = requestAnimationFrame(place) }

  // ---- starting and stopping
  function begin(e, { bub, node }) {
    const read = readText(bub)
    if (!read.text.trim()) return
    // the long press and the swipe stand aside before anything is measured
    onStart?.()
    const segs = segmentsOf(read.text, document.documentElement.lang || undefined)
    const chars = measure(bub, read)
    const anchor = charUnder(chars, ...local(bub, e))
    const span = anchor < 0 ? null : wordAt(segs, anchor)
    if (!span) return
    stop()
    sel = { bub, node, read, segs, chars, span, lines: [] }
    drag = { id: e.pointerId, kind: 'slide', anchor, x: e.clientX, y: e.clientY, moved: false }
    bub.classList.add('is-picking')
    draw()
    haptic()
    scroller.addEventListener('touchmove', holdStill, { passive: false })
    document.addEventListener('pointerdown', outside, true)
    document.addEventListener('keydown', onKey)
    scroller.addEventListener('scroll', replace, { passive: true })
    addEventListener('resize', stop)
  }

  /** Stop picking; the marks stay only for an answer being shown. */
  function stop({ keepMarks = false } = {}) {
    cancelAnimationFrame(frame)
    frame = 0
    button?.remove()
    button = null
    drag = null
    if (!sel) return
    const { bub } = sel
    sel = null
    bub.classList.remove('is-picking')
    disarm()
    scroller.removeEventListener('touchmove', holdStill)
    document.removeEventListener('pointerdown', outside, true)
    document.removeEventListener('keydown', onKey)
    scroller.removeEventListener('scroll', replace)
    removeEventListener('resize', stop)
    if (!keepMarks) clearMarks(bub)
  }

  function confirm() {
    if (!sel) return
    const text = pickedText(sel.read.text, sel.span)
    if (!text) return
    const { bub, node, read, span } = sel
    stop({ keepMarks: true })
    markRange(bub, read, span) // the words stay marked while they're explained
    onPick({ text, context: read.text, bub, node, clear: () => clearMarks(bub) })
  }

  const holdStill = e => { if (sel && drag) e.preventDefault() }
  // A touch anywhere but the picking message and its button stops picking.
  const outside = e => {
    if (!sel) return
    if (sel.bub.contains(e.target) || button?.contains(e.target)) return
    stop()
  }
  const onKey = e => { if (e.key === 'Escape') stop() }

  // Which handle a point (layout px in the bubble) takes hold of, if any.
  function handleAt(x, y) {
    const ls = sel.lines
    if (!ls?.length) return null
    x -= sel.bub.clientLeft
    y -= sel.bub.clientTop
    const d = (px, l) => Math.hypot(x - px, y < l.top ? l.top - y : y > l.bottom ? y - l.bottom : 0)
    const ds = d(ls[0].left, ls[0]), de = d(ls.at(-1).right, ls.at(-1))
    if (Math.min(ds, de) > HANDLE) return null
    return { end: ds < de ? 'start' : 'end', dist: Math.min(ds, de) }
  }

  // ---- touches
  scroller.addEventListener('pointerdown', e => {
    const hit = pickable(e)
    if (sel && hit?.bub === sel.bub) {
      // a touch in the message being picked from: it adjusts the selection
      tap = null
      onStart?.()
      if (!sel.bub.isConnected) return stop()
      const [x, y] = local(sel.bub, e)
      const held = handleAt(x, y)
      const kind = held?.end || 'slide'
      drag = { id: e.pointerId, kind, onHandle: Boolean(held && held.dist <= ON_HANDLE), anchor: charUnder(sel.chars, x, y), fixed: kind === 'start' ? sel.span.end : sel.span.start, x: e.clientX, y: e.clientY, moved: false }
      hideButton()
      return
    }
    if (!hit) { tap = null; return }
    const now = performance.now()
    if (tap && tap.bub === hit.bub && tap.up && now - tap.up < DOUBLE_TAP && Math.hypot(e.clientX - tap.x, e.clientY - tap.y) < NEAR) {
      tap = null
      begin(e, hit)
    } else {
      tap = { bub: hit.bub, x: e.clientX, y: e.clientY, down: now, up: 0 }
    }
  }, { passive: true })

  scroller.addEventListener('pointermove', e => {
    if (tap && Math.hypot(e.clientX - tap.x, e.clientY - tap.y) > TAP_MOVE) tap = null
    if (!sel || !drag || e.pointerId !== drag.id) return
    if (!drag.moved && Math.hypot(e.clientX - drag.x, e.clientY - drag.y) < SLIDE) return
    drag.moved = true
    const focus = charUnder(sel.chars, ...local(sel.bub, e))
    if (focus < 0) return
    const { text } = sel.read
    const span = drag.kind === 'slide'
      ? pickSpan(text, sel.segs, drag.anchor, focus, true)
      : dragEdge(text, sel.segs, drag.fixed, focus)
    if (!span || (span.start === sel.span.start && span.end === sel.span.end)) return
    sel.span = span
    draw()
    if (!reducedMotion()) haptic()
  }, { passive: true })

  scroller.addEventListener('pointerup', e => {
    if (sel && drag && e.pointerId === drag.id) {
      // a tap (no slide) takes the word under it — unless it was on a handle
      if (!drag.moved && !drag.onHandle && drag.anchor >= 0) {
        const word = wordAt(sel.segs, drag.anchor)
        if (word && (word.start !== sel.span.start || word.end !== sel.span.end)) { sel.span = word; draw(); haptic() }
      }
      drag = null
      swallow = true
      showButton()
      return
    }
    if (!tap) return
    const now = performance.now()
    if (now - tap.down > 300) { tap = null; return }
    tap.up = now
    arm(tap.bub)
  })
  scroller.addEventListener('pointercancel', e => {
    tap = null
    if (drag && e.pointerId === drag.id) { drag = null; showButton() }
  })
  // While picking, a touch on the message is the picking's alone: no click
  // follows it (no link opens, nothing else answers it).
  scroller.addEventListener('touchend', e => {
    if (!swallow) return
    swallow = false
    if (e.cancelable) e.preventDefault()
  }, { passive: false })
  scroller.addEventListener('click', e => {
    if (sel && sel.bub.contains(e.target)) { e.preventDefault(); e.stopImmediatePropagation() }
  }, true)

  return {
    get active() { return Boolean(sel) },
    /** Stop picking (and forget a first tap). */
    cancel() { stop(); tap = null }
  }
}

// ------------------------------------------------------------ selections

/**
 * An Explain button by a selection made in a message (with a mouse, or the
 * menu's Select Text): `onPick` as for touch.
 */
export function attachSelectionPill(scroller, { enabled, onPick }) {
  let pill = null
  let timer = 0
  const hide = () => { pill?.remove(); pill = null }

  const selected = () => {
    const sel = document.getSelection()
    if (!sel || sel.isCollapsed || !sel.rangeCount) return null
    const range = sel.getRangeAt(0)
    const el = n => (n?.nodeType === 1 ? n : n?.parentElement)
    const bub = el(range.commonAncestorContainer)?.closest?.('.bubble.text')
    if (!bub || !scroller.contains(bub)) return null
    const node = bub.closest('.m')
    if (!node || !enabled(bub, node)) return null
    const read = readText(bub)
    const text = pickedText(sel.toString(), { start: 0, end: sel.toString().length })
    return text ? { bub, node, text, context: read.text, rect: range.getBoundingClientRect() } : null
  }

  const show = () => {
    const s = selected()
    if (!s) return hide()
    if (!pill) {
      pill = explainButton(() => {
        const now = selected()
        hide()
        if (!now) return
        document.getSelection()?.removeAllRanges()
        onPick({ text: now.text, context: now.context, bub: now.bub, node: now.node, clear: () => {} })
      })
      document.body.append(pill)
    }
    // above a mouse selection; below the system's own menu when touched
    placeButton(pill, s.rect, { below: s.bub.dataset.selecting != null })
  }

  document.addEventListener('selectionchange', () => {
    clearTimeout(timer)
    timer = setTimeout(show, 180)
  })
  scroller.addEventListener('scroll', hide, { passive: true })
  document.addEventListener('keydown', e => { if (e.key === 'Escape') hide() })
  return { hide }
}
