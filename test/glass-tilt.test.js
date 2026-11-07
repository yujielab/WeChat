// The Liquid Glass tilt (public/js/ui/liquid-glass/tilt-math.js): device
// angles in the screen's axes, and how far the edge light slides round a rim.
import test from 'node:test'
import assert from 'node:assert/strict'
import { screenAxes, createTiltFilter, TILT_MAX } from '../public/js/ui/liquid-glass/tilt-math.js'

const deg = r => (r * 180) / Math.PI

test("the screen's axes follow its rotation", () => {
  assert.deepEqual(screenAxes(40, 10, 0), [10, 40])
  assert.deepEqual(screenAxes(40, 10, 90), [40, -10])
  assert.deepEqual(screenAxes(40, 10, 180), [-10, -40])
  assert.deepEqual(screenAxes(40, 10, 270), [-40, 10])
  assert.deepEqual(screenAxes(40, 10, -90), [-40, 10])
})

test('however the phone is held, the light starts at home', () => {
  const f = createTiltFilter()
  assert.equal(f(25, 55, Infinity), 0)
  assert.equal(createTiltFilter()(-80, 10, 0.016), 0)
})

test('a small tilt moves the light a little, the same way each time', () => {
  const f = createTiltFilter()
  f(0, 45, Infinity)
  const right = f(10, 45, 0.016)
  assert.ok(right > 0 && deg(right) > 5 && deg(right) < 8, `10° of tilt → ${deg(right).toFixed(2)}°`)
  const g = createTiltFilter()
  g(0, 45, Infinity)
  assert.ok(g(-10, 45, 0.016) < 0, 'the other way, the other way')
})

test('it never goes far: eased into ±16°', () => {
  const f = createTiltFilter()
  f(0, 45, Infinity)
  for (const x of [20, 40, 59]) {
    const v = f(x, 45 + x / 2, 0.016)
    assert.ok(Math.abs(v) < TILT_MAX, `${x}° → ${deg(v).toFixed(2)}°`)
  }
  assert.ok(deg(TILT_MAX) === 16)
})

test('held still at an angle, the light drifts back home', () => {
  const f = createTiltFilter()
  f(0, 45, Infinity)
  const first = f(12, 45, 0.016)
  let v = first
  for (let i = 0; i < 60 * 3; i++) v = f(12, 45, 1 / 60) // three seconds held
  assert.ok(Math.abs(v) < Math.abs(first) * 0.4, `${deg(first).toFixed(2)}° → ${deg(v).toFixed(2)}°`)
  for (let i = 0; i < 60 * 10; i++) v = f(12, 45, 1 / 60)
  assert.ok(Math.abs(deg(v)) < 0.1, 'and settles there')
})

test('a gimbal flip near upright, or a long gap, re-centres instead of whipping the light', () => {
  const f = createTiltFilter()
  f(5, 85, Infinity)
  assert.equal(f(-170, 95, 0.016), 0, 'gamma flipping past upright is not a tilt')
  const g = createTiltFilter()
  g(0, 45, Infinity)
  assert.equal(g(30, 45, 5), 0, 'after a pause the new angle is the rest')
})
