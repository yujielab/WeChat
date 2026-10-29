// Symbol effects after the SF Symbols animation presets, played on symbols
// drawn by icon() (ui/dom.js) with Web Animations:
//
// * discrete, played once: bounce, bounce-down, appear, disappear, draw-on,
//   draw-off
// * indefinite, running until stopped: pulse, variable-color, and bounce
//   with { repeat: true } — whoever starts one stops it
// * content transitions: replaceSymbol() swaps one symbol for another
//   (Replace, down-up), or a symbol and its slash (Magic Replace)
//
// Effects run by layer (each layer a beat after the one before) unless they
// move the whole symbol. Under Reduce Motion they all stand down: the symbol
// just shows its new state.

import { drawSymbol, reducedMotion } from './dom.js'

const running = new WeakMap()
const replacing = new WeakMap()

const layersOf = svg => [...svg.querySelectorAll('.sym-layers > *')]
const isStroke = el => el.classList.contains('s')
const STILL = { stop() {}, done: Promise.resolve() }

// The bounce squashes, springs past its rest and settles: up lifts the
// symbol; down presses it into the surface.
const BOUNCE_UP = [
  { transform: 'none', easing: 'cubic-bezier(0.3, 0, 0.3, 1)' },
  { transform: 'scale(0.86)', offset: 0.18, easing: 'cubic-bezier(0.2, 0, 0.3, 1)' },
  { transform: 'translateY(-1.6px) scale(1.07)', offset: 0.48, easing: 'cubic-bezier(0.4, 0, 0.5, 1)' },
  { transform: 'translateY(0.3px) scale(0.98)', offset: 0.76, easing: 'ease-out' },
  { transform: 'none' }
]
const BOUNCE_DOWN = [
  { transform: 'none', easing: 'cubic-bezier(0.3, 0, 0.3, 1)' },
  { transform: 'translateY(1.4px) scale(0.88)', offset: 0.3, easing: 'cubic-bezier(0.2, 0, 0.3, 1)' },
  { transform: 'translateY(-0.4px) scale(1.04)', offset: 0.64, easing: 'ease-out' },
  { transform: 'none' }
]

const EFFECTS = {
  bounce: svg => byLayer(svg, 40, () => [BOUNCE_UP, { duration: 520 }]),
  'bounce-down': svg => byLayer(svg, 40, () => [BOUNCE_DOWN, { duration: 460 }]),
  appear: svg => byLayer(svg, 35, () => [[
    { opacity: 0, transform: 'scale(0.4)', easing: 'cubic-bezier(0.2, 0, 0.2, 1)' },
    { opacity: 1, transform: 'scale(1.06)', offset: 0.7 },
    { opacity: 1, transform: 'none' }
  ], { duration: 340, fill: 'backwards' }]),
  disappear: svg => whole(svg, [
    { opacity: 1, transform: 'none' },
    { opacity: 0, transform: 'scale(0.4)' }
  ], { duration: 200, easing: 'cubic-bezier(0.4, 0, 1, 1)', fill: 'forwards' }),
  // Draw On traces each stroke from its start, a layer at a time; fills grow
  // in on their turn. Draw Off erases the same way.
  'draw-on': svg => byLayer(svg, 90, el => isStroke(el)
    ? [[
        { strokeDasharray: '1 1', strokeDashoffset: 1, opacity: 0 },
        { strokeDasharray: '1 1', strokeDashoffset: 0.99, opacity: 1, offset: 0.01 },
        { strokeDasharray: '1 1', strokeDashoffset: 0, opacity: 1 }
      ], { duration: 440, easing: 'cubic-bezier(0.4, 0, 0.2, 1)', fill: 'backwards' }]
    : [[
        { opacity: 0, transform: 'scale(0.5)', easing: 'cubic-bezier(0.2, 0, 0.2, 1)' },
        { opacity: 1, transform: 'scale(1.06)', offset: 0.7 },
        { opacity: 1, transform: 'none' }
      ], { duration: 300, fill: 'backwards' }]),
  'draw-off': svg => byLayer(svg, 60, el => isStroke(el)
    ? [[
        { strokeDasharray: '1 1', strokeDashoffset: 0, opacity: 1 },
        { strokeDasharray: '1 1', strokeDashoffset: -0.99, opacity: 1, offset: 0.99 },
        { strokeDasharray: '1 1', strokeDashoffset: -1, opacity: 0 }
      ], { duration: 320, easing: 'cubic-bezier(0.4, 0, 0.6, 1)', fill: 'forwards' }]
    : [[{ opacity: 1, transform: 'none' }, { opacity: 0, transform: 'scale(0.5)' }], { duration: 220, easing: 'ease-in', fill: 'forwards' }]),
  pulse: svg => whole(svg, [{ opacity: 1 }, { opacity: 0.32 }, { opacity: 1 }], { duration: 1300, easing: 'ease-in-out', iterations: Infinity }),
  // Cumulative: the variable layers light one after another, hold, and dim
  // together. Symbols without them pulse instead.
  'variable-color': svg => {
    const layers = layersOf(svg).filter(el => /\bv\d\b/.test(el.getAttribute('class')))
    if (!layers.length) return EFFECTS.pulse(svg)
    const step = 200
    const hold = 420
    const total = layers.length * step + hold + 240
    return layers.map((el, k) => el.animate([
      { opacity: 0.28 },
      { opacity: 0.28, offset: (k * step) / total },
      { opacity: 1, offset: (k * step + 140) / total },
      { opacity: 1, offset: (layers.length * step + hold) / total },
      { opacity: 0.28 }
    ], { duration: total, easing: 'ease-in-out', iterations: Infinity }))
  }
}

