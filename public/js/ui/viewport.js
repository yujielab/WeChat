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
// * Reports the folding region when the device is partially open, from the
//   browser's viewport segments (data-fold, --fold-start / --fold-end), or,
//   where the browser only says the device is folded (the Device Posture
//   API), the middle of the screen.
// * Names the posture (data-pose): "closed" — the outer display (or any
//   phone); "half" — partly open, a hinge to respect (a book, or a laptop on
//   its side); "open" — the inner display flat, two columns side by side or,
//   turned upright, one. The columns
//   (js/ui/strip.js), the overlays and their motion follow it.
// * Decides where the controls go: where the system keeps a column of its own
//   down the right edge (the Duo's status bar and Dynamic Island) they stand
//   in it as a rail ("vertical", data-bars); everywhere else they are the bar
//   at each column's foot ("horizontal").

import { reducedMotion } from './dom.js'
import { poseOf, INNER_MIN } from './posture.js'

const root = document.documentElement
const vv = window.visualViewport
const SPLIT_MIN = 700
// A right inset this wide is the system's column, which the rail can share
// (the rail is 52pt; other iPhones' insets stay under 59pt even in landscape).
const EDGE_COLUMN_MIN = 64
const listeners = new Set()
const barListeners = new Set()
const poseListeners = new Set()
let pose = null
let layout = null
let bars = null
let fold = { axis: 'none', start: 0, end: 0, source: 'none' }
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
  measureColumn()
  measureBars()
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
      // A morph never runs on: while it does the page takes no touches.
      const t = posture
      const late = setTimeout(() => t.skipTransition?.(), 1500)
      posture.finished.catch(() => {}).finally(() => {
        clearTimeout(late)
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
  measurePose()
}

// ---------------------------------------------------------------- pose
let shiftTimer = 0
function measurePose() {
  // The inner display is open whether it shows two columns (landscape) or
  // one (turned upright); only a screen narrower both ways is the closed one.
  const next = poseOf(fold, { split: layout === 'split', width: window.innerWidth, height: window.innerHeight })
  const key = `${next}:${fold.axis}:${fold.start}:${fold.end}`
  if (key === pose?.key) return
  const prev = pose?.pose
  pose = { pose: next, fold: { ...fold }, key }
  root.dataset.pose = next
  if (prev && prev !== 'closed' && next !== 'closed' && prev !== next) markShift(next)
  for (const fn of poseListeners) fn({ pose: next, fold: { ...fold } }, prev)
}
// Between half and open the screen stays the same size and only the hinge
// changes: overlays glide to their new places with the columns
// (data-pose-shift, for the length of the glide). It is set before the hinge
// is written, since measuring anything between the two would let the new
// places land without their transitions.
function markShift(next) {
  root.dataset.poseShift = next
  clearTimeout(shiftTimer)
  shiftTimer = setTimeout(() => delete root.dataset.poseShift, 760)
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
// browser reports it as viewport segments — through window.viewport.segments,
// or the segment media queries with their env() edges, which a probe resolves
// to pixels — or only says the device is folded (the Device Posture API).
// What they mean is decided in js/ui/posture.js. emulateFold(),
// emulatePosture() and emulateSegments() stand in for hardware when testing.
let probe = null
const segments = {
  vertical: matchMedia('(horizontal-viewport-segments: 2)'),
  horizontal: matchMedia('(vertical-viewport-segments: 2)')
}
// Recognised at all: a browser with the API matches one of these.
const segmentsKnown = [matchMedia('(horizontal-viewport-segments: 1)'), matchMedia('(vertical-viewport-segments: 1)')]
for (const query of [...Object.values(segments), ...segmentsKnown]) query.addEventListener?.('change', () => measure())
const postureQueries = { folded: matchMedia('(device-posture: folded)'), continuous: matchMedia('(device-posture: continuous)') }
for (const query of Object.values(postureQueries)) query.addEventListener?.('change', () => measure())
navigator.devicePosture?.addEventListener?.('change', () => measure())
let postureOverride = null
let segmentsOverride
const fullScreen = () => [{ x: 0, y: 0, width: window.innerWidth, height: window.innerHeight }]

/** The viewport's segments as rectangles (one when there is no hinge), or null where the browser has no such API. */
function readSegments() {
  if (segmentsOverride !== undefined) return segmentsOverride
  const api = window.viewport && 'segments' in window.viewport ? window.viewport.segments : undefined
  if (api !== undefined) return api && api.length ? Array.from(api, r => ({ x: r.x, y: r.y, width: r.width, height: r.height })) : fullScreen()
  const axis = segments.vertical.matches ? 'vertical' : segments.horizontal.matches ? 'horizontal' : null
  if (!axis) return segmentsKnown.some(q => q.matches) ? fullScreen() : null
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
  const W = window.innerWidth, H = window.innerHeight
  return axis === 'vertical'
    ? [{ x: 0, y: 0, width: start, height: H }, { x: end, y: 0, width: W - end, height: H }]
    : [{ x: 0, y: 0, width: W, height: start }, { x: 0, y: end, width: W, height: H - end }]
}

/** 'folded' | 'continuous' as the device says, or null where it says nothing. */
function readPosture() {
  if (postureOverride) return postureOverride
  const type = navigator.devicePosture?.type
  if (type === 'folded' || type === 'continuous') return type
  return postureQueries.folded.matches ? 'folded' : postureQueries.continuous.matches ? 'continuous' : null
}

// Not every browser says when the posture changes (no event for the segments
// or the posture, and the viewport keeps its size): without a look of its
// own the page would stay in whichever posture it opened in. So while it is
// shown it looks five times a second at what is cheap to read, and measures
// again when that changed.
function postureSignature() {
  const api = window.viewport && 'segments' in window.viewport ? window.viewport.segments : undefined
  const rects = api ? Array.from(api, r => `${Math.round(r.x)},${Math.round(r.y)},${Math.round(r.width)},${Math.round(r.height)}`).join(';') : String(api)
  return [rects, segments.vertical.matches, segments.horizontal.matches, navigator.devicePosture?.type, postureQueries.folded.matches, window.innerWidth, window.innerHeight].join('|')
}
let lastSignature = ''
function watchPosture() {
  setInterval(() => {
    if (document.hidden) return
    const now = postureSignature()
    if (now === lastSignature) return
    lastSignature = now
    measure()
  }, 200)
}

// The system's status column at the screen's edge. In the page, it is a
// safe area (CSS sees it). Beside the page (iOS 27.2 narrows the page
// instead), the page is a column's width narrower than the screen on a
// touch screen — not half of it (split view), not a desktop window — and
// data-column="beside" says so; backdrops fade out into it (backdrops.css).
function measureColumn() {
  if (root.dataset.wide === 'outer') {
    delete root.dataset.column
    root.style.removeProperty('--column-beside')
    return
  }
  const landscape = matchMedia('(orientation: landscape)').matches
  const screenWidth = landscape ? Math.max(screen.width, screen.height) : Math.min(screen.width, screen.height)
  const extra = screenWidth - window.innerWidth
  const beside = matchMedia('(pointer: coarse)').matches && extra >= 48 && extra <= 140
  if (beside) {
    root.dataset.column = 'beside'
    // How far the screen's middle is from the page's: sheets centre on the screen (overlays.css).
    root.style.setProperty('--column-beside', `${Math.round(extra)}px`)
  } else {
    delete root.dataset.column
    root.style.removeProperty('--column-beside')
  }
}

// Both displays keep a column of their own down the right edge for the
// status bar and the Dynamic Island (84pt on device, open or closed). Where
// the page runs under it — the early wide viewport, or the safe area iOS
// reports — it is a wide right inset and the rail joins it
// (data-edge-column). Where the system keeps it outside the page
// (data-column="beside") the rail stands beside it. Without either there is
// no column, and the bars stay at each column's foot.
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

function measureBars() {
  // The column stays with the hardware: on the outer display in landscape the
  // camera is at its foot rather than its head (see duo-layout.css).
  root.dataset.orientation = window.innerWidth > window.innerHeight ? 'landscape' : 'portrait'
  const inPage = insetRight() >= EDGE_COLUMN_MIN
  const beside = !inPage && root.dataset.column === 'beside'
  if (inPage) root.dataset.edgeColumn = ''
  else if (beside) root.dataset.edgeColumn = 'beside'
  else delete root.dataset.edgeColumn
  const next = inPage || beside ? 'vertical' : 'horizontal'
  if (next !== bars) {
    bars = next
    root.dataset.bars = bars
    for (const fn of barListeners) fn(bars)
  }
}

function measureFold() {
  // The half-open (hinge) posture has been removed: the app is either the outer
  // display (closed) or the inner display (open), never half. The folding
  // region is always reported as none, so no hinge divider or tabletop layout
  // appears and poseOf never returns 'half'. (readSegments / readPosture stay
  // for the settings' screen-posture readout; they no longer drive layout.)
  const next = { axis: 'none', start: 0, end: 0, source: 'none' }
  fold.source = next.source
  if (next.axis === fold.axis && next.start === fold.start && next.end === fold.end) return
  fold = next
  delete root.dataset.fold
  root.style.removeProperty('--fold-start')
  root.style.removeProperty('--fold-end')
}


/** Pretend the device is partially folded (axis: 'vertical' | 'horizontal'), or clear it. */
export function emulateFold(options = null) {
  foldOverride = options && options.axis !== 'none' ? options : null
  measure()
}

/**
 * Pretend the device reports only a posture ('folded' | 'continuous'), as the
 * Device Posture API would, with no segments to go by; or clear it.
 */
export function emulatePosture(type = null) {
  postureOverride = type === 'folded' || type === 'continuous' ? type : null
  segmentsOverride = postureOverride ? null : undefined
  measure()
}

/** Pretend the browser reports these segments (rectangles; 'none' for no such API), or clear it. */
export function emulateSegments(rects) {
  segmentsOverride = rects === undefined || rects === null ? undefined : rects === 'none' ? null : rects
  measure()
}

/** What the browser reports and what was made of it, for the settings' Screen posture. */
export function getPostureReadings() {
  return { segments: readSegments(), posture: readPosture(), source: fold.source, pose: pose?.pose || 'closed', fold: { ...fold } }
}

export function getFold() {
  return { ...fold }
}

/** closed | half | open, and the hinge. */
export function getPose() {
  return pose ? { pose: pose.pose, fold: { ...pose.fold } } : { pose: 'closed', fold: { ...fold } }
}

export function onPose(fn) {
  poseListeners.add(fn)
  return () => poseListeners.delete(fn)
}

function hasTextFocus() {
  const el = document.activeElement
  return Boolean(el && (el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && !['checkbox', 'radio', 'button'].includes(el.type))))
}

/** End any view transition at once (the app leaving the screen mid-way). */
export function skipTransitions() {
  posture?.skipTransition?.()
}

export function initViewport() {
  const params = new URLSearchParams(location.search)
  const asked = params.get('fold')
  if (asked === 'vertical' || asked === 'horizontal') foldOverride = { axis: asked }
  if (params.get('posture') === 'folded') {
    postureOverride = 'folded'
    segmentsOverride = null
  }
  measure()
  lastSignature = postureSignature()
  watchPosture()
  vv?.addEventListener('resize', measure)
  vv?.addEventListener('scroll', measure)
  window.addEventListener('resize', measure)
  window.addEventListener('orientationchange', () => setTimeout(measure, 300))
  // Returning from the background or the app switcher can bring new insets too.
  window.addEventListener('pageshow', () => measure())
  document.addEventListener('visibilitychange', () => {
    if (document.hidden) skipTransitions()
    else measure()
  })
  document.addEventListener('focusin', () => setTimeout(measure, 50))
  document.addEventListener('focusout', () => {
    setTimeout(() => {
      measure()
      // iOS can leave the layout viewport scrolled after the keyboard hides.
      if (!hasTextFocus() && window.scrollY) window.scrollTo(0, 0)
    }, 80)
  })
}

/** 'vertical' where the system's column is on the right edge (a rail stands in it), else 'horizontal'. */
export function getBars() {
  return bars
}

export function onBars(fn) {
  barListeners.add(fn)
  return () => barListeners.delete(fn)
}

export function getLayout() {
  return layout
}

export function onLayout(fn) {
  listeners.add(fn)
  return () => listeners.delete(fn)
}

export const isStandalone = () =>
  window.navigator.standalone === true || matchMedia('(display-mode: standalone)').matches
