// A photo framed in a circle (the avatar editor, views/avatar-editor.js): how
// big it is drawn, how far it may be moved, which part of it becomes the
// picture; and the colour a photo lends the sheet around it. Plain numbers,
// no DOM, so they can be checked on their own.

export const MAX_ZOOM = 4
export const OUTPUT = 512 // pixels a side of the avatar that is uploaded

/** The scale at which a w × h photo just covers a circle of diameter d. */
export const coverScale = (w, h, d) => (w > 0 && h > 0 ? Math.max(d / w, d / h) : 1)

/**
 * A framing kept in bounds: zoom between 1 and MAX_ZOOM, and moved no further
 * than keeps the circle covered. x and y are the photo's centre offset from
 * the circle's centre, in screen pixels.
 */
export function clampFrame({ w, h, d, zoom = 1, x = 0, y = 0 }) {
  const z = Math.min(MAX_ZOOM, Math.max(1, Number.isFinite(zoom) ? zoom : 1))
  const k = coverScale(w, h, d) * z
  const mx = Math.max(0, (w * k - d) / 2)
  const my = Math.max(0, (h * k - d) / 2)
  const clamp = (v, m) => Math.min(m, Math.max(-m, Number.isFinite(v) ? v : 0))
  return { zoom: z, x: clamp(x, mx), y: clamp(y, my), scale: k }
}

/** Where the photo is drawn inside the circle: its box, in screen pixels from the circle's top left. */
export function frameBox({ w, h, d, zoom, x, y }) {
  const f = clampFrame({ w, h, d, zoom, x, y })
  const width = w * f.scale
  const height = h * f.scale
  return { left: (d - width) / 2 + f.x, top: (d - height) / 2 + f.y, width, height }
}

/** The square of the photo, in its own pixels, that the circle shows: what is cut out and uploaded. */
export function cropRect({ w, h, d, zoom, x, y }) {
  const f = clampFrame({ w, h, d, zoom, x, y })
  const size = d / f.scale
  return {
    sx: Math.max(0, ((w * f.scale - d) / 2 - f.x) / f.scale),
    sy: Math.max(0, ((h * f.scale - d) / 2 - f.y) / f.scale),
    size: Math.min(size, w, h)
  }
}

/**
 * Zoom about a point (px, py from the circle's centre), keeping that point of
 * the photo under it. Returns the frame with its new zoom and offset.
 */
export function zoomAbout(frame, nextZoom, px = 0, py = 0) {
  const before = clampFrame(frame)
  const after = clampFrame({ ...frame, zoom: nextZoom })
  const r = after.scale / before.scale
  const { zoom, x, y } = clampFrame({ ...frame, zoom: after.zoom, x: px - (px - before.x) * r, y: py - (py - before.y) * r })
  return { ...frame, zoom, x, y }
}

/**
 * The colour a photo lends the sheet: its own hue, quietened, light on a
 * light screen and deep on a dark one, so the controls on it stay legible.
 * r, g, b: the photo's average colour (0–255).
 */
export function tintOf(r, g, b, dark = false) {
  const [h, s] = hsl(r, g, b)
  const sat = Math.round(Math.min(s * 100, 30))
  return dark ? `hsl(${h} ${Math.min(sat, 22)}% 17%)` : `hsl(${h} ${sat}% 80%)`
}

/** Hue (0–360), saturation and lightness (0–1) of an RGB colour. */
export function hsl(r, g, b) {
  const [R, G, B] = [r, g, b].map(v => Math.min(255, Math.max(0, v)) / 255)
  const max = Math.max(R, G, B), min = Math.min(R, G, B), l = (max + min) / 2
  if (max === min) return [0, 0, l]
  const d = max - min
  const s = l > 0.5 ? d / (2 - max - min) : d / (max + min)
  const h = max === R ? (G - B) / d + (G < B ? 6 : 0) : max === G ? (B - R) / d + 2 : (R - G) / d + 4
  return [Math.round(h * 60), s, l]
}
