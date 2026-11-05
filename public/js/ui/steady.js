// Keeps the page from being pulled out of shape. The layout is fitted to one
// screen at one scale; the ways someone can stretch, shift or leave it by
// accident are refused here, so nothing has to be put back afterwards:
//
// * zoom — pinch (Safari's gesture events), Ctrl/⌘ + wheel or trackpad
//   pinch, Ctrl/⌘ with + − 0; and if the page is somehow scaled anyway, the
//   viewport is set again so it goes back to 1. (The viewport meta and
//   touch-action in css/base.css cover double-tap and the browsers that
//   honour them; iOS ignores user-scalable, hence the gesture events.)
// * a file, link or picture dragged onto the page, which would otherwise
//   navigate away from the app, and links and pictures dragged out of it;
// * the page or one of its fixed containers scrolled off its place (focus,
//   find-in-page, scrollIntoView and a keyboard closing can all do it);
// * the system's text size growing past what the layout holds (Dynamic Type
//   scales the whole page; beyond DYNAMIC_TYPE_MAX px the bars and rows
//   no longer fit), read again whenever the app comes back to the screen.
//
// Text fields keep everything they need: selection, text drags, paste.

export const DYNAMIC_TYPE_MAX = 21 // px: iOS's "xxLarge" body size; the default is 17
const SCALE_EPSILON = 1.02
const RESCALE_GAP_MS = 400
const ZOOM_KEYS = new Set(['+', '=', '-', '_', '0'])
const ZOOM_CODES = new Set(['NumpadAdd', 'NumpadSubtract', 'Numpad0', 'Equal', 'Minus', 'Digit0'])
const FIXED = ['app', 'shell', 'pane']

/** A browser zoom shortcut: Ctrl/⌘ with + − or 0. */
export function isZoomKey(e) {
  if (!(e.ctrlKey || e.metaKey) || e.altKey) return false
  return ZOOM_KEYS.has(e.key) || ZOOM_CODES.has(e.code)
}

const editable = el => Boolean(el?.closest?.('input, textarea, select, [contenteditable=""], [contenteditable="true"]'))

/** Whether a drag over/drop at `e` is the page's to refuse: files anywhere, anything else outside a field. */
export function refusesDrop(e) {
  const types = Array.from(e.dataTransfer?.types || [])
  return types.includes('Files') || !editable(e.target)
}

/** A link, picture or the like being dragged out of the page. */
export function refusesDrag(e) {
  const el = e.target
  if (!el?.closest || editable(el)) return false
  return Boolean(el.closest('a, img, svg, canvas, video, [draggable="true"]'))
}

/** The root font size to set so the text never grows past `max`, or '' to leave the system's. */
export function cappedRootSize(natural, max = DYNAMIC_TYPE_MAX) {
  return Number.isFinite(natural) && natural > max ? `${max}px` : ''
}

export function initSteady(win = window, doc = document) {
  const root = doc.documentElement
  const vv = win.visualViewport
  const on = (target, type, fn, options) => target?.addEventListener?.(type, fn, options)
  const stop = e => e.preventDefault()

  // Zoom.
  for (const type of ['gesturestart', 'gesturechange', 'gestureend']) on(doc, type, stop, { passive: false })
  on(win, 'wheel', e => { if (e.ctrlKey || e.metaKey) e.preventDefault() }, { passive: false })
  on(doc, 'keydown', e => { if (isZoomKey(e)) e.preventDefault() }, true)

  // Something scaled the page anyway: set the viewport again so it goes back to 1.
  let rescaled = 0
  function unscale() {
    const meta = doc.querySelector('meta[name="viewport"]')
    const now = Date.now()
    if (!meta || !vv || vv.scale <= SCALE_EPSILON || now - rescaled < RESCALE_GAP_MS) return
    rescaled = now
    const keep = meta.content
    meta.content = 'width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no'
    win.requestAnimationFrame(() => { if (meta.content !== keep) meta.content = keep })
  }
  on(vv, 'resize', unscale)
  on(win, 'pageshow', unscale)

  // Drag and drop.
  on(win, 'dragover', e => { if (refusesDrop(e)) e.preventDefault() })
  on(win, 'drop', e => { if (refusesDrop(e)) e.preventDefault() })
  on(doc, 'dragstart', e => { if (refusesDrag(e)) e.preventDefault() })

  // Scrolled off its place: the page, or a container that is never meant to scroll.
  const typing = () => {
    const el = doc.activeElement
    return Boolean(el && (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT'))
  }
  on(doc, 'scroll', e => {
    const el = e.target
    if (el === doc || el === root || el === doc.body) {
      // With the keyboard up the system scrolls the page on purpose (ui/viewport.js follows it).
      if ((win.scrollX || win.scrollY) && !typing()) win.scrollTo(0, 0)
    } else if (el?.classList && FIXED.some(c => el.classList.contains(c))) {
      if (el.scrollTop) el.scrollTop = 0
      if (el.scrollLeft) el.scrollLeft = 0
    }
  }, true)

  // Dynamic Type, capped.
  function capType() {
    root.style.removeProperty('font-size')
    const size = parseFloat(win.getComputedStyle(root).fontSize)
    const capped = cappedRootSize(size)
    if (capped) root.style.fontSize = capped
  }
  capType()
  on(win, 'pageshow', capType)
  on(doc, 'visibilitychange', () => { if (!doc.hidden) capType() })
}
