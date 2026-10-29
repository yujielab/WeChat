// Fold-aware overlays for iPhone Duo. Unfolded, a dialog, photo, drawing
// paper or call belongs to the screen half it was opened from, so the hinge
// never runs through it. The region follows the pane's live geometry, which
// already accounts for viewport segments and the fold gap.

import { getLayout, onLayout } from './viewport.js'

let lastTarget = null
for (const type of ['pointerdown', 'keydown']) {
  document.addEventListener(type, e => { lastTarget = e.target }, { capture: true, passive: true })
}

const placed = new Set()
const paneFor = side => document.querySelector(side === 'list' ? '.pane-list' : '.pane-thread')

/**
 * Which half an overlay belongs to: the origin's pane, the overlay it was
 * opened from, or the pane last touched. Decided in either posture, so an
 * overlay opened folded still lands on the right side after unfolding.
 */
export function foldSide(origin) {
  const el = [origin, lastTarget, document.activeElement].find(e => e instanceof Element && e.isConnected && e !== document.body)
  const owner = el?.closest('[data-side], .pane-list, .pane-thread')
  if (owner?.dataset.side) return owner.dataset.side
  return owner?.classList.contains('pane-list') ? 'list' : 'thread'
}

function measure(el) {
  if (!el.isConnected) {
    placed.delete(el)
    return
  }
  const pane = paneFor(el.dataset.side)
  if (getLayout() !== 'split' || !pane) {
    delete el.dataset.region
    return
  }
  const r = pane.getBoundingClientRect()
  const o = el.parentElement.getBoundingClientRect()
  el.style.setProperty('--region-left', `${Math.round(r.left - o.left)}px`)
  el.style.setProperty('--region-width', `${Math.round(r.width)}px`)
  el.dataset.region = el.dataset.side
}

/**
 * Remember an overlay's side and keep its --region-left / --region-width in
 * step with folding, unfolding and resizing. CSS opts in with [data-region].
 */
export function placeOnSide(el, side = foldSide()) {
  el.dataset.side = side
  for (const other of placed) if (!other.isConnected) placed.delete(other)
  placed.add(el)
  measure(el)
  return el
}

let frame = 0
function remeasure() {
  cancelAnimationFrame(frame)
  // After every layout listener has run, so pane geometry is current.
  frame = requestAnimationFrame(() => { for (const el of placed) measure(el) })
}
window.addEventListener('resize', remeasure)
onLayout(remeasure)
