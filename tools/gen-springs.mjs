#!/usr/bin/env node
// Prints CSS `linear()` easings that sample Apple-style springs, defined the
// way SwiftUI/UIKit do: damping ratio + response (seconds). Paste the output
// into public/css/tokens.css. Run: npm run springs

const SPRINGS = {
  // name: [dampingRatio, response, initialVelocity]
  smooth: [1.0, 0.3, 0],   // default UI motion, no overshoot
  snappy: [0.86, 0.24, 0],  // buttons, small controls, message appear
  bouncy: [0.8, 0.34, 0],  // sheets, menus that "land"
  gentle: [1.0, 0.4, 0]    // large surfaces, page pushes
}

function sample(zeta, response, v0 = 0) {
  const w0 = (2 * Math.PI) / response
  // x(t) is the progress from 0 → 1 (displacement from target is 1 - x).
  const pos = t => {
    if (zeta < 1) {
      const wd = w0 * Math.sqrt(1 - zeta * zeta)
      const A = 1
      const B = (zeta * w0 * A - v0) / wd
      return 1 - Math.exp(-zeta * w0 * t) * (A * Math.cos(wd * t) + B * Math.sin(wd * t))
    }
    return 1 - Math.exp(-w0 * t) * (1 + (w0 - v0) * t)
  }
  // Settled = the last moment the value is still 0.4% (imperceptible) off target.
  let end = 0
  for (let t = 0; t < 3; t += 0.001) {
    if (Math.abs(1 - pos(t)) >= 0.004) end = t + 0.001
  }
  const steps = 40
  const pts = []
  for (let i = 0; i <= steps; i++) {
    const t = (end * i) / steps
    pts.push(+pos(t).toFixed(4))
  }
  pts[pts.length - 1] = 1
  return { duration: Math.round(end * 1000), easing: `linear(${pts.join(', ')})` }
}

for (const [name, [z, r, v]] of Object.entries(SPRINGS)) {
  const { duration, easing } = sample(z, r, v)
  console.log(`  --spring-${name}: ${easing};`)
  console.log(`  --spring-${name}-dur: ${duration}ms;`)
}
