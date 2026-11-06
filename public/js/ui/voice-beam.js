// VoiceBeam — a sound-reactive glow along the bottom edge of a control, drawn
// on a <canvas>. A centred bloom of coloured lobes rises and spreads with the
// voice; while work is pending it gathers into one beam that travels the edge.
// A port of the voice-glow idea with no dependencies, no React, no inline CSS.
//
// Feed it a live level: either a MediaStream (it taps a WebAudio analyser) or a
// `level` getter / number in 0..1 (wins when there is no stream — e.g. the mic
// module already owns the analyser). The render loop runs only while active,
// and stills to a calm floor under reduced motion.
//
//   const beam = createVoiceBeam(host, target, { colorVariant: 'colorful' })
//   beam.setLevel(() => meter.current)   // or beam.setStream(stream)
//   beam.setActive(true)                 // show + start the loop
//   beam.setProcessing(true)             // gather into a travelling beam
//   beam.destroy()
//
// `host` is the positioned element the canvas lives in; `target` is the control
// whose bottom edge and corner radius the glow follows (defaults to host).

import { reducedMotion } from './dom.js'
import { shapeLevel } from './voice-level.js'

// Up to seven lobe colours per look. core/above/mid/below tint the bright band
// hugging the edge. Tuned for a luminous additive bloom on dark or light.
export const PALETTES = {
  colorful: ['#5b8cff', '#8a5bff', '#d14bff', '#ff4bb0', '#ff7a45', '#ffd24b', '#4bffd2'],
  mono: ['#ffffff', '#dfe7ff', '#bcd0ff', '#9fbcff', '#cdd9ff', '#eaf0ff', '#ffffff'],
  ocean: ['#2bd2ff', '#2b9bff', '#2b6bff', '#51e0c6', '#2bd2ff', '#6fb8ff', '#9ff0ff'],
  sunset: ['#ff5e62', '#ff9966', '#ffc371', '#ff6b9d', '#ff5e62', '#ffd16b', '#ff8e53'],
  forest: ['#5ddf7a', '#39c16a', '#2ea36b', '#7ef0a0', '#39c16a', '#bdf0a0', '#2ea36b'],
  candy: ['#ff8fe0', '#ff6fd8', '#c08cff', '#8cb8ff', '#ff8fe0', '#ffc0ec', '#b8a0ff'],
  ice: ['#aee9ff', '#8fd6ff', '#bcd0ff', '#dff2ff', '#aee9ff', '#e8f6ff', '#9fe0ff'],
  gold: ['#ffd76b', '#ffc24b', '#ffac3b', '#ffe29a', '#ffd76b', '#fff0c0', '#ffb85c']
}
const BANDS = {
  core: 'rgba(255,255,255,0.95)',
  above: 'rgba(255,255,255,0.55)',
  mid: 'rgba(255,255,255,0.28)',
  below: 'rgba(255,255,255,0.12)'
}

// Geometry presets: a ~350px chat input, a small recording pill, or the bottom
// of a phone screen. reach = bloom height as a fraction of width.
const TYPES = {
  default: { reach: 0.42, spread: 0.72, pad: 0.5, lobes: 7 },
  pill: { reach: 0.9, spread: 0.86, pad: 0.7, lobes: 5 },
  mobile: { reach: 0.3, spread: 0.94, pad: 0.34, lobes: 7 }
}

const DEFAULTS = {
  type: 'default',
  colorVariant: 'colorful',
  colors: null,
  bandColors: null,
  sensitivity: 1.6,
  threshold: 0.04,
  attack: 0.6,
  release: 0.12,
  reach: null,
  spread: null,
  flow: 1,
  bend: 0.3,
  idle: 0.06,
  theme: 'auto',
  strength: 1,
  scale: 1,
  active: false,
  paused: false,
  processing: false
}

const clamp = (v, a, b) => (v < a ? a : v > b ? b : v)
const lerp = (a, b, t) => a + (b - a) * t

/** A live analyser over a MediaStream, giving a smoothed RMS level in 0..1. */
function streamMeter(stream) {
  const Ctx = window.AudioContext || window.webkitAudioContext
  if (!Ctx) return null
  const ctx = new Ctx()
  const src = ctx.createMediaStreamSource(stream)
  const analyser = ctx.createAnalyser()
  analyser.fftSize = 1024
  analyser.smoothingTimeConstant = 0.6
  src.connect(analyser)
  const buf = new Uint8Array(analyser.fftSize)
  return {
    level() {
      analyser.getByteTimeDomainData(buf)
      let sum = 0
      for (let i = 0; i < buf.length; i++) {
        const x = (buf[i] - 128) / 128
        sum += x * x
      }
      return Math.min(1, Math.sqrt(sum / buf.length) * 3.2)
    },
    close() {
      try { src.disconnect() } catch {}
      ctx.close().catch(() => {})
    }
  }
}

