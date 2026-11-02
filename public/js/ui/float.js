// A tile that floats over something and can be thrown into a corner — the
// call's picture in picture over the app, the self view over the call. It
// follows the finger 1:1, resists past its room, and when let go travels on
// a spring that keeps the throw's speed to the corner it was heading for
// (ui/corners.js) — or, if it may be stashed, tucks against the side it was
// flung past with a strip still showing. Caught mid-flight it stops under
// the finger. A tap and a long press (or the context menu) are the owner's.

import { spring, velocityTracker, rubberband } from './spring.js'
import { cancelPress } from './press.js'
import { cornerPoint, stashPoint, restingPlace } from './corners.js'

const SLOP = 8
const HOLD_MS = 460

/**
 * el: what is pressed and dragged.
 * frame() → { left, top, right, bottom }: the room its whole box rests in.
 * size() → { w, h }
 * edge() → { left, right }: the sides a stashed tile hangs off (stash only).
 * apply(x, y): draw its top-left there.
 * place: where it rests to begin with: { corner } or { stashed: 'left' | 'right', y }.
 * onTap(e) / onHold(e): a press that didn't move, or one held (or the context menu).
 * onGrab(e): return false to refuse a press.
 * onRest(place): it was let go (or moved) towards a resting place.
 * onDrag(): it started to follow a finger.
 */
export function floatTile(el, { frame, size, edge = null, apply, place = { corner: 'tr' }, stash = false, strip = 28, onTap, onHold, onGrab, onRest, onDrag }) {
  let at = { ...place }
  let pos = { x: 0, y: 0 }
  let runs = []
  let g = null

  function target() {
    const f = frame()
    const s = size()
    return at.stashed ? stashPoint(f, s, edge(), at.stashed, at.y ?? pos.y, strip) : cornerPoint(f, s, at.corner || 'tr')
  }
  function draw(x, y) {
    pos = { x, y }
    apply(x, y)
  }
  function stop() {
    for (const r of runs) r.stop()
    runs = []
  }

  /** Go to the resting place: on a spring that keeps `velocity` (px/s), or at once. */
  function settle({ velocity = { x: 0, y: 0 }, animate = true } = {}) {
    stop()
    const to = target()
    if (!animate) {
      draw(to.x, to.y)
      return Promise.resolve(true)
    }
    let x = pos.x
    let y = pos.y
    // It lands with the barest give, as a picture in picture does.
    const feel = { damping: 0.84, response: 0.38 }
    const rx = spring({ from: x, to: to.x, velocity: velocity.x, ...feel, onUpdate: v => { x = v; draw(x, y) } })
    const ry = spring({ from: y, to: to.y, velocity: velocity.y, ...feel, onUpdate: v => { y = v; draw(x, y) } })
    runs = [rx, ry]
    return Promise.all([rx.done, ry.done]).then(([a, b]) => a && b)
  }

  function moveTo(next, opts) {
    at = { ...next }
    onRest?.({ ...at })
    return settle(opts)
  }

  function down(e) {
    if (e.button > 0 || g || onGrab?.(e) === false) return
    stop()
    g = { id: e.pointerId, x0: e.clientX, y0: e.clientY, from: { ...pos }, moved: false, held: false, vt: velocityTracker() }
    g.vt.add(e.clientX, e.clientY)
    try { el.setPointerCapture(e.pointerId) } catch {}
    if (onHold) {
      g.timer = setTimeout(() => {
        if (!g || g.moved) return
        g.held = true
        onHold(e)
      }, HOLD_MS)
    }
  }

  function move(e) {
    if (!g || e.pointerId !== g.id) return
    g.vt.add(e.clientX, e.clientY)
    if (!g.moved) {
      if (g.held || Math.hypot(e.clientX - g.x0, e.clientY - g.y0) < SLOP) return
      g.moved = true
      clearTimeout(g.timer)
      cancelPress()
      // From here on 1:1, without a jump by the slop.
      g.x0 = e.clientX
      g.y0 = e.clientY
      onDrag?.()
    }
    const f = frame()
    const s = size()
    const sides = stash ? edge() : null
    const minX = stash ? sides.left - s.w + strip : f.left
    const maxX = stash ? sides.right - strip : f.right - s.w
    const minY = f.top
    const maxY = Math.max(f.top, f.bottom - s.h)
    let x = g.from.x + e.clientX - g.x0
    let y = g.from.y + e.clientY - g.y0
    if (x < minX) x = minX + rubberband(x - minX, s.w)
    else if (x > maxX) x = maxX + rubberband(x - maxX, s.w)
    if (y < minY) y = minY + rubberband(y - minY, s.h)
    else if (y > maxY) y = maxY + rubberband(y - maxY, s.h)
    draw(x, y)
  }

  function up(e, cancelled = false) {
    if (!g || (e && e.pointerId !== g.id)) return
    const was = g
    g = null
    clearTimeout(was.timer)
    try { el.releasePointerCapture(was.id) } catch {}
    if (was.held) return
    if (!was.moved) {
      if (!cancelled) onTap?.(e)
      return
    }
    // Where the throw is heading decides where it lands; one the system took
    // over lands where it was.
    const v = cancelled ? { x: 0, y: 0 } : was.vt.velocity()
    moveTo(restingPlace(frame(), size(), pos, v, { stash, edge: stash ? edge() : undefined }), { velocity: v })
  }

  const onUp = e => up(e)
  const onCancel = e => up(e, true)
  const onLost = e => { if (g && e.pointerId === g.id) up(e, true) }
  // A right click, Android's long press or the menu key: the same as holding.
  const onMenu = e => {
    e.preventDefault()
    if (!onHold || g?.held || g?.moved) return
    if (g) {
      clearTimeout(g.timer)
      g.held = true
    }
    onHold(e)
  }
  el.addEventListener('pointerdown', down)
  el.addEventListener('pointermove', move)
  el.addEventListener('pointerup', onUp)
  el.addEventListener('pointercancel', onCancel)
  el.addEventListener('lostpointercapture', onLost)
  el.addEventListener('contextmenu', onMenu)

  return {
    get place() { return { ...at } },
    get position() { return { ...pos } },
    get dragging() { return Boolean(g?.moved) },
    /** Where it rests now, in the room as it is now. */
    target,
    settle,
    moveTo,
    stop,
    destroy() {
      stop()
      if (g) clearTimeout(g.timer)
      g = null
      el.removeEventListener('pointerdown', down)
      el.removeEventListener('pointermove', move)
      el.removeEventListener('pointerup', onUp)
      el.removeEventListener('pointercancel', onCancel)
      el.removeEventListener('lostpointercapture', onLost)
      el.removeEventListener('contextmenu', onMenu)
    }
  }
}
