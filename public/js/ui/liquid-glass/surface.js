// A surface whose buttons the WebGL Liquid Glass draws: the composer row, the
// conversation's heading, the rail. Loads the engine on demand, attaches while
// it should run (and there are buttons to draw), leaves the CSS glass in place
// otherwise, and follows the glass settings (appearance.js → 'cuven:glass').

import { storage } from '../dom.js'

let mod = null
let loading = null
const load = () => (mod ? Promise.resolve(mod) : (loading ||= import('./index.js').then(m => (mod = m)).catch(() => null)))

/** The bar buttons in `host` drawn as glass: each round button, and each
 *  capsule as one piece (its buttons sit inside it). A button filled with ink
 *  to show it's on keeps that fill and isn't glass. */
export function barShapes(host) {
  return [...host.querySelectorAll('.bar-group.capsule, .bar-item')].filter(el =>
    el.matches('.bar-group.capsule') || (!el.closest('.bar-group.capsule') && !el.classList.contains('active')))
}

export function glassSurface(host, shapeEls, { enabled = () => true } = {}) {
  let glass = null
  let gen = 0
  const visible = () => shapeEls().some(el => el && !el.hidden && el.getClientRects().length)
  function teardown() {
    if (glass) { glass.destroy(); glass = null }
  }
  async function sync() {
    const my = ++gen
    if (storage('ui:glass-engine') === 'css' || !enabled() || !visible()) { teardown(); return }
    const m = await load()
    if (!m || my !== gen) return
    if (!(enabled() && visible() && m.liquidGlassActive())) { teardown(); return }
    if (!glass) glass = m.attachLiquidGlass(host, shapeEls)
    else glass.invalidate()
  }
  window.addEventListener('cuven:glass', sync)
  return {
    sync,
    refresh() { glass ? glass.refresh() : sync() },
    destroy() { gen++; teardown(); window.removeEventListener('cuven:glass', sync) }
  }
}
