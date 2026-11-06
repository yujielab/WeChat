// Morph and separation — the reserved motion hooks for glass controls
// (css/liquid.css draws them). Two things:
//
//   flip(el, mutate)         a FLIP transition: measure, change, play the
//                            change back to its new place on a spring, so a
//                            button that moves or changes shape eases there
//                            instead of jumping (形变).
//   merge / split a group    adjacent controls in an .lg-group flow into one
//                            blob and part again (分离); the CSS animates the
//                            gap and the inner corners, this toggles the flag.
//
// Nothing here runs on its own; a view opts a control in. Reduced motion
// applies the end state at once.

import { reducedMotion } from './dom.js'

/**
 * Animate an element from where it is to where `mutate()` leaves it, on a
 * spring. Position and size are both carried (First-Last-Invert-Play); for a
 * shape that holds its content, prefer a position-only change. Reduced motion
 * just runs the mutation.
 */
export function flip(el, mutate, { spring = 'var(--spring-bouncy)', dur = 'var(--spring-bouncy-dur)' } = {}) {
  if (reducedMotion()) return void mutate()
  const first = el.getBoundingClientRect()
  mutate()
  const last = el.getBoundingClientRect()
  const dx = first.left - last.left
  const dy = first.top - last.top
  const sx = last.width ? first.width / last.width : 1
  const sy = last.height ? first.height / last.height : 1
  if (Math.abs(dx) < 0.5 && Math.abs(dy) < 0.5 && Math.abs(sx - 1) < 0.01 && Math.abs(sy - 1) < 0.01) return
  el.style.transition = 'none'
  el.style.transformOrigin = 'top left'
  el.style.transform = `translate(${dx}px, ${dy}px) scale(${sx}, ${sy})`
  requestAnimationFrame(() => {
    el.style.transition = `transform ${dur} ${spring}`
    el.style.transform = ''
    const clear = () => {
      el.style.transition = ''
      el.style.transformOrigin = ''
      el.style.transform = ''
      el.removeEventListener('transitionend', clear)
    }
    el.addEventListener('transitionend', clear)
    // A transform that resolves to no change fires no transitionend.
    setTimeout(clear, 700)
  })
}

/** Flow the items of an .lg-group edge-to-edge into one blob. */
export function mergeGroup(group) {
  if (group) group.dataset.merged = ''
}
/** Part them back to separate controls. */
export function splitGroup(group) {
  if (group) delete group.dataset.merged
}
/** merged = true merges, false splits. */
export function setMerged(group, merged) {
  return merged ? mergeGroup(group) : splitGroup(group)
}

/**
 * An .lg-group that rests merged and parts while it is in use: it splits on
 * pointer-enter / focus-within / touch, and settles back together a moment
 * after attention leaves. Returns a function that stops watching it.
 */
export function wireIdleMerge(group, { delay = 900 } = {}) {
  if (!group) return () => {}
  let timer = 0
  const split = () => {
    clearTimeout(timer)
    splitGroup(group)
  }
  const restMerged = () => {
    clearTimeout(timer)
    timer = setTimeout(() => {
      if (!group.matches(':hover, :focus-within')) mergeGroup(group)
    }, delay)
  }
  mergeGroup(group)
  const on = (type, fn) => (group.addEventListener(type, fn), () => group.removeEventListener(type, fn))
  const offs = [
    on('pointerenter', split),
    on('pointerdown', split),
    on('focusin', split),
    on('pointerleave', restMerged),
    on('focusout', restMerged)
  ]
  return () => {
    clearTimeout(timer)
    for (const off of offs) off()
  }
}
