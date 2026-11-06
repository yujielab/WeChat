// Which Liquid Glass a button becomes (public/js/ui/liquid-glass/tone.js),
// from the fill its own CSS gives it — the fills found across the app.
import test from 'node:test'
import assert from 'node:assert/strict'
import { glassTone } from '../public/js/ui/liquid-glass/tone.js'

const WHITE = [255, 255, 255], BLACK = [0, 0, 0]
const tone = (fill, page) => glassTone(fill, page).tone

test('no fill, a white or grey bead, a light chip: clear glass', () => {
  assert.equal(tone([0, 0, 0, 0], WHITE), 'clear')
  assert.equal(tone([255, 255, 255, 1], WHITE), 'clear') // a white bead on white
  assert.equal(tone([245, 245, 250, 1], WHITE), 'clear') // the light secondary pill
  assert.equal(tone([120, 120, 128, 0.16], WHITE), 'clear') // fill tokens
  assert.equal(tone([120, 120, 128, 0.32], BLACK), 'clear')
  assert.equal(tone([15, 15, 17, 1], BLACK), 'clear') // a dark surface in dark mode
  assert.equal(tone([255, 255, 255, 0.14], BLACK), 'clear') // the call screen's toggles
})

test('ink actions stay prominent: tinted glass in their colour', () => {
  const ink = glassTone([0, 0, 0, 1], WHITE)
  assert.equal(ink.tone, 'tint')
  assert.deepEqual(ink.tint, [0, 0, 0, 1])
  assert.equal(tone([255, 255, 255, 1], BLACK), 'tint', 'dark mode ink is white')
  assert.equal(tone([255, 59, 48, 1], WHITE), 'tint', 'Hang up / Discard')
  assert.equal(tone([52, 199, 89, 1], BLACK), 'tint', 'Answer')
})

test('a dark scrim over a photo keeps a light dim for its white symbol', () => {
  const d = glassTone([0, 0, 0, 0.72], WHITE)
  assert.equal(d.tone, 'dim')
  assert.ok(d.tint[3] > 0 && d.tint[3] <= 0.5)
  assert.equal(tone([0, 0, 0, 0.42], BLACK), 'dim')
})
