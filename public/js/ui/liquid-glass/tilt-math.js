// The maths of the Liquid Glass tilt (tilt.js), free of the DOM so it can be
// tested: device angles → the screen's own axes → how far the edge light
// slides round each glass rim.

/** The furthest the light travels round a rim, either way (rad). */
export const TILT_MAX = (16 * Math.PI) / 180
const GAIN = 0.8 // rim degrees per degree of tilt
const SETTLE = 2.6 // s: held still at an angle, the light drifts home over about this long
const JUMP = 60 // deg: a reading this far from the last is a gimbal flip, not a tilt

/** beta/gamma (deg) in the screen's own axes [x, y] for the screen's rotation (deg). */
export function screenAxes(beta, gamma, angle = 0) {
  switch (((Math.round(angle / 90) % 4) + 4) % 4) {
    case 1: return [beta, -gamma]
    case 2: return [-gamma, -beta]
    case 3: return [-beta, gamma]
    default: return [gamma, beta]
  }
}

/**
 * A stateful filter. Feed it the tilt in screen axes (deg) and the seconds
 * since the last reading; it returns the light's offset round the rim (rad),
 * eased into ±TILT_MAX. Only movement counts: whatever angle the phone is
 * held at becomes the new rest, so held still the light drifts back home.
 */
export function createTiltFilter() {
  let base = null
  return function step(x, y, dt) {
    if (!base || !(dt <= 1) || Math.abs(x - base.x) > JUMP || Math.abs(y - base.y) > JUMP) base = { x, y }
    const k = 1 - Math.exp(-Math.max(0, dt) / SETTLE)
    base.x += (x - base.x) * k
    base.y += (y - base.y) * k
    const d = (((x - base.x) * 0.9 + (y - base.y) * 0.45) * GAIN * Math.PI) / 180
    return TILT_MAX * Math.tanh(d / TILT_MAX)
  }
}
