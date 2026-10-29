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

import { reducedMotion } from './dom.js'

const root = document.documentElement
const vv = window.visualViewport
const SPLIT_MIN = 700
const listeners = new Set()
let layout = null

function measure() {
  const h = vv ? vv.height : window.innerHeight
  const top = vv ? vv.offsetTop : 0
  root.style.setProperty('--vvh', `${Math.round(h)}px`)
  root.style.setProperty('--vvt', `${Math.round(top)}px`)
  const kb = window.innerHeight - h > 120 && hasTextFocus()
  if (kb) root.dataset.kb = '1'
  else delete root.dataset.kb
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

function hasTextFocus() {
  const el = document.activeElement
  return Boolean(el && (el.tagName === 'TEXTAREA' || (el.tagName === 'INPUT' && !['checkbox', 'radio', 'button'].includes(el.type))))
}

export function initViewport() {
  measure()
  vv?.addEventListener('resize', measure)
  vv?.addEventListener('scroll', measure)
  window.addEventListener('resize', measure)
  window.addEventListener('orientationchange', () => setTimeout(measure, 300))
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

export const isStandalone = () =>
  window.navigator.standalone === true || matchMedia('(display-mode: standalone)').matches
