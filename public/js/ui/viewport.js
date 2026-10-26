// Viewport tracking for iPhone Duo.
//
// * Pins the app to the visual viewport (--vvh / --vvt) so the keyboard
//   shrinks the app instead of scrolling the page, and flags data-kb="1"
//   while the keyboard is up.
// * Decides the layout: "split" (list + conversation) or "stack" (one pane).
//   The threshold comes from what each column needs, not from a device
//   width: a scannable list and a conversation at least as wide as the outer
//   screen. In Safari that splits the inner display both ways (669 / 951
//   wide) and stacks the outer screen (382 / 594) and Split View windows
//   (385). Folding changes the width without a rotation, so this listens to
//   size, not orientation.

const root = document.documentElement
const vv = window.visualViewport
const LIST_MIN = 280
const THREAD_MIN = 380
const SPLIT_MIN = LIST_MIN + THREAD_MIN
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
    const prev = layout
    layout = next
    // Snap, don't animate, when the device folds/unfolds or rotates.
    root.classList.add('no-anim')
    requestAnimationFrame(() => requestAnimationFrame(() => root.classList.remove('no-anim')))
    for (const fn of listeners) fn(next, prev)
  }
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
