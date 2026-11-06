// The VoiceBeam input chain (public/js/ui/voice-level.js): raw mic amplitude →
// gain → gate → attack/release smoothing → a level in 0..1.
import test from 'node:test'
import assert from 'node:assert/strict'
import { shapeLevel } from '../public/js/ui/voice-level.js'

const near = (a, b, eps = 0.01) => Math.abs(a - b) <= eps

test('silence stays at nothing', () => {
  assert.equal(shapeLevel(0, 0), 0)
  assert.equal(shapeLevel(0, 0, {}, 0.05), 0)
})

test('the gate drops anything under the threshold, and decays a held level toward it', () => {
  // raw·sensitivity below threshold reads as silence: a held level eases down, never jumps.
  const next = shapeLevel(0.02, 0.5)
  assert.ok(next < 0.5 && next > 0.45, `decays, not jumps: ${next}`)
})

test('a loud frame rises part-way toward 1 on the attack', () => {
  const v = shapeLevel(1, 0)
  assert.ok(v > 0 && v < 1, v)
  assert.ok(near(v, 0.109, 0.02), v)
})

test('attack is snappier than release: the same step up moves more than the step down', () => {
  const up = shapeLevel(1, 0)          // from quiet to loud
  const down = 1 - shapeLevel(0, 1)    // from loud to quiet, as a drop
  assert.ok(up > down, `attack ${up} should exceed release ${down}`)
})

test('it never leaves 0..1, whatever the input', () => {
  assert.ok(shapeLevel(10, 0) <= 1)
  assert.ok(shapeLevel(1, 0.999) <= 1)
  assert.ok(shapeLevel(-5, 0.2) >= 0)
})

test('more sensitivity and more time each move it further', () => {
  assert.ok(shapeLevel(0.1, 0, { sensitivity: 5 }) > shapeLevel(0.1, 0, { sensitivity: 1 }))
  assert.ok(shapeLevel(1, 0, {}, 0.05) > shapeLevel(1, 0, {}, 0.016))
})

test('sustained voice converges to the top; then silence trails back to nothing', () => {
  let v = 0
  for (let i = 0; i < 200; i++) v = shapeLevel(1, v)
  assert.ok(v > 0.99, `rose to ${v}`)
  for (let i = 0; i < 600; i++) v = shapeLevel(0, v)
  assert.ok(v < 0.01, `fell to ${v}`)
})
