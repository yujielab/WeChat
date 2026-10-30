// Viewport tracking for iPhone Duo.
//
// * Pins the app to the visual viewport (--vvh / --vvt) so the keyboard
//   shrinks the app instead of scrolling the page, and flags data-kb="1"
//   while the keyboard is up.
// * Decides the layout: "split" (unfolded inner display, ≥700px wide) or
//   "stack" (folded outer display, Split View halves, narrow windows).
//   Folding/unfolding changes the width without a rotation, so this listens
//   to size, not orientation.
// * Folding and unfolding morph instead of cutting: where the browser has
//   view transitions, the conversation's title, tools and field travel to
//   their new places while the list slides in (or out) from the left.
// * Decides where bars go (Apple HIG, Designing for iPhone Duo): toolbars and
//   navigation controls move to the trailing edge ("vertical") wherever the
//   window is wide or short — the outer display, the inner display in
//   landscape — and stay as standard top / bottom bars only where there is
//   vertical room, like the inner display in portrait (data-bars).
// * Reports the folding region when the device is partially open, from the
//   browser's viewport segments (data-fold, --fold-start / --fold-end).

import { reducedMotion } from './dom.js'

const root = document.documentElement
const vv = window.visualViewport
const SPLIT_MIN = 700
// Height below which a portrait window has no room for top and bottom bars.
const TALL_MIN = 760
// A right inset this wide is a column the bars can share (the rail is 52pt).
const EDGE_COLUMN_MIN = 64
// …and no wider than this: a larger shortfall is Split View or a window.
const EDGE_COLUMN_MAX = 128
const listeners = new Set()
const barListeners = new Set()
let layout = null
let bars = null
let fold = { axis: 'none', start: 0, end: 0 }
let foldOverride = null
let lastVVWidth = vv ? vv.width : window.innerWidth

function measure() {
  const h = vv ? vv.height : window.innerHeight
  const top = vv ? vv.offsetTop : 0
  // The app follows the visual viewport only while the keyboard can be up;
  // otherwise it fills the layout viewport, which on the Duo is taller than
  // the visual one by the home-indicator strip.
  const appH = hasTextFocus() ? h : Math.max(h, window.innerHeight)
  root.style.setProperty('--vvh', `${Math.round(appH)}px`)
  root.style.setProperty('--vvt', `${Math.round(top)}px`)
  // A resize that changes the width is a fold, an unfold or a rotation, never
  // the keyboard (keyboards don't change width): it starts from no keyboard,
  // and the next height-only change decides again.
  const w = vv ? vv.width : window.innerWidth
  const reshaped = Math.abs(w - lastVVWidth) > 1
  lastVVWidth = w
  const kb = !reshaped && window.innerHeight - h > 120 && hasTextFocus()
  if (kb) root.dataset.kb = '1'
  else delete root.dataset.kb
  measureFold()
  // The layout viewport, not the visual one: the keyboard must not move bars.
  const nextBars = window.innerWidth >= window.innerHeight || window.innerHeight < TALL_MIN ? 'vertical' : 'horizontal'
  // The column stays with the hardware: on the outer display in landscape the
  // camera is at its foot rather than its head (see duo-layout.css).
  root.dataset.orientation = window.innerWidth > window.innerHeight ? 'landscape' : 'portrait'
  // Both displays keep a column of their own down the right edge for the
  // status bar and the Dynamic Island (84pt on device, open or closed).
  // Where the page runs under it, it is reported as a wide right safe-area
  // inset (other iPhones' insets stay under 59pt even in landscape) and the
  // bars join it. iOS 27.2 can instead keep the column out of the page: the
  // page is then narrower than the screen by about that much, with no
  // inset, and the bars stand beside it, free of the camera and status bar.
  if (insetRight() >= EDGE_COLUMN_MIN) root.dataset.edgeColumn = ''
  else if (columnBeside()) root.dataset.edgeColumn = 'beside'
  else delete root.dataset.edgeColumn
  if (nextBars !== bars) {
    bars = nextBars
    root.dataset.bars = bars
    for (const fn of barListeners) fn(bars)
  }
  const next = window.innerWidth >= SPLIT_MIN ? 'split' : 'stack'
  if (next !== layout) {
    layout = next
    // Element transitions never replay across a posture change; the morph
    // below (or nothing, with reduced motion) carries the continuity.
    root.classList.add('no-anim')
    if (applied && !posture && document.startViewTransition && !reducedMotion() && document.visibilityState === 'visible') {
      // The browser has already resized; hold the app at its previous width
      // for the outgoing snapshot, so it shows the posture the person just
      // saw rather than that layout squeezed into the new screen.
      root.style.setProperty('--posture-w', `${lastWidth}px`)
      root.dataset.posture = next === 'split' ? 'unfold' : 'fold'
      posture = document.startViewTransition(() => {
        root.style.removeProperty('--posture-w')
        applyLayout()
      })
      posture.ready.catch(() => {})
      posture.finished.catch(() => {}).finally(() => {
        posture = null
        delete root.dataset.posture
        applyLayout()
        settle()
      })
    } else {
      // A second change mid-morph applies at once; the pending update then
      // finds nothing left to do.
      applyLayout()
      if (!posture) settle()
    }
  }
  lastWidth = window.innerWidth
}

let applied = null
let posture = null
let lastWidth = window.innerWidth
function applyLayout() {
  if (layout === applied) return
  const prev = applied
  applied = layout
  for (const fn of listeners) fn(layout, prev)
}
function settle() {
  requestAnimationFrame(() => requestAnimationFrame(() => root.classList.remove('no-anim')))
}

