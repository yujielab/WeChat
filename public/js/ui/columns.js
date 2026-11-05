// Where the columns stand in each of the Duo's postures (js/ui/strip.js
// draws them). Plain numbers, no DOM, so they can be checked on their own.
//
//   closed  the outer display (or any one screen): one column fills it.
//   half    partly open, held like a book: two columns, each on its own side
//           of the hinge, meeting it exactly; nothing sits in the bend.
//   open    flat: there is no bend to respect, so the columns take the
//           proportions of what they hold. The conversation, the thing being
//           read, is wide; the column that leads to it (sidebar, list) or
//           tells more about it (details) is narrow. The conversation keeps
//           the same width whichever column is beside it, so moving between
//           the list and the details slides it over without reflowing it.

export const NARROW = { share: 0.36, min: 300, max: 380 }
const THREAD = 2

/** The narrow column's width on a flat screen `width` wide. */
export function narrowWidth(width) {
  const w = Math.round(Math.min(NARROW.max, Math.max(NARROW.min, width * NARROW.share)))
  return Math.min(w, Math.floor(width / 2))
}

/**
 * The open window starting at column `start`: how wide its leading column is
 * and the gap before the trailing one. fold: { axis, start, end } in the
 * shell's own pixels (axis 'none' when there is no hinge).
 */
export function openGeometry({ pose, width, fold, start }) {
  if (!(width > 0)) return { lead: 0, gap: 0 }
  if (pose === 'half') {
    // On the hinge: the screen's segments, or its middle when the device
    // only says it is folded.
    if (fold?.axis === 'vertical' && fold.end > fold.start && fold.start > 0 && fold.end < width) return { lead: fold.start, gap: fold.end - fold.start }
    return { lead: width / 2, gap: 0 }
  }
  const narrow = narrowWidth(width)
  return { lead: start < THREAD ? narrow : width - narrow, gap: 0 }
}

/** Between two geometries: t = 0 is a, 1 is b (a spring may run a little past either). */
export const mixGeometry = (a, b, t) => ({ lead: a.lead + (b.lead - a.lead) * t, gap: a.gap + (b.gap - a.gap) * t })

/**
 * Every column's box ({ x, w }, from the shell's left edge) with the window
 * standing at column `s` (a whole number). One column: each is the full
 * width, side by side. Two: the window's pair from geo(s); the columns before
 * it stand as they would leading their own window, the ones after as they
 * would trailing theirs, so sliding to them only moves what is already the
 * right size.
 */
export function boxesAt(s, { n, width, count, geo }) {
  const boxes = new Array(n)
  if (count === 1) {
    for (let i = 0; i < n; i++) boxes[i] = { x: (i - s) * width, w: width }
    return boxes
  }
  const here = geo(s)
  boxes[s] = { x: 0, w: here.lead }
  if (s + 1 < n) boxes[s + 1] = { x: here.lead + here.gap, w: width - here.lead - here.gap }
  for (let i = s - 1; i >= 0; i--) {
    const g = geo(i)
    boxes[i] = { x: boxes[i + 1].x - g.gap - g.lead, w: g.lead }
  }
  for (let i = s + 2; i < n; i++) {
    const g = geo(i - 1)
    const prev = boxes[i - 1]
    boxes[i] = { x: prev.x + prev.w + g.gap, w: width - g.lead - g.gap }
  }
  return boxes
}

/** The boxes at a position between windows (p from 0 to n − 1): each column's box, in step. */
export function boxesAtPosition(p, opts) {
  const lo = Math.max(0, Math.floor(p + 1e-6))
  const hi = Math.min(opts.n - 1, Math.ceil(p - 1e-6))
  const a = boxesAt(lo, opts)
  if (hi === lo) return a
  const b = boxesAt(hi, opts)
  const t = (p - lo) / (hi - lo)
  return a.map((box, i) => ({ x: box.x + (b[i].x - box.x) * t, w: box.w + (b[i].w - box.w) * t }))
}
