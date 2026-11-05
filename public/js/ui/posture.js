// Where the hinge is, from what the browser reports (js/ui/viewport.js reads
// the reports; this decides). Plain values, no DOM, so it can be checked on
// its own.
//
// Two sources, in order of trust:
//   segments  the Viewport Segments API: the screen as one rectangle, or as
//             two either side of the hinge. Where the browser has it, it is
//             the answer — two segments is half open, one is not — even
//             when the two touch with no gap between them (a continuous
//             folding screen), which was read as no hinge at all; only a
//             device that says it lies flat overrules two that touch.
//   posture   the Device Posture API: "folded" or "continuous". Used only
//             where there are no segments to go by; the hinge is then taken
//             to run down the middle of the longer side.

/** The outer display is never the folded one: only a screen this wide both ways can be. */
export const INNER_MIN = 560

const NONE = { axis: 'none', start: 0, end: 0 }

/**
 * segments: rectangles ({ x, y, width, height }) when the browser reports
 * segments (one when there is no hinge), or null when it has no such API.
 * posture: 'folded' | 'continuous' | null.
 * width, height: the viewport.
 * Returns { axis: 'none' | 'vertical' | 'horizontal', start, end, source }:
 * the hinge from start to end along the axis it cuts (x for a vertical one),
 * and which report decided ('segments' | 'posture' | 'none').
 */
export function readFold({ segments, posture, width, height }) {
  if (Array.isArray(segments)) {
    let hinge = segments.length >= 2 ? between(segments[0], segments[1], width, height) : null
    // Two segments that touch say only where the screen could bend; if the
    // device says it lies flat, it does. A hinge with a gap is always one.
    if (hinge && hinge.start === hinge.end && posture === 'continuous') hinge = null
    return { ...(hinge || NONE), source: 'segments' }
  }
  if (posture === 'folded' && Math.min(width, height) >= INNER_MIN) {
    const axis = width >= height ? 'vertical' : 'horizontal'
    const mid = Math.round((axis === 'vertical' ? width : height) / 2)
    return { axis, start: mid, end: mid, source: 'posture' }
  }
  return { ...NONE, source: posture ? 'posture' : 'none' }
}

/** The hinge between two segments, side by side (a vertical hinge) or one above the other. */
function between(a, b, width, height) {
  const [first, second] = a.x + a.y <= b.x + b.y ? [a, b] : [b, a]
  const sideBySide = second.x >= first.x + first.width - 1
  const start = Math.round(sideBySide ? first.x + first.width : first.y + first.height)
  const end = Math.round(sideBySide ? second.x : second.y)
  const length = sideBySide ? width : height
  // Touching (no gap) is a hinge too; one outside the screen, or overlapping, is not believed.
  if (!(end >= start && start > 0 && end < length)) return null
  return { axis: sideBySide ? 'vertical' : 'horizontal', start, end }
}

/** closed | half | open: half wherever there is a hinge; open on the inner display (two columns, or one turned upright). */
export function poseOf(fold, { split, width, height }) {
  if (fold.axis !== 'none') return 'half'
  return split || Math.min(width, height) >= INNER_MIN ? 'open' : 'closed'
}
