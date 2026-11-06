// Pictures arriving (css/reveal.css). Until a picture is there its frame is
// alive — slow rings spread from its middle under a drifting light — and when
// it has decoded it opens out of that middle through a soft-edged circle
// rather than popping in. A picture being sent shows how far it has gone (a
// ring and a count) over its dimmed preview, and opens the same way once it
// has gone.
//
// A picture already shown this session (scrolling back, a list redrawn) is
// simply there: the frame never plays twice for the same picture.

import { reducedMotion } from './dom.js'

const shown = new Set()
const MAX_SHOWN = 2000

function remember(src) {
  if (!src) return
  shown.add(src)
  if (shown.size > MAX_SHOWN) shown.delete(shown.values().next().value)
}

/**
 * Play `frame` while `img` loads, then open the picture. Call it once the
 * img's src is set. play: open it even if already seen (a picture just sent).
 */
export function reveal(img, frame, { play = false } = {}) {
  if (!img || !frame) return
  const src = img.currentSrc || img.src
  frame.classList.add('rv')
  const ready = img.complete && img.naturalWidth > 0
  // Seen before, or already decoded: there at once.
  if (!play && (shown.has(src) || ready)) {
    remember(src)
    img.classList.add('loaded')
    return
  }
  frame.classList.add('rv-wait')
  let done = false
  const open = () => {
    if (done) return
    done = true
    remember(img.currentSrc || img.src)
    img.classList.add('loaded')
    frame.classList.remove('rv-wait')
    if (reducedMotion()) return
    frame.classList.add('rv-in')
    setTimeout(() => frame.classList.remove('rv-in'), 900)
  }
  const decoded = () => (img.decode ? img.decode().then(open, open) : open())
  if (ready) decoded()
  else img.addEventListener('load', decoded, { once: true })
  img.addEventListener('error', () => { done = true; frame.classList.remove('rv-wait', 'rv-in') }, { once: true })
}

// ------------------------------------------------------------ sending
// How far each picture being sent has gone (its local id → 0…1), kept here so
// a bubble drawn again mid-send picks it up, and told to whatever shows it.
const progress = new Map()
const justSent = new Set()

/** The upload of `cid` has reached `p` (0…1); null when it is over (sent or failed). */
export function setProgress(cid, p) {
  if (!cid) return
  if (p == null) {
    if (progress.has(cid)) justSent.add(cid)
    progress.delete(cid)
  } else progress.set(cid, Math.max(0, Math.min(1, p)))
  window.dispatchEvent(new CustomEvent('media-progress', { detail: { cid, p: progress.get(cid) ?? null } }))
}
export const progressOf = cid => progress.get(cid) ?? 0
/** Whether `cid` has just finished sending (once: the bubble that asks plays the opening). */
export function takeJustSent(cid) {
  if (!justSent.has(cid)) return false
  justSent.delete(cid)
  return true
}

/**
 * Show a send's progress on `frame` (a picture bubble) while it is going: a
 * ring filling and a count, updated live; stops when the bubble leaves.
 */
export function showProgress(frame, cid) {
  const paint = p => {
    frame.style.setProperty('--rv-p', String(p))
    const n = frame.querySelector('.rv-count')
    if (n) n.textContent = `${Math.round(p * 100)}%`
  }
  paint(progressOf(cid))
  const on = e => {
    if (e.detail.cid !== cid) return
    if (!frame.isConnected) return window.removeEventListener('media-progress', on)
    if (e.detail.p == null) return window.removeEventListener('media-progress', on)
    paint(e.detail.p)
  }
  window.addEventListener('media-progress', on)
}
