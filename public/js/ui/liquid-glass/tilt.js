// Device tilt for the Liquid Glass edge light (index.js). As the phone tilts,
// the glare slides a little way round each glass rim, the way light moves
// over real glass: at most 16°, eased on a soft spring, and drifting home when
// the phone is held still. Nothing moves with Reduce Motion, while the page is
// hidden, or where no orientation sensor answers (most desktops). iOS asks
// once for Motion & Orientation access, on the first tap on a glass button
// once you're signed in (never over the sign-in form); a refusal is
// remembered and never asked again.

import { reducedMotion, storage } from '../dom.js'
import { screenAxes, createTiltFilter } from './tilt-math.js'

const STIFF = 50 // spring, critically damped: settles in about half a second
const DAMP = 2 * Math.sqrt(STIFF)
const EPS = 0.0015 // rad (~0.09°): smaller changes aren't redrawn

const subs = new Set()
const filter = createTiltFilter()
let listening = false
let asking = false
let watching = false
let target = 0
let value = 0
let velocity = 0
let shown = 0
let lastEvent = 0
let lastFrame = 0
let raf = 0

const supported = () => 'DeviceOrientationEvent' in window
const needsPermission = () => supported() && typeof DeviceOrientationEvent.requestPermission === 'function'
const screenAngle = () => screen.orientation?.angle ?? window.orientation ?? 0

function onOrient(e) {
  if (e.beta == null || e.gamma == null) return
  const now = performance.now()
  const dt = lastEvent ? (now - lastEvent) / 1000 : Infinity
  lastEvent = now
  const [x, y] = screenAxes(e.beta, e.gamma, screenAngle())
  const next = filter(x, y, dt)
  // nearly home is home: the light stops there instead of creeping for ever
  target = reducedMotion() || Math.abs(next) < EPS / 2 ? 0 : next
  kick()
}

function kick() {
  if (raf) return
  lastFrame = performance.now()
  raf = requestAnimationFrame(frame)
}
function frame(t) {
  raf = 0
  const dt = Math.min(0.05, Math.max(0, (t - lastFrame) / 1000))
  lastFrame = t
  velocity += (STIFF * (target - value) - DAMP * velocity) * dt
  value += velocity * dt
  const settled = Math.abs(target - value) < 1e-4 && Math.abs(velocity) < 1e-3
  if (settled) { value = target; velocity = 0 }
  // a visible change, or the final step home
  if (Math.abs(value - shown) >= EPS || (settled && value === 0 && shown !== 0)) {
    shown = value
    for (const fn of subs) fn(shown)
  }
  if (!settled) raf = requestAnimationFrame(frame)
}

function listen() {
  if (listening || !supported() || document.visibilityState === 'hidden') return
  window.addEventListener('deviceorientation', onOrient)
  listening = true
  lastEvent = 0
}
function unlisten() {
  if (!listening) return
  window.removeEventListener('deviceorientation', onOrient)
  listening = false
  target = 0 // the light goes home
  kick()
}

// iOS: access is granted from a tap. If the decision is already made this
// resolves without asking; a refusal is kept so it is never asked again.
function askOnGesture() {
  if (asking || storage('ui:tilt') === 'denied') return
  asking = true
  const ask = e => {
    // a tap on a glass button, in the app
    if (!e.target?.closest?.('[data-lg]') || !document.querySelector('.shell')) return
    window.removeEventListener('click', ask, true)
    window.removeEventListener('touchend', ask, true)
    DeviceOrientationEvent.requestPermission().then(state => {
      storage('ui:tilt', state === 'granted' ? 'granted' : 'denied')
      if (state === 'granted' && subs.size) { unlisten(); listen() }
    }, () => {
      // not counted as a tap after all: ask on the next one
      asking = false
      if (subs.size) askOnGesture()
    })
  }
  window.addEventListener('click', ask, true)
  window.addEventListener('touchend', ask, true)
}

function onVisibility() {
  if (!subs.size) return
  if (document.visibilityState === 'hidden') unlisten()
  else listen()
}

/** Follow the tilt: `fn(rad)` with the light's offset round the rim, on every
 *  eased change. Returns the unsubscribe. */
export function subscribeTilt(fn) {
  subs.add(fn)
  if (subs.size === 1 && supported()) {
    if (!watching) { document.addEventListener('visibilitychange', onVisibility); watching = true }
    if (needsPermission()) askOnGesture()
    listen()
  }
  if (shown) fn(shown)
  return () => {
    subs.delete(fn)
    if (!subs.size) unlisten()
  }
}
