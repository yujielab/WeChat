// The app as one strip of columns — sidebar | list | conversation | details —
// with the screen as a window onto it: one column folded, two adjacent
// columns unfolded. Navigating slides the window along the strip on a spring
// (which can inherit a swipe's velocity), and the column at the window's
// leading edge can be swiped back interactively, 1:1 under the finger.
// Folding or unfolding keeps the focused column on screen.

import { reducedMotion } from './dom.js'
import { spring, velocityTracker, project } from './spring.js'
import { cancelPress } from './press.js'
import { isStandalone } from './viewport.js'

export const COLS = ['sidebar', 'list', 'thread', 'artifact']

/**
 * The window's first column. Folded, it's the focused column. Unfolded, the
 * focused column shows with the one before it — except the sidebar and the
 * list, which show with the column after them.
 */
export function windowStart(focus, count) {
  if (count === 1) return focus
  return Math.max(0, Math.min(COLS.length - 2, focus <= 1 ? focus : focus - 1))
}

function roleAt(i, start, count) {
  if (count === 1) return i === start ? 'single' : 'hidden'
  return i === start ? 'leading' : i === start + 1 ? 'trailing' : 'hidden'
}

/**
 * panes: one element per column, in strip order.
 * onRoles(changed): after columns change role (single | leading | trailing | hidden).
 * onSwipeBack({ from, velocity }): the leading column was swiped away.
 * swipeZone(pane): how far from its leading edge a back swipe may start (px), or 0.
 */
export function createStrip(shell, panes, { onRoles, onSwipeBack, swipeZone }) {
  let count = 1
  let focus = 1
  let start = 1
  let pos = 1
  let anim = null

  panes.forEach((pane, i) => { pane.dataset.col = COLS[i] })

  function render(p) {
    pos = p
    const lo = Math.floor(p + 1e-4)
    const hi = Math.ceil(p - 1e-4) + count - 1
    panes.forEach((pane, i) => {
      pane.style.transform = `translate3d(calc(${(i - p).toFixed(4)} * (100% + var(--gap))), 0, 0)`
      pane.classList.toggle('off', i < lo || i > hi)
    })
  }

  function setRole(pane, role) {
    if (pane.dataset.role === role) return false
    pane.dataset.role = role
    pane.inert = role === 'hidden'
    return true
  }

  function applyRoles() {
    const changed = panes.filter((pane, i) => setRole(pane, roleAt(i, start, count)))
    shell.dataset.start = COLS[start]
    shell.dataset.focus = COLS[focus]
    if (changed.length) onRoles?.(changed)
  }

  /** Slide the window so the column at `next` has focus. */
  function go(next, { velocity = 0, instant = false } = {}) {
    anim?.stop()
    anim = null
    focus = Math.max(0, Math.min(COLS.length - 1, next))
    start = windowStart(focus, count)
    applyRoles()
    if (instant || pos === start) {
      delete shell.dataset.anim
      render(start)
      return Promise.resolve(true)
    }
    if (reducedMotion()) {
      render(start)
      for (const pane of panes) if (pane.dataset.role !== 'hidden') pane.animate?.([{ opacity: 0.4 }, { opacity: 1 }], { duration: 160, easing: 'linear' })
      return Promise.resolve(true)
    }
    shell.dataset.anim = ''
    // Moving between list, conversation and details is the app's most
    // frequent navigation: quick, critically damped, no lingering.
    const run = spring({ from: pos, to: start, velocity, damping: 1, response: 0.34, restDelta: 0.0005, onUpdate: render })
    anim = run
    return run.done.then(done => {
      if (anim === run) {
        anim = null
        delete shell.dataset.anim
      }
      return done
    })
  }

  /**
   * The column last used inside the window becomes the focus, without
   * sliding — so folding keeps on screen what was being used.
   */
  function touch(i) {
    if (i === focus || windowStart(i, count) !== start || anim || g?.active) return false
    focus = i
    shell.dataset.focus = COLS[i]
    return true
  }

  /** Folding or unfolding: the same focus in a window of `n` columns, at once. */
  function setCount(n) {
    count = n
    go(focus, { instant: true })
  }

  // ---------------------------------------------------------- interactive back
  let g = null
  const step = () => (panes[start].getBoundingClientRect().width || shell.clientWidth) + gap()
  const gap = () => parseFloat(getComputedStyle(shell).getPropertyValue('--gap')) || 0

  shell.addEventListener('pointerdown', e => {
    if (g || e.button > 0 || start === 0) return
    const pane = panes[start]
    if (!pane.contains(e.target)) return
    if (e.target.closest('textarea, input, .composer, .menu, .draw-stage, [data-no-swipe]')) return
    // In Safari (not installed to the home screen) the screen's left edge belongs to the browser's own back swipe.
    if (!isStandalone() && e.clientX < 24) return
    const x = e.clientX - pane.getBoundingClientRect().left
    const zone = swipeZone ? swipeZone(pane) : pane.clientWidth * 0.6
    if (x > zone) return
    g = { id: e.pointerId, x0: e.clientX, y0: e.clientY, active: false, vt: velocityTracker(), from: start, pane }
    g.vt.add(e.clientX, e.clientY)
    // A swipe from the edge belongs to the strip, not to rows that swipe themselves.
    if (pane.dataset.edgeSwipe !== undefined) e.stopPropagation()
  }, { capture: true })

  shell.addEventListener('pointermove', e => {
    if (!g || e.pointerId !== g.id) return
    const dx = e.clientX - g.x0
    const dy = e.clientY - g.y0
    g.vt.add(e.clientX, e.clientY)
    if (!g.active) {
      if (Math.abs(dy) > 10 && Math.abs(dy) > Math.abs(dx)) {
        g = null
        return
      }
      if (dx < 10 || dx < Math.abs(dy) * 1.2) return
      g.active = true
      g.x0 = e.clientX
      g.step = step()
      anim?.stop()
      anim = null
      cancelPress()
      try { shell.setPointerCapture(e.pointerId) } catch {}
      shell.dataset.anim = ''
      // The column coming into view takes the role it will have once there.
      const incoming = panes[g.from - 1]
      g.preview = setRole(incoming, roleAt(g.from - 1, g.from - 1, count)) ? incoming : null
      if (g.preview) {
        g.preview.inert = true
        onRoles?.([g.preview])
      }
    }
    render(g.from - Math.min(1, Math.max(0, e.clientX - g.x0) / g.step))
  }, { capture: true })

  const end = e => {
    if (!g || e.pointerId !== g.id) return
    const was = g
    g = null
    if (!was.active) return
    const vx = was.vt.velocity().x
    const dx = (was.from - pos) * was.step
    // Decide from where the gesture is heading, not just where it stopped.
    const back = dx + project(vx) > was.step * 0.5 || vx > 900
    const velocity = -vx / was.step
    if (back) onSwipeBack?.({ from: was.from, velocity })
    else {
      if (was.preview) setRole(was.preview, 'hidden')
      go(focus, { velocity })
    }
  }
  shell.addEventListener('pointerup', end, { capture: true })
  shell.addEventListener('pointercancel', end, { capture: true })

  return {
    go,
    touch,
    setCount,
    get focus() { return focus },
    get start() { return start },
    get count() { return count },
    /** Whether the column is in the window (or will be, once the slide settles). */
    shows: i => i >= start && i < start + count,
    get moving() { return Boolean(anim || g?.active) }
  }
}
