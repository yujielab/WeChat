// Stack navigation for the folded / narrow layout: the conversation slides
// over the list (which parallaxes back and dims), and can be swiped back
// interactively from anywhere on the left half with 1:1 tracking, velocity
// projection and a spring hand-off — like UINavigationController.

import { reducedMotion } from './dom.js'
import { spring, velocityTracker, project } from './spring.js'
import { cancelPress } from './press.js'
import { isStandalone } from './viewport.js'

export function createNav(shell, listPane, threadPane, { onSwipeBack }) {
  let p = 0
  let anim = null

  const width = () => shell.clientWidth || window.innerWidth

  function render(v) {
    const W = width()
    threadPane.style.transform = `translate3d(${(1 - v) * W}px, 0, 0)`
    listPane.style.transform = `translate3d(${-0.28 * W * v}px, 0, 0)`
    listPane.style.setProperty('--dim', String(Math.max(0, Math.min(1, v))))
  }

  function settle(open) {
    p = open ? 1 : 0
    shell.dataset.thread = open ? 'open' : 'closed'
    delete shell.dataset.anim
    threadPane.style.transform = ''
    listPane.style.transform = ''
    listPane.style.removeProperty('--dim')
  }

  async function go(open, velocity = 0, { instant = false } = {}) {
    anim?.stop()
    if (shell.dataset.layout !== 'stack' || instant) {
      settle(open)
      return
    }
    if (reducedMotion()) {
      settle(open)
      const pane = open ? threadPane : listPane
      pane.animate?.([{ opacity: 0 }, { opacity: 1 }], { duration: 160, easing: 'linear' })
      return
    }
    shell.dataset.anim = ''
    if (open && p === 0) render(0)
    const run = spring({
      from: p,
      to: open ? 1 : 0,
      velocity,
      damping: 1,
      response: open ? 0.4 : 0.34,
      restDelta: 0.001,
      onUpdate: v => {
        p = v
        render(v)
      }
    })
    anim = run
    const finished = await run.done
    if (finished && anim === run) {
      anim = null
      settle(open)
    }
  }

  // ---------------------------------------------------------- interactive back
  let g = null
  threadPane.addEventListener('pointerdown', e => {
    if (shell.dataset.layout !== 'stack' || shell.dataset.thread !== 'open' || e.button > 0) return
    if (e.target.closest('textarea, input, .composer, .viewer, .menu')) return
    const x = e.clientX - shell.getBoundingClientRect().left
    // In Safari (not installed to the home screen) the left edge belongs to the browser's own back swipe.
    if (!isStandalone() && x < 24) return
    if (x > width() * 0.6) return
    g = { id: e.pointerId, x0: e.clientX, y0: e.clientY, active: false, vt: velocityTracker() }
    g.vt.add(e.clientX, e.clientY)
  })
  threadPane.addEventListener('pointermove', e => {
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
      anim?.stop()
      cancelPress()
      try { threadPane.setPointerCapture(e.pointerId) } catch {}
      shell.dataset.anim = ''
    }
    const v = 1 - Math.max(0, e.clientX - g.x0) / width()
    p = Math.max(0, Math.min(1, v))
    render(p)
  })
  const end = e => {
    if (!g || e.pointerId !== g.id) return
    const was = g
    g = null
    if (!was.active) return
    const vx = was.vt.velocity().x
    const W = width()
    const dx = (1 - p) * W
    // Decide from where the gesture is heading, not just where it stopped.
    const close = dx + project(vx) > W * 0.5 || vx > 900
    const velocity = -vx / W
    if (close) {
      go(false, velocity).then(() => onSwipeBack?.())
    } else {
      go(true, velocity)
    }
  }
  threadPane.addEventListener('pointerup', end)
  threadPane.addEventListener('pointercancel', end)

  return {
    push: opts => go(true, 0, opts),
    pop: opts => go(false, 0, opts),
    settle,
    get open() {
      return shell.dataset.thread === 'open'
    }
  }
}
