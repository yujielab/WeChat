// Where the columns stand in each posture (public/js/ui/columns.js): one
// column closed; on the hinge half open; the conversation wide and the column
// beside it narrow open flat; and every step between, in step.
import test from 'node:test'
import assert from 'node:assert/strict'
import { NARROW, narrowWidth, openGeometry, mixGeometry, boxesAt, boxesAtPosition } from '../public/js/ui/columns.js'

const N = 4 // sidebar | list | conversation | details
const W = 951
const hinge = { axis: 'vertical', start: 462, end: 490 }
const flat = s => openGeometry({ pose: 'open', width: W, fold: { axis: 'none' }, start: s })
const half = s => openGeometry({ pose: 'half', width: W, fold: hinge, start: s })
const near = (a, b, msg) => assert.ok(Math.abs(a - b) < 1e-6, `${msg || ''} ${a} ≈ ${b}`)

test('open flat, the column beside the conversation is narrow, a third of the screen within bounds', () => {
  assert.equal(narrowWidth(951), 342)
  assert.equal(narrowWidth(700), NARROW.min, 'never narrower than a list can be read')
  assert.equal(narrowWidth(1600), NARROW.max, 'never wider than a list needs')
  assert.equal(narrowWidth(500), 250, 'and never more than half')
})

test('open flat, the conversation keeps its width whichever column is beside it', () => {
  // list | conversation, then conversation | details
  assert.deepEqual(flat(1), { lead: 342, gap: 0 })
  assert.deepEqual(flat(2), { lead: 609, gap: 0 })
  const withList = boxesAt(1, { n: N, width: W, count: 2, geo: flat })
  const withDetails = boxesAt(2, { n: N, width: W, count: 2, geo: flat })
  assert.deepEqual(withList[2], { x: 342, w: 609 })
  assert.deepEqual(withDetails[2], { x: 0, w: 609 })
  assert.deepEqual(withDetails[3], { x: 609, w: 342 })
  // The sidebar leads with the list beside it, narrow too.
  assert.deepEqual(boxesAt(0, { n: N, width: W, count: 2, geo: flat }).slice(0, 2), [{ x: 0, w: 342 }, { x: 342, w: 609 }])
})

test('half open, the two columns meet the hinge exactly, whatever is in them', () => {
  for (const s of [0, 1, 2]) assert.deepEqual(half(s), { lead: 462, gap: 28 })
  const b = boxesAt(1, { n: N, width: W, count: 2, geo: half })
  assert.deepEqual(b[1], { x: 0, w: 462 }); assert.deepEqual(b[2], { x: 490, w: 461 })
  // Folded without segments (the device only says so): the middle, no gap.
  assert.deepEqual(openGeometry({ pose: 'half', width: W, fold: { axis: 'none' }, start: 1 }), { lead: 475.5, gap: 0 })
  // A hinge reported outside the screen is not believed.
  assert.deepEqual(openGeometry({ pose: 'half', width: W, fold: { axis: 'vertical', start: 990, end: 1010 }, start: 1 }), { lead: 475.5, gap: 0 })
})

test('folded, one column fills the screen and the others wait beside it', () => {
  const b = boxesAt(2, { n: N, width: 466, count: 1, geo: flat })
  assert.deepEqual(b.map(x => x.x), [-932, -466, 0, 466])
  assert.ok(b.every(x => x.w === 466))
})

test('sliding between windows moves every column in step, and nothing overlaps or parts', () => {
  for (const geo of [flat, half]) {
    for (const p of [1, 1.25, 1.5, 1.8, 2]) {
      const b = boxesAtPosition(p, { n: N, width: W, count: 2, geo })
      const gap = geo(1).gap
      for (let i = 0; i + 1 < N; i++) near(b[i].x + b[i].w + gap, b[i + 1].x, `columns ${i}|${i + 1} meet at ${p}`)
    }
  }
  // Halfway from list | conversation to conversation | details, the list
  // narrows away while the details come in: the conversation keeps 609.
  const mid = boxesAtPosition(1.5, { n: N, width: W, count: 2, geo: flat })
  near(mid[2].w, 609)
  near(mid[2].x, 171)
})

test('the divider glides between the hinge and the conversation\'s width, and a spring may carry it a little past', () => {
  assert.deepEqual(mixGeometry(half(1), flat(1), 0), half(1))
  assert.deepEqual(mixGeometry(half(1), flat(1), 1), flat(1))
  const m = mixGeometry(half(1), flat(1), 0.5)
  assert.equal(m.lead, 402); assert.equal(m.gap, 14)
  assert.ok(mixGeometry(half(1), flat(1), 1.04).lead < 342, 'overshoot')
  // Mid-glide, the window's two columns still fill the screen with the gap between them.
  const b = boxesAt(1, { n: N, width: W, count: 2, geo: s => mixGeometry(half(s), flat(s), 0.5) })
  near(b[1].w + 14 + b[2].w, W)
})

test('nothing to draw on a screen of no size', () => {
  assert.deepEqual(openGeometry({ pose: 'open', width: 0, start: 1 }), { lead: 0, gap: 0 })
})
