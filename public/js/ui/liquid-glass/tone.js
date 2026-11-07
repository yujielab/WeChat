// What kind of Liquid Glass a button becomes, from the fill its own CSS gives
// it (buttons.js reads that, then the glass replaces it). Free of the DOM so
// it can be tested.
//
//   clear  neutral buttons (no fill, a white or grey bead, a light chip):
//          pure glass, no fill of its own
//   dim    a dark scrim over a photo or video: glass with a light dim, so its
//          white symbol stays readable
//   tint   a filled action (ink Send / Post / Log in, red Hang up, green
//          Answer): the glass takes that colour — prominent, like iOS's
//          tinted glass — so the hierarchy stays
//
// `fill` is [r, g, b, a] (0..255, alpha 0..1); `page` the page colour [r, g, b].

const lum = c => (0.2126 * c[0] + 0.7152 * c[1] + 0.0722 * c[2]) / 255
const chroma = c => (Math.max(c[0], c[1], c[2]) - Math.min(c[0], c[1], c[2])) / 255

export function glassTone(fill, page = [255, 255, 255]) {
  const [r, g, b, a] = fill
  if (!(a >= 0.05)) return { tone: 'clear', tint: [1, 1, 1, 0] }
  const rgb = [r / 255, g / 255, b / 255]
  // a colour of its own: an action (red, green, blue)
  if (chroma(fill) > 0.3 && a >= 0.5) return { tone: 'tint', tint: [...rgb, 1] }
  // ink: opaque, and stands out from the page (black on white, white on black)
  if (a >= 0.95 && Math.abs(lum(fill) - lum(page)) > 0.5) return { tone: 'tint', tint: [...rgb, 1] }
  // a dark see-through scrim (over media)
  if (lum(fill) < 0.3 && a >= 0.2 && a < 0.95) return { tone: 'dim', tint: [0, 0, 0, Math.min(0.5, a * 0.6)] }
  return { tone: 'clear', tint: [1, 1, 1, 0] }
}