export function createVoiceBeam(host, target = host, options = {}) {
  const o = { ...DEFAULTS, ...options }
  const canvas = document.createElement('canvas')
  canvas.className = 'voice-beam'
  canvas.setAttribute('aria-hidden', 'true')
  host.appendChild(canvas)
  const ctx = canvas.getContext('2d')

  let meter = null            // live analyser over a stream
  let levelGetter = null      // caller-supplied 0..1 source
  let raf = 0
  let running = false
  let last = 0
  let travel = 0              // processing-beam position, 0..1
  const state = { level: 0 }  // smoothed envelope
  let W = 0, H = 0, dpr = 1
  let left = 0, width = 0, bottom = 0, radius = 0

  const palette = () => (o.colors && o.colors.length ? o.colors : PALETTES[o.colorVariant] || PALETTES.colorful)
  const bands = () => ({ ...BANDS, ...(o.bandColors || {}) })
  const geom = () => TYPES[o.type] || TYPES.default

  // Place the canvas over the host, big enough for the bloom to spill below
  // the target's bottom edge, and learn the edge + corner to hug.
  function measure() {
    const hostBox = host.getBoundingClientRect()
    const box = target.getBoundingClientRect()
    if (!hostBox.width || !box.width) return
    const g = geom()
    const reach = (o.reach ?? g.reach) * box.width * o.scale
    const padX = box.width * 0.4
    left = box.left - hostBox.left - padX
    width = box.width + padX * 2
    const cssH = reach
    bottom = box.bottom - hostBox.top          // canvas bottom sits on the control's bottom edge
    const top = bottom - cssH                  // the bloom rises from there
    radius = parseFloat(getComputedStyle(target).borderBottomLeftRadius) || 0
    dpr = Math.min(2, window.devicePixelRatio || 1)
    W = Math.max(1, Math.round(width * dpr))
    H = Math.max(1, Math.round(cssH * dpr))
    canvas.width = W
    canvas.height = H
    canvas.style.setProperty('--vb-left', `${Math.round(left)}px`)
    canvas.style.setProperty('--vb-top', `${Math.round(top)}px`)
    canvas.style.setProperty('--vb-w', `${Math.round(width)}px`)
    canvas.style.setProperty('--vb-h', `${Math.round(cssH)}px`)
  }

  function frame(now) {
    if (!running) return
    const dt = last ? Math.min(0.05, (now - last) / 1000) : 0.016
    last = now
    const raw = meter ? meter.level() : readLevel()
    const lvl = shapeLevel(raw, state.level, o, dt)
    state.level = lvl
    if (o.processing && !reducedMotion()) travel = (travel + dt * 0.6) % 1
    draw(lvl, now / 1000)
    // The active window is bounded (recording / transcribing), so run the loop
    // through it and stop on setActive(false) / pause.
    if (o.active && !o.paused) raf = requestAnimationFrame(frame)
    else { running = false; clearCanvas() }
  }

  function readLevel() {
    if (typeof levelGetter === 'function') return clamp(Number(levelGetter()) || 0, 0, 1)
    if (typeof levelGetter === 'number') return clamp(levelGetter, 0, 1)
    return 0
  }

  function clearCanvas() {
    ctx.clearRect(0, 0, W, H)
  }

  function draw(level, t) {
    ctx.clearRect(0, 0, W, H)
    const g = geom()
    const cols = palette()
    const n = Math.min(cols.length, g.lobes)
    const rm = reducedMotion()
    const flow = rm ? 0 : o.flow
    const spread = (o.spread ?? g.spread)
    const edgeY = H // bottom edge of the canvas is the control's bottom
    const maxReach = H * 0.96
    const dark = o.theme === 'light' ? false : o.theme === 'dark' ? true : matchMedia('(prefers-color-scheme: dark)').matches
    ctx.globalCompositeOperation = 'lighter'
    ctx.globalAlpha = clamp(o.strength, 0, 1) * (dark ? 1 : 0.9)

    // When processing, pull the lobes toward a single travelling point; the
    // phase below slides each lobe's centre to the beam position. Reduced
    // motion holds the beam centred.
    const beamX = o.processing ? (rm ? 0.5 : 0.12 + 0.76 * (0.5 - 0.5 * Math.cos(travel * Math.PI * 2))) : 0.5

    for (let i = 0; i < n; i++) {
      const f = n > 1 ? i / (n - 1) : 0.5 // 0..1 across the colours
      // Lobe home position, centred and spread out; drifts with flow.
      const drift = Math.sin(t * flow * (0.7 + f) + i) * 0.03 * spread
      const home = 0.5 + (f - 0.5) * spread + drift
      const cx = (o.processing ? lerp(home, beamX, 0.82) : home) * W
      // Each lobe's height: the shared level, shaped by distance from centre
      // (bend), plus a little idle shimmer so it is alive when quiet.
      const centreBias = 1 - Math.abs(f - 0.5) * 2 * o.bend
      const shimmer = 0.5 + 0.5 * Math.sin(t * flow * 1.7 + i * 1.3)
      const amp = clamp(level * centreBias + o.idle * shimmer * 0.6, 0, 1)
      const peak = maxReach * (0.18 + amp * 0.82) * (o.processing ? 1.15 : 1)
      const halfW = W * (0.06 + 0.1 * spread) * (o.processing ? 0.6 : 1)
      paintLobe(ctx, cx, edgeY, halfW, peak, cols[i], amp)
    }

    // The bright band hugging the very edge: widens and lifts with the level.
    paintBand(ctx, level, dark)
    ctx.globalCompositeOperation = 'source-over'
    ctx.globalAlpha = 1
  }

  function paintLobe(ctx, cx, edgeY, halfW, peak, color, amp) {
    // A vertical bloom: bright at the edge, fading up and out. Built from a
    // radial gradient squashed into a tall ellipse.
    const topY = edgeY - peak
    const grad = ctx.createRadialGradient(cx, edgeY, 0, cx, edgeY, peak)
    const [r, g, b] = hexRgb(color)
    grad.addColorStop(0, `rgba(${r},${g},${b},${0.9 * (0.5 + amp * 0.5)})`)
    grad.addColorStop(0.35, `rgba(${r},${g},${b},${0.5 * (0.4 + amp * 0.6)})`)
    grad.addColorStop(1, `rgba(${r},${g},${b},0)`)
    ctx.save()
    ctx.translate(cx, edgeY)
    ctx.scale(halfW / peak, 1) // squash horizontally into a column
    ctx.translate(-cx, -edgeY)
    ctx.fillStyle = grad
    ctx.beginPath()
    ctx.ellipse(cx, edgeY, peak, peak, 0, Math.PI, Math.PI * 2) // upper half only
    ctx.fill()
    ctx.restore()
    void topY
  }

  function paintBand(ctx, level, dark) {
    const b = bands()
    const edgeY = H
    const h = (2 + level * 10) * dpr
    const grad = ctx.createLinearGradient(0, edgeY - h * 3, 0, edgeY)
    grad.addColorStop(0, 'rgba(255,255,255,0)')
    grad.addColorStop(0.5, b.above)
    grad.addColorStop(0.82, b.core)
    grad.addColorStop(1, dark ? b.core : b.mid)
    ctx.fillStyle = grad
    ctx.globalAlpha = clamp(o.strength, 0, 1) * (0.5 + level * 0.5)
    ctx.fillRect(W * 0.08, edgeY - h * 3, W * 0.84, h * 3)
  }

  function start() {
    if (running || !o.active) return
    measure()
    running = true
    last = 0
    raf = requestAnimationFrame(frame)
  }
  function stop() {
    running = false
    cancelAnimationFrame(raf)
    clearCanvas()
  }

  const ro = 'ResizeObserver' in window ? new ResizeObserver(() => measure()) : null
  ro?.observe(host)
  ro?.observe(target)

  function apply() {
    canvas.classList.toggle('on', !!o.active)
    canvas.classList.toggle('processing', !!o.processing)
    if (o.active && !o.paused) { measure(); start() }
    else stop()
  }

  return {
    el: canvas,
    setStream(stream) {
      meter?.close()
      meter = stream ? streamMeter(stream) : null
      return this
    },
    setLevel(src) { levelGetter = src; return this },
    setProcessing(on) { o.processing = !!on; if (on) travel = 0; apply(); return this },
    setActive(on) { o.active = !!on; apply(); return this },
    setPaused(on) { o.paused = !!on; apply(); return this },
    setOptions(next) { Object.assign(o, next); measure(); return this },
    destroy() {
      stop()
      ro?.disconnect()
      meter?.close()
      canvas.remove()
    }
  }
}

function hexRgb(hex) {
  const h = hex.replace('#', '')
  const n = parseInt(h.length === 3 ? h.replace(/./g, c => c + c) : h, 16)
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255]
}

// Re-export so callers get the whole surface from one module.
export { shapeLevel }