// A repeating bounce rests between bounces: the bounce takes the first
// share of each cycle.
const resting = (frames, share) => [
  ...frames.slice(0, -1).map(k => (k.offset === undefined ? k : { ...k, offset: k.offset * share })),
  { transform: 'none', offset: share },
  { transform: 'none' }
]
const REPEAT = {
  bounce: svg => byLayer(svg, 40, () => [resting(BOUNCE_UP, 0.4), { duration: 1300, iterations: Infinity }])
}

function byLayer(svg, stagger, frames) {
  const layers = layersOf(svg)
  const slash = svg.hasAttribute('data-slashed')
  // A slashed symbol moves as one, so its gap stays under the slash.
  if (slash) {
    const [keyframes, timing] = frames(svg.querySelector('.sym'))
    return whole(svg, keyframes, timing)
  }
  return layers.map((el, i) => {
    const [keyframes, timing] = frames(el)
    return el.animate(keyframes, { ...timing, delay: (timing.delay || 0) + i * stagger })
  })
}

function whole(svg, keyframes, timing) {
  const sym = svg.querySelector('.sym')
  return sym ? [sym.animate(keyframes, timing)] : []
}

/** Stop whatever effect a symbol is running; it returns to rest. */
export function stopEffect(svg) {
  for (const a of running.get(svg) || []) a.cancel()
  running.delete(svg)
}

/**
 * Play an effect on a symbol. Returns { stop(), done }: done settles when a
 * discrete effect finishes; an indefinite one runs until stop().
 */
export function symbolEffect(svg, effect, { repeat = false } = {}) {
  if (!svg) return STILL
  stopEffect(svg)
  const make = (repeat && REPEAT[effect]) || EFFECTS[effect]
  if (!make || reducedMotion()) return STILL
  const anims = make(svg)
  running.set(svg, anims)
  const done = Promise.all(anims.map(a => a.finished)).then(() => true, () => false)
  const ends = !(repeat || effect === 'pulse' || effect === 'variable-color')
  // Effects that end visible let go of their last frame; Disappear and Draw
  // Off hold theirs until the symbol is removed or plays something else.
  if (ends && effect !== 'disappear' && effect !== 'draw-off') {
    done.then(finished => { if (finished && running.get(svg) === anims) running.delete(svg) })
  }
  return {
    done,
    stop() {
      if (running.get(svg) === anims) stopEffect(svg)
    }
  }
}

/**
 * Swap a symbol for another in place. A symbol and its slash ("mic" ↔
 * "mic-slash") Magic Replace: the slash draws on or off over the same
 * enclosure. Anything else Replaces down-up: the old symbol shrinks away
 * and the new one springs in.
 */
export function replaceSymbol(svg, name) {
  if (!svg) return Promise.resolve()
  const pending = replacing.get(svg)
  if (pending?.name === name) return pending.done
  replacing.delete(svg)
  if (svg.classList.contains(`i-${name}`)) {
    // Asked back to what it shows before the old one had gone.
    if (pending) stopEffect(svg)
    return Promise.resolve()
  }
  const base = name.endsWith('-slash') ? name.slice(0, -6) : name
  if (svg.dataset.symbol === base && svg.querySelector('.sym-slash')) {
    stopEffect(svg)
    for (const c of [...svg.classList]) if (c.startsWith('i-')) svg.classList.remove(c)
    svg.classList.add(`i-${name}`)
    svg.toggleAttribute('data-slashed', name !== base)
    return Promise.resolve()
  }
  const sym = svg.querySelector('.sym')
  if (!sym || reducedMotion() || !svg.isConnected) {
    stopEffect(svg)
    drawSymbol(svg, name)
    return Promise.resolve()
  }
  const token = { name }
  replacing.set(svg, token)
  stopEffect(svg)
  const out = sym.animate([
    { opacity: 1, transform: 'none' },
    { opacity: 0, transform: 'scale(0.5)' }
  ], { duration: 120, easing: 'cubic-bezier(0.4, 0, 1, 1)', fill: 'forwards' })
  running.set(svg, [out])
  token.done = out.finished.then(() => {
    if (replacing.get(svg) !== token) return
    replacing.delete(svg)
    drawSymbol(svg, name)
    const next = svg.querySelector('.sym').animate([
      { opacity: 0, transform: 'scale(0.5)', easing: 'cubic-bezier(0.2, 0, 0.2, 1)' },
      { opacity: 1, transform: 'scale(1.08)', offset: 0.62, easing: 'ease-out' },
      { opacity: 1, transform: 'none' }
    ], { duration: 300 })
    running.set(svg, [next])
    return next.finished.then(() => { if (running.get(svg)?.[0] === next) running.delete(svg) }, () => {})
  }, () => {})
  return token.done
}
