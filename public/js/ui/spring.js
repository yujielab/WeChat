// Interruptible springs for gesture-driven motion, parameterized like UIKit /
// SwiftUI (damping ratio + response). Motion always starts from the current
// on-screen value and can inherit the finger's velocity.

import { reducedMotion } from './dom.js'

export function springState(t, { from, to, velocity = 0, damping = 1, response = 0.35 }) {
  const w0 = (2 * Math.PI) / response
  const x0 = from - to
  let x
  if (damping < 1) {
    const wd = w0 * Math.sqrt(1 - damping * damping)
    const env = Math.exp(-damping * w0 * t)
    x = env * (x0 * Math.cos(wd * t) + ((velocity + damping * w0 * x0) / wd) * Math.sin(wd * t))
  } else {
    x = Math.exp(-w0 * t) * (x0 + (velocity + w0 * x0) * t)
  }
  return to + x
}

/**
 * Animate a number with a spring.
 *   onUpdate(value) every frame; returns { stop(), value(), velocity(), done: Promise }
 * Velocity is in units per second (px/s for positions).
 */
export function spring({ from, to, velocity = 0, damping = 1, response = 0.35, onUpdate, restDelta = 0.4 }) {
  let raf = 0
  let stopped = false
  let current = from
  let currentV = velocity
  let resolveDone
  const done = new Promise(r => { resolveDone = r })
  const params = { from, to, velocity, damping, response }

  if (reducedMotion()) {
    onUpdate(to)
    resolveDone(true)
    return { stop() {}, value: () => to, velocity: () => 0, done }
  }

  const start = performance.now()
  const tick = now => {
    if (stopped) return
    const t = (now - start) / 1000
    const v = springState(t, params)
    const dt = 1 / 240
    currentV = (springState(t + dt, params) - v) / dt
    current = v
    const settled = Math.abs(to - v) < restDelta && Math.abs(currentV) < restDelta * 20
    onUpdate(settled ? to : v)
    if (settled) {
      current = to
      resolveDone(true)
      return
    }
    raf = requestAnimationFrame(tick)
  }
  raf = requestAnimationFrame(tick)
  return {
    stop() {
      stopped = true
      cancelAnimationFrame(raf)
      resolveDone(false)
    },
    value: () => current,
    velocity: () => currentV,
    done
  }
}

/** Velocity tracker over the last ~100 ms of pointer samples. */
export function velocityTracker() {
  const samples = []
  return {
    add(x, y, t = performance.now()) {
      samples.push({ x, y, t })
      while (samples.length > 2 && t - samples[0].t > 100) samples.shift()
    },
    velocity() {
      if (samples.length < 2) return { x: 0, y: 0 }
      const a = samples[0]
      const b = samples[samples.length - 1]
      const dt = (b.t - a.t) / 1000 || 1 / 60
      return { x: (b.x - a.x) / dt, y: (b.y - a.y) / dt }
    },
    reset() {
      samples.length = 0
    }
  }
}

/** Apple's momentum projection (Designing Fluid Interfaces). */
export function project(velocity, decelerationRate = 0.998) {
  return ((velocity / 1000) * decelerationRate) / (1 - decelerationRate)
}

/** Progressive resistance past a boundary. */
export function rubberband(overshoot, dimension, c = 0.55) {
  const s = Math.sign(overshoot)
  const o = Math.abs(overshoot)
  return s * ((o * dimension * c) / (dimension + c * o))
}
