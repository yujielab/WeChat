// Fold-aware overlays for iPhone Duo. Unfolded, a dialog, photo or call
// belongs to the column it was opened from, so the hinge never runs through
// it. The region follows the column's live geometry, which already accounts
// for viewport segments and the fold gap; if that column has slid out of the
// window, the overlay moves to the half of the screen nearest to it.

import { getLayout, onLayout } from './viewport.js'

let lastTarget = null
for (const type of ['pointerdown', 'keydown']) {
  document.addEventListener(type, e => { lastTarget = e.target }, { capture: true, passive: true })
}

const placed = new Set()
const COLS = ['sidebar', 'list', 'thread', 'artifact']
function paneFor(side) {
  const pane = document.querySelector(`.pane[data-col="${side}"]`)
  if (!pane || pane.dataset.role !== 'hidden') return pane
  const leading = document.querySelector('.pane[data-role="leading"]')
  const before = leading && COLS.indexOf(side) < COLS.indexOf(leading.dataset.col)
  return before ? leading : document.querySelector('.pane[data-role="trailing"]') || leading
}

/**
 * Which column an overlay belongs to: the origin's column, the overlay it
 * was opened from, or the column last touched. Decided in either posture, so
 * an overlay opened folded still lands on the right side after unfolding.
 */
export function foldSide(origin) {
  const el = [origin, lastTarget, document.activeElement].find(e => e instanceof Element && e.isConnected && e !== document.body)
  const owner = el?.closest('[data-side], .pane[data-col]')
  return owner?.dataset.side || owner?.dataset.col || 'thread'
}

function measure(el) {
  if (!el.isConnected) {
    placed.delete(el)
    return
  }
  const pane = paneFor(el.dataset.side)
  if (getLayout() !== 'split' || !pane) {
    delete el.dataset.region
    delete el.dataset.place
    return
  }
  const r = pane.getBoundingClientRect()
  const o = el.parentElement.getBoundingClientRect()
  el.style.setProperty('--region-left', `${Math.round(r.left - o.left)}px`)
  el.style.setProperty('--region-width', `${Math.round(r.width)}px`)
  el.dataset.region = el.dataset.side
  // leading | trailing: which half it's on, whichever column that is.
  el.dataset.place = pane.dataset.role
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
