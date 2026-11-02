// Where a floating tile comes to rest — the call's picture in picture over
// the app, or the self view inside a call: one of the four corners of the
// room it may use, the one a throw is heading for; or, flung past a side,
// tucked against that side with a strip still showing (picture in picture
// only, as on iOS). Pure geometry with no DOM, checked by test/corners.test.js.
//
// frame: { left, top, right, bottom } — the room the tile's whole box rests in
// size:  { w, h }
// edge:  { left, right } — the visible sides a tucked tile hangs off

export const CORNERS = ['tl', 'tr', 'bl', 'br']

const clamp = (v, lo, hi) => Math.max(lo, Math.min(hi, v))

/** Top-left of a tile resting in `corner`; a frame too small for it centres it on that axis. */
export function cornerPoint(frame, size, corner) {
  const roomX = frame.right - frame.left - size.w
  const roomY = frame.bottom - frame.top - size.h
  return {
    x: roomX < 0 ? frame.left + roomX / 2 : corner[1] === 'l' ? frame.left : frame.right - size.w,
    y: roomY < 0 ? frame.top + roomY / 2 : corner[0] === 't' ? frame.top : frame.bottom - size.h
  }
}

/** The corner whose resting place is nearest to a tile whose top-left is at `at`. */
export function nearestCorner(frame, size, at) {
  let best = 'tr'
  let bestD = Infinity
  for (const c of CORNERS) {
    const p = cornerPoint(frame, size, c)
    const d = (p.x - at.x) ** 2 + (p.y - at.y) ** 2
    if (d < bestD) {
      bestD = d
      best = c
    }
  }
  return best
}

/** Top-left of a tile tucked against `side`, `strip` of it still showing, at height y (kept in the frame). */
export function stashPoint(frame, size, edge, side, y, strip) {
  return {
    x: side === 'left' ? edge.left - size.w + strip : edge.right - strip,
    y: clamp(y, frame.top, Math.max(frame.top, frame.bottom - size.h))
  }
}

// How far momentum carries something let go at `v` px/s (Apple's projection,
// Designing Fluid Interfaces): `rate` is the deceleration per millisecond.
const travel = (v, rate) => ((v / 1000) * rate) / (1 - rate)

/**
 * Where a tile let go at `at` (its top-left) with `velocity` comes to rest:
 * the corner its momentum carries it towards (projected at the scroll
 * view's normal deceleration). A tile that may be tucked away is, when the
 * first moment of its flight (a tenth of a second) carries its middle past a
 * visible side — dragged off that side, or flicked hard at the side it is
 * near. A throw across the screen lands in the far corner.
 */
export function restingPlace(frame, size, at, velocity = { x: 0, y: 0 }, { stash = false, edge = frame } = {}) {
  if (stash) {
    const middle = at.x + travel(velocity.x, 0.99) + size.w / 2
    const y = at.y + travel(velocity.y, 0.99)
    if (middle < edge.left) return { stashed: 'left', y }
    if (middle > edge.right) return { stashed: 'right', y }
  }
  const to = { x: at.x + travel(velocity.x, 0.998), y: at.y + travel(velocity.y, 0.998) }
  return { corner: nearestCorner(frame, size, to) }
}

/** Out from a tucked place: the corner on that side nearest to where it hangs. */
export function unstashCorner(frame, size, side, y) {
  const top = cornerPoint(frame, size, side === 'left' ? 'tl' : 'tr').y
  const bottom = cornerPoint(frame, size, side === 'left' ? 'bl' : 'br').y
  return `${Math.abs(y - top) <= Math.abs(y - bottom) ? 't' : 'b'}${side === 'left' ? 'l' : 'r'}`
}

/** The corner an arrow key moves a tile to (a tucked tile comes out on its side first). */
export function cornerToward(corner, key) {
  const v = corner?.[0] || 't'
  const h = corner?.[1] || 'r'
  switch (key) {
    case 'ArrowLeft': return `${v}l`
    case 'ArrowRight': return `${v}r`
    case 'ArrowUp': return `t${h}`
    case 'ArrowDown': return `b${h}`
    default: return corner
  }
}
