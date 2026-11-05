// Where the hinge is, from what the browser reports (public/js/ui/posture.js):
// the viewport's segments first, the device's posture only where there are
// none, and a hinge with no gap is still a hinge.
import test from 'node:test'
import assert from 'node:assert/strict'
import { readFold, poseOf, INNER_MIN } from '../public/js/ui/posture.js'

const W = 951, H = 669
const whole = [{ x: 0, y: 0, width: W, height: H }]
const book = (start, end) => [{ x: 0, y: 0, width: start, height: H }, { x: end, y: 0, width: W - end, height: H }]

test('two segments that touch (a continuous folding screen) are half open — they were taken for no hinge', () => {
  assert.deepEqual(readFold({ segments: book(476, 476), posture: null, width: W, height: H }), { axis: 'vertical', start: 476, end: 476, source: 'segments' })
  assert.deepEqual(readFold({ segments: book(462, 490), posture: null, width: W, height: H }), { axis: 'vertical', start: 462, end: 490, source: 'segments' })
})

test('two touching segments on a device that says it lies flat: open; a hinge with a gap is half open regardless', () => {
  assert.equal(readFold({ segments: book(476, 476), posture: 'continuous', width: W, height: H }).axis, 'none')
  assert.equal(readFold({ segments: book(476, 476), posture: 'folded', width: W, height: H }).axis, 'vertical')
  assert.equal(readFold({ segments: book(462, 490), posture: 'continuous', width: W, height: H }).axis, 'vertical', 'two screens with a real gap')
})

test('one segment is open, whatever the posture says: where there are segments they are the answer', () => {
  assert.deepEqual(readFold({ segments: whole, posture: 'folded', width: W, height: H }), { axis: 'none', start: 0, end: 0, source: 'segments' })
  assert.deepEqual(readFold({ segments: whole, posture: 'continuous', width: W, height: H }), { axis: 'none', start: 0, end: 0, source: 'segments' })
})

test('segments one above the other: a laptop hinge', () => {
  const laptop = [{ x: 0, y: 0, width: 669, height: 462 }, { x: 0, y: 490, width: 669, height: 461 }]
  assert.deepEqual(readFold({ segments: laptop, posture: null, width: 669, height: 951 }), { axis: 'horizontal', start: 462, end: 490, source: 'segments' })
  // In whichever order they come.
  assert.deepEqual(readFold({ segments: [laptop[1], laptop[0]], posture: null, width: 669, height: 951 }).start, 462)
})

test('a hinge outside the screen, or segments that overlap, is not believed', () => {
  assert.equal(readFold({ segments: book(990, 1000), posture: null, width: W, height: H }).axis, 'none')
  assert.equal(readFold({ segments: book(500, 480), posture: null, width: W, height: H }).axis, 'none')
  assert.equal(readFold({ segments: book(0, 0), posture: null, width: W, height: H }).axis, 'none')
})

test('without segments, the posture: folded is half open down the middle of the longer side; not on the outer display', () => {
  assert.deepEqual(readFold({ segments: null, posture: 'folded', width: W, height: H }), { axis: 'vertical', start: 476, end: 476, source: 'posture' })
  assert.deepEqual(readFold({ segments: null, posture: 'folded', width: 669, height: 951 }), { axis: 'horizontal', start: 476, end: 476, source: 'posture' })
  assert.equal(readFold({ segments: null, posture: 'folded', width: 466, height: 678 }).axis, 'none', `under ${INNER_MIN} one way: the outer display`)
  assert.deepEqual(readFold({ segments: null, posture: 'continuous', width: W, height: H }), { axis: 'none', start: 0, end: 0, source: 'posture' })
  assert.deepEqual(readFold({ segments: null, posture: null, width: W, height: H }), { axis: 'none', start: 0, end: 0, source: 'none' })
})

test('the posture named: half with a hinge, open on the inner display, closed on the outer', () => {
  const none = { axis: 'none' }
  assert.equal(poseOf({ axis: 'vertical' }, { split: true, width: W, height: H }), 'half')
  assert.equal(poseOf(none, { split: true, width: W, height: H }), 'open')
  assert.equal(poseOf(none, { split: false, width: 669, height: 951 }), 'open', 'upright, one column, still open')
  assert.equal(poseOf(none, { split: false, width: 466, height: 678 }), 'closed')
})
