// The real Liquid Glass — the liquid-glass-studio shader (MIT) on every button
// in the app. buttons.js finds the buttons and keeps them drawn; engine.js is
// the one shared WebGL2 context; paint.js paints what is behind each button;
// tone.js picks clear, dim or tinted glass.

import { storage } from '../dom.js'
import { glassEngine } from './engine.js'

export { initLiquidGlass, glassButtons, glassStats, BUTTONS } from './buttons.js'

const root = document.documentElement

/** Whether this device can draw the real-time glass (WebGL2). */
export function liquidGlassSupported() {
  return Boolean(glassEngine())
}

/** Whether the real-time glass is on now: supported, not turned off, and not
 *  set aside for Reduce Transparency, high contrast or the solid fallback. */
export function liquidGlassActive() {
  if (!liquidGlassSupported()) return false
  if (storage('ui:glass-engine') === 'css') return false
  if (root.getAttribute('data-glass') === 'solid' || storage('ui:glass-auto') === 'solid') return false
  try {
    if (matchMedia('(prefers-reduced-transparency: reduce)').matches) return false
    if (matchMedia('(prefers-contrast: more)').matches) return false
  } catch {}
  return true
}
