// Framing a photo in the avatar editor's circle (public/js/ui/framing.js): how
// big it is drawn, how far it may move, which square of it is uploaded, and
// the colour it lends the sheet.
import test from 'node:test'
import assert from 'node:assert/strict'
import { coverScale, clampFrame, frameBox, cropRect, zoomAbout, tintOf, hsl, MAX_ZOOM, OUTPUT } from '../public/js/ui/framing.js'

const near = (a, b, msg) => assert.ok(Math.abs(a - b) < 1e-6, `${msg || ''} ${a} ≈ ${b}`)

test('a photo is drawn just large enough to cover the circle', () => {
  assert.equal(coverScale(600, 400, 200), 0.5, 'the short side meets the circle')
  assert.equal(coverScale(400, 800, 200), 0.5)
  assert.equal(coverScale(0, 400, 200), 1, 'nothing to measure: as it is')
  const box = frameBox({ w: 600, h: 400, d: 200, zoom: 1, x: 0, y: 0 })
  assert.deepEqual(box, { left: -50, top: 0, width: 300, height: 200 }, 'centred, overhanging left and right')
})

test('zoom stays between 1 and the most, and the photo can never leave a gap in the circle', () => {
  assert.equal(clampFrame({ w: 600, h: 400, d: 200, zoom: 9 }).zoom, MAX_ZOOM)
  assert.equal(clampFrame({ w: 600, h: 400, d: 200, zoom: 0.2 }).zoom, 1)
  assert.equal(clampFrame({ w: 600, h: 400, d: 200, zoom: NaN }).zoom, 1)
  // At zoom 1 a landscape photo moves sideways by its overhang, not up or down.
  const f = clampFrame({ w: 600, h: 400, d: 200, zoom: 1, x: 500, y: 80 })
  assert.equal(f.x, 50); assert.equal(f.y, 0)
  assert.equal(clampFrame({ w: 600, h: 400, d: 200, zoom: 1, x: -500 }).x, -50)
  // Zoomed in, it may move further each way.
  const z = clampFrame({ w: 600, h: 400, d: 200, zoom: 2, x: 999, y: -999 })
  assert.equal(z.x, 200); assert.equal(z.y, -100)
})

test('the square uploaded is the one the circle shows', () => {
  // Unmoved: the middle square of the photo.
  assert.deepEqual(cropRect({ w: 600, h: 400, d: 200, zoom: 1, x: 0, y: 0 }), { sx: 100, sy: 0, size: 400 })
  // Moved all the way right on screen: the photo's left edge shows.
  assert.deepEqual(cropRect({ w: 600, h: 400, d: 200, zoom: 1, x: 50, y: 0 }), { sx: 0, sy: 0, size: 400 })
  // Zoomed twice: half as much of it, about its middle.
  const c = cropRect({ w: 600, h: 400, d: 200, zoom: 2, x: 0, y: 0 })
  near(c.size, 200); near(c.sx, 200); near(c.sy, 100)
  // Pushed past the edge: still inside the photo.
  const edge = cropRect({ w: 600, h: 400, d: 200, zoom: 2, x: -9999, y: -9999 })
  near(edge.sx + edge.size, 600, 'right edge'); near(edge.sy + edge.size, 400, 'bottom edge')
  assert.equal(OUTPUT, 512)
})

test('zooming about a point keeps that point of the photo under it', () => {
  const frame = { w: 600, h: 400, d: 200, zoom: 1, x: 0, y: 0 }
  // A point 40px right of centre is photo x = 300 + 40 / 0.5 = 380.
  const next = zoomAbout(frame, 2, 40, 0)
  assert.equal(next.w, 600, 'the photo\'s size is kept'); assert.equal(next.zoom, 2)
  const box = frameBox(next)
  near((40 + 100 - box.left) / (box.width / 600), 380, 'the same photo pixel under the finger')
  // Past the most it will zoom, it stops there.
  assert.equal(zoomAbout(frame, 50).zoom, MAX_ZOOM)
})

test('the sheet takes the photo\'s hue, quietened: light on a light screen, deep on a dark one', () => {
  assert.deepEqual(hsl(255, 0, 0), [0, 1, 0.5])
  assert.deepEqual(hsl(128, 128, 128).slice(0, 2), [0, 0])
  assert.equal(tintOf(201, 180, 138), 'hsl(40 30% 80%)', 'a warm beige, no louder than 30%')
  assert.equal(tintOf(201, 180, 138, true), 'hsl(40 22% 17%)')
  assert.equal(tintOf(0, 0, 255), 'hsl(240 30% 80%)', 'even a pure blue is only a wash')
  assert.equal(tintOf(120, 120, 120), 'hsl(0 0% 80%)', 'grey stays grey')
})
