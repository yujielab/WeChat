// The input chain for VoiceBeam, kept pure so it can be reasoned about and
// tested on its own: raw mic amplitude (0..1) → gain → noise gate → attack /
// release smoothing → a level in 0..1. `prev` is last frame's level; `dt` is
// the frame time in seconds.
//
//   sensitivity  gain on the raw amplitude
//   threshold    gate: anything quieter reads as silence, and the rest is
//                expanded back across the full range
//   attack       responsiveness while the level rises (0..1, larger = snappier)
//   release      responsiveness while it falls (0..1, smaller = longer tail)

const clamp = (v, a, b) => (v < a ? a : v > b ? b : v)

export function shapeLevel(raw, prev = 0, opts = {}, dt = 0.016) {
  const { sensitivity = 1.6, threshold = 0.04, attack = 0.6, release = 0.12 } = opts
  let v = clamp(Number(raw) || 0, 0, 4) * sensitivity
  // Gate, then expand what's left above the gate across 0..1.
  v = v <= threshold ? 0 : (v - threshold) / (1 - threshold)
  v = clamp(v, 0, 1)
  // One-pole smoothing toward v. attack and release are responsiveness rates:
  // the rise uses attack, the fall uses the (smaller) release, so a loud moment
  // reads at once and then trails off. coef = 1 - e^(-dt·rate·k).
  const rising = v > prev
  const coef = 1 - Math.exp(-clamp(dt, 0, 0.1) * (rising ? attack : release) * 12)
  return clamp(prev + (v - prev) * coef, 0, 1)
}
