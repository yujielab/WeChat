// Picking words out of a message to search and explain them (views/explain.js).
//
// Touch: double-tap a message, yours or theirs, and keep the finger down —
// the word under it is picked; slide to take in more (whole words, or single
// characters in Chinese and Japanese), and let go to ask. The page doesn't
// scroll while you pick; the long-press menu and swipe-to-reply stand aside.
// With a mouse, or the menu's Select Text, words are selected the usual way
// and an Explain button stands by the selection.

import { h, icon, reducedMotion } from '../ui/dom.js'
import { haptic } from '../ui/haptics.js'
import { segmentsOf, pickSpan, pickedText } from '../ui/text-pick.js'

const DOUBLE_TAP = 340 // ms from the first tap's lift to the second touch
const NEAR = 30 // px between the two taps
const TAP_MOVE = 10 // px a tap may wander
const SLIDE = 9 // px before a slide counts
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

/** Soft rounded marks behind what is picked, one per line. */
export function markRange(bub, read, span) {
  let layer = bub.querySelector(':scope > .pick-marks')
  if (!span || span.end <= span.start) { layer?.remove(); return }
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
  layer.replaceChildren(...marks)
}

export const clearMarks = bub => bub?.querySelector(':scope > .pick-marks')?.remove()

// ------------------------------------------------------------ touch

/**
 * Double-tap and slide on the messages in `scroller`.
 *   enabled(bub, node) — may this bubble be picked from
 *   onStart()          — picking began: the long press and swipe stand aside
 *   onPick({ text, context, bub, node }) — let go over something picked
 */
export function attachPick(scroller, { enabled, onStart, onPick }) {
  let tap = null // the first tap: { bub, x, y, down, up }
  let pick = null
  let armed = null
  let armTimer = 0

  const disarm = () => {
    clearTimeout(armTimer)
    armed?.classList.remove('is-pick-armed')
    armed = null
  }
  // Until the second tap may come, this bubble doesn't scroll the page, so
  // a slide after it picks words instead.
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

  scroller.addEventListener('pointerdown', e => {
    const hit = pickable(e)
    if (!hit) { tap = null; return }
    const now = performance.now()
    if (tap && tap.bub === hit.bub && tap.up && now - tap.up < DOUBLE_TAP && Math.hypot(e.clientX - tap.x, e.clientY - tap.y) < NEAR) {
      tap = null
      begin(e, hit)
    } else {
      tap = { bub: hit.bub, x: e.clientX, y: e.clientY, down: now, up: 0 }
    }
  }, { passive: true })

  function begin(e, { bub, node }) {
    const read = readText(bub)
    if (!read.text.trim()) return
    // the long press and the swipe stand aside before anything is measured
    onStart?.()
    const segs = segmentsOf(read.text, document.documentElement.lang || undefined)
    const chars = measure(bub, read)
    const local = ev => {
      const b = bub.getBoundingClientRect()
      const scale = b.width / (bub.offsetWidth || b.width || 1) || 1
      return [(ev.clientX - b.left) / scale, (ev.clientY - b.top) / scale]
    }
    const anchor = charUnder(chars, ...local(e))
    if (anchor < 0) return
    const span = pickSpan(read.text, segs, anchor, anchor, false)
    if (!span) return
    pick = { id: e.pointerId, bub, node, read, segs, chars, local, anchor, x: e.clientX, y: e.clientY, moved: false, span }
    bub.classList.add('is-picking')
    markRange(bub, read, pick.span)
    haptic()
    scroller.addEventListener('touchmove', holdStill, { passive: false })
  }
  const holdStill = e => { if (pick) e.preventDefault() }

  scroller.addEventListener('pointermove', e => {
    if (tap && Math.hypot(e.clientX - tap.x, e.clientY - tap.y) > TAP_MOVE) tap = null
    if (!pick || e.pointerId !== pick.id) return
    if (!pick.moved && Math.hypot(e.clientX - pick.x, e.clientY - pick.y) < SLIDE) return
    pick.moved = true
    const focus = charUnder(pick.chars, ...pick.local(e))
    const span = pickSpan(pick.read.text, pick.segs, pick.anchor, focus, true)
    if (!span || (span.start === pick.span?.start && span.end === pick.span?.end)) return
    pick.span = span
    markRange(pick.bub, pick.read, span)
    if (!reducedMotion()) haptic()
  }, { passive: true })

  const finish = (e, ask) => {
    if (!pick || e.pointerId !== pick.id) return
    const { bub, node, read, span } = pick
    pick = null
    scroller.removeEventListener('touchmove', holdStill)
    bub.classList.remove('is-picking')
    disarm()
    const text = pickedText(read.text, span)
    if (!ask || !text) { clearMarks(bub); return }
    picked = true
    onPick({ text, context: read.text, bub, node, clear: () => clearMarks(bub) })
  }
  // The touch's own click would land on whatever opened under the finger
  // (the sheet's scrim) and close it: it's dropped.
  let picked = false
  scroller.addEventListener('touchend', e => {
    if (!picked) return
    picked = false
    if (e.cancelable) e.preventDefault()
  }, { passive: false })
  scroller.addEventListener('pointerup', e => {
    if (pick) return finish(e, true)
    if (!tap) return
    const now = performance.now()
    if (now - tap.down > 300) { tap = null; return }
    tap.up = now
    arm(tap.bub)
  })
  scroller.addEventListener('pointercancel', e => { tap = null; finish(e, false) })

  return {
    get active() { return Boolean(pick) },
    /** Stop picking (and forget a first tap). */
    cancel() { if (pick) finish({ pointerId: pick.id }, false); tap = null; disarm() }
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
      pill = h('button', { class: 'explain-pill', type: 'button', 'aria-label': 'Search and explain' }, icon('sparkles'), h('span', {}, 'Explain'))
      // keep the selection: pressing the button mustn't clear it first
      pill.addEventListener('pointerdown', e => e.preventDefault())
      pill.addEventListener('click', () => {
        const now = selected()
        hide()
        if (!now) return
        document.getSelection()?.removeAllRanges()
        onPick({ text: now.text, context: now.context, bub: now.bub, node: now.node, clear: () => {} })
      })
      document.body.append(pill)
    }
    // above a mouse selection; below the system's own menu when touched
    const below = s.bub.dataset.selecting != null
    const w = pill.offsetWidth || 96
    const left = Math.max(8, Math.min(innerWidth - w - 8, s.rect.left + s.rect.width / 2 - w / 2))
    const top = below ? Math.min(innerHeight - 56, s.rect.bottom + 12) : Math.max(8, s.rect.top - 48)
    Object.assign(pill.style, { left: `${left}px`, top: `${top}px` })
  }

  document.addEventListener('selectionchange', () => {
    clearTimeout(timer)
    timer = setTimeout(show, 180)
  })
  scroller.addEventListener('scroll', hide, { passive: true })
  document.addEventListener('keydown', e => { if (e.key === 'Escape') hide() })
  return { hide }
}