// ---------------------------------------------------------------- fold
// The folding region exists only while the device is partially open. The
// browser exposes it as two viewport segments; a probe resolves their env()
// edges to pixels. emulateFold() stands in for hardware when testing.
let probe = null
const segments = {
  vertical: matchMedia('(horizontal-viewport-segments: 2)'),
  horizontal: matchMedia('(vertical-viewport-segments: 2)')
}
for (const query of Object.values(segments)) query.addEventListener?.('change', () => measure())

function measureFold() {
  let next = { axis: 'none', start: 0, end: 0 }
  if (foldOverride) {
    const length = foldOverride.axis === 'vertical' ? window.innerWidth : window.innerHeight
    const size = foldOverride.size ?? 24
    next = { axis: foldOverride.axis, start: Math.round((length - size) / 2), end: Math.round((length + size) / 2) }
  } else if (segments.vertical.matches || segments.horizontal.matches) {
    const axis = segments.vertical.matches ? 'vertical' : 'horizontal'
    if (!probe) {
      probe = document.createElement('div')
      probe.setAttribute('aria-hidden', 'true')
      probe.style.cssText = 'position:fixed;visibility:hidden;pointer-events:none;top:0;left:0;width:0;height:0'
      document.body.append(probe)
    }
    probe.style.width = axis === 'vertical' ? 'env(viewport-segment-right 0 0, 0px)' : '0'
    probe.style.height = axis === 'horizontal' ? 'env(viewport-segment-bottom 0 0, 0px)' : '0'
    probe.style.left = axis === 'vertical' ? 'env(viewport-segment-left 1 0, 0px)' : '0'
    probe.style.top = axis === 'horizontal' ? 'env(viewport-segment-top 0 1, 0px)' : '0'
    const start = axis === 'vertical' ? probe.offsetWidth : probe.offsetHeight
    const end = axis === 'vertical' ? probe.offsetLeft : probe.offsetTop
    if (end > start) next = { axis, start, end }
  }
  if (next.axis === fold.axis && next.start === fold.start && next.end === fold.end) return
  fold = next
  if (fold.axis === 'none') {
    delete root.dataset.fold
    root.style.removeProperty('--fold-start')
    root.style.removeProperty('--fold-end')
  } else {
    root.dataset.fold = fold.axis
    root.style.setProperty('--fold-start', `${fold.start}px`)
    root.style.setProperty('--fold-end', `${fold.end}px`)
  }
}

/** Pretend the device is partially folded (axis: 'vertical' | 'horizontal'), or clear it. */
export function emulateFold(options = null) {
  foldOverride = options && options.axis !== 'none' ? options : null
  measure()
}

export function getFold() {
  return { ...fold }
}

let insetProbe = null
function insetRight() {
  if (!insetProbe) {
    insetProbe = document.createElement('div')
    insetProbe.setAttribute('aria-hidden', 'true')
    insetProbe.style.cssText = 'position:fixed;visibility:hidden;pointer-events:none;top:0;left:0;height:0;width:var(--safe-right)'
    document.body.append(insetProbe)
    // The insets can settle after launch without any resize (iOS 27.2 hands a
    // Home Screen app its safe area a moment later), so the probe itself is
    // watched: when the right inset changes, everything is measured again.
    new ResizeObserver(() => measure()).observe(insetProbe)
  }
  return insetProbe.offsetWidth
}

// The system column standing outside the page: a touch screen wider than
// the page by a column's width (not a Split View half, not a desktop window).
function columnBeside() {
  if (!matchMedia('(pointer: coarse)').matches) return false
  const w = window.innerWidth
  const across = [screen.width, screen.height].filter(s => s >= w - 1)
  if (!across.length) return false
  const gap = Math.min(...across) - w
  return gap >= EDGE_COLUMN_MIN && gap <= EDGE_COLUMN_MAX
}

function hasTextFocus() {
  const el = document.activeElement
  return Boolean(el && (el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && !['checkbox', 'radio', 'button'].includes(el.type))))
}

export function initViewport() {
  const asked = new URLSearchParams(location.search).get('fold')
  if (asked === 'vertical' || asked === 'horizontal') foldOverride = { axis: asked }
  measure()
  vv?.addEventListener('resize', measure)
  vv?.addEventListener('scroll', measure)
  window.addEventListener('resize', measure)
  window.addEventListener('orientationchange', () => setTimeout(measure, 300))
  // Returning from the background or the app switcher can bring new insets too.
  window.addEventListener('pageshow', () => measure())
  document.addEventListener('visibilitychange', () => { if (!document.hidden) measure() })
  document.addEventListener('focusin', () => setTimeout(measure, 50))
  document.addEventListener('focusout', () => {
    setTimeout(() => {
      measure()
      // iOS can leave the layout viewport scrolled after the keyboard hides.
      if (!hasTextFocus() && window.scrollY) window.scrollTo(0, 0)
    }, 80)
  })
}

export function getLayout() {
  return layout
}

export function onLayout(fn) {
  listeners.add(fn)
  return () => listeners.delete(fn)
}

export function getBars() {
  return bars
}

export function onBars(fn) {
  barListeners.add(fn)
  return () => barListeners.delete(fn)
}

export const isStandalone = () =>
  window.navigator.standalone === true || matchMedia('(display-mode: standalone)').matches
