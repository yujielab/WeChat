// What is behind an element, painted into a 2D canvas for the Liquid Glass
// to refract (buttons.js). The glass must refract exactly what is behind it,
// or the difference reads as a fill, so this paints, the way the browser
// does: the backgrounds of the element's ancestors (colour, gradients, images,
// a wallpaper's doodle, a photo under its wash), their underlays (a ::before
// at a negative z-index, like the composer's fade), and whatever comes before
// the element and overlaps it — backgrounds, photos, video frames, canvases
// and text. Other glass canvases count as transparent.

/** Split a CSS list at its top-level commas. */
function splitTop(s) {
  const out = []
  let depth = 0
  let start = 0
  for (let i = 0; i < s.length; i++) {
    const c = s[i]
    if (c === '(') depth++
    else if (c === ')') depth--
    else if (c === ',' && depth === 0) { out.push(s.slice(start, i).trim()); start = i + 1 }
  }
  out.push(s.slice(start).trim())
  return out.filter(Boolean)
}

let scratch = null
function rgba(str) {
  // color-mix() and wide-gamut colours compute to color(srgb r g b / a), 0..1
  const c = /color\(\s*(?:srgb|srgb-linear|display-p3)\s+([^)]+)\)/.exec(str)
  if (c) {
    const [rgb, a] = c[1].split('/')
    const p = rgb.trim().split(/\s+/).map(v => (v.endsWith('%') ? parseFloat(v) / 100 : Number(v)))
    return [p[0] * 255, p[1] * 255, p[2] * 255, a != null ? (a.trim().endsWith('%') ? parseFloat(a) / 100 : Number(a)) : 1]
  }
  let m = /rgba?\(([^)]+)\)/.exec(str)
  if (!m) {
    scratch ||= document.createElement('canvas').getContext('2d')
    scratch.fillStyle = '#000'
    scratch.fillStyle = str
    const v = scratch.fillStyle
    if (v[0] === '#') return [parseInt(v.slice(1, 3), 16), parseInt(v.slice(3, 5), 16), parseInt(v.slice(5, 7), 16), 1]
    return v !== str && /^(rgba?|color)\(/.test(v) ? rgba(v) : [0, 0, 0, 0]
  }
  const p = m[1].split(/[\s,/]+/).filter(Boolean).map(Number)
  return [p[0], p[1], p[2], p.length > 3 ? p[3] : 1]
}
const css = c => `rgba(${c[0]},${c[1]},${c[2]},${c[3]})`

/** Colour stops → [{ c:[r,g,b,a], p:0..1 }], positions resolved as CSS does. */
function parseStops(parts, lineLen) {
  const flat = []
  for (const s of parts) {
    let color, rest
    if (/^[a-z-]+\(/i.test(s)) { const end = s.indexOf(')') + 1; color = s.slice(0, end); rest = s.slice(end).trim() }
    else { const sp = s.indexOf(' '); color = sp < 0 ? s : s.slice(0, sp); rest = sp < 0 ? '' : s.slice(sp + 1).trim() }
    const pos = rest ? rest.split(/\s+/).map(p => (p.endsWith('%') ? parseFloat(p) / 100 : parseFloat(p) / lineLen)) : []
    const c = rgba(color)
    if (pos.length === 2) flat.push({ c, p: pos[0] }, { c, p: pos[1] })
    else flat.push({ c, p: pos.length ? pos[0] : null })
  }
  if (!flat.length) return flat
  if (flat[0].p == null) flat[0].p = 0
  if (flat.at(-1).p == null) flat.at(-1).p = 1
  let max = flat[0].p
  for (const s of flat) if (s.p != null) { if (s.p < max) s.p = max; max = s.p }
  for (let i = 1; i < flat.length; i++) {
    if (flat[i].p != null) continue
    let j = i
    while (flat[j].p == null) j++
    const a = flat[i - 1].p, b = flat[j].p, n = j - i + 1
    for (let k = i; k < j; k++) flat[k].p = a + ((b - a) * (k - i + 1)) / n
    i = j
  }
  // CSS blends stops premultiplied: a transparent stop takes its neighbours'
  // colour at zero alpha (canvas would otherwise fade through black).
  const out = []
  for (let i = 0; i < flat.length; i++) {
    const s = flat[i]
    if (s.c[3] !== 0) { out.push(s); continue }
    const prev = flat[i - 1], next = flat[i + 1]
    if (prev) out.push({ c: [prev.c[0], prev.c[1], prev.c[2], 0], p: s.p })
    if (next) out.push({ c: [next.c[0], next.c[1], next.c[2], 0], p: s.p })
    if (!prev && !next) out.push(s)
  }
  return out
}
function addStops(g, stops) {
  for (const s of stops) g.addColorStop(Math.min(1, Math.max(0, s.p)), css(s.c))
}

const isShapeSpec = a => /^(circle|ellipse|closest|farthest|at\b|-?[\d.]+(px|%))/.test(a)
const posValue = (v, room) => (v == null ? room / 2 : v === 'left' || v === 'top' ? 0 : v === 'right' || v === 'bottom' ? room : v === 'center' ? room / 2 : v.endsWith('%') ? (parseFloat(v) / 100) * room : parseFloat(v) || 0)

/** Fill a w×h box (current transform) with a CSS gradient. */
function fillGradient(ctx, src, w, h) {
  const open = src.indexOf('(')
  const name = src.slice(0, open).trim()
  let args = splitTop(src.slice(open + 1, src.lastIndexOf(')')))
  if (name === 'linear-gradient') {
    let angle = Math.PI
    const first = args[0]
    const deg = /^(-?[\d.]+)(deg|rad|turn|grad)$/.exec(first)
    if (deg) {
      const n = parseFloat(deg[1])
      angle = deg[2] === 'deg' ? (n * Math.PI) / 180 : deg[2] === 'rad' ? n : deg[2] === 'turn' ? n * 2 * Math.PI : (n * Math.PI) / 200
      args = args.slice(1)
    } else if (first.startsWith('to ')) {
      const sx = first.includes('right') ? 1 : first.includes('left') ? -1 : 0
      const sy = first.includes('bottom') ? 1 : first.includes('top') ? -1 : 0
      const dx = sx && sy ? sx * h : sx, dy = sx && sy ? sy * w : sy
      angle = Math.atan2(dx, -dy)
      args = args.slice(1)
    }
    const L = Math.abs(w * Math.sin(angle)) + Math.abs(h * Math.cos(angle))
    const dx = (Math.sin(angle) * L) / 2, dy = (-Math.cos(angle) * L) / 2
    const g = ctx.createLinearGradient(w / 2 - dx, h / 2 - dy, w / 2 + dx, h / 2 + dy)
    addStops(g, parseStops(args, L || 1))
    ctx.fillStyle = g
    ctx.fillRect(0, 0, w, h)
    return
  }
  if (name !== 'radial-gradient') return
  let circle = false, cx = w / 2, cy = h / 2, sizes = []
  if (isShapeSpec(args[0])) {
    const [shapePart, posPart] = args[0].split(/\s*\bat\b\s*/)
    args = args.slice(1)
    const toks = (shapePart || '').split(/\s+/).filter(Boolean)
    circle = toks.includes('circle') || (toks.filter(t => /^[\d.]/.test(t)).length === 1 && !toks.includes('ellipse'))
    sizes = toks.filter(t => /^-?[\d.]/.test(t))
    if (posPart) {
      const [px, py] = posPart.split(/\s+/)
      cx = posValue(px, w); cy = posValue(py ?? 'center', h)
    }
  }
  let rx, ry
  if (sizes.length) {
    rx = sizes[0].endsWith('%') ? (parseFloat(sizes[0]) / 100) * w : parseFloat(sizes[0])
    ry = circle ? rx : sizes[1] ? (sizes[1].endsWith('%') ? (parseFloat(sizes[1]) / 100) * h : parseFloat(sizes[1])) : rx
  } else {
    // farthest-corner, the default
    const fx = Math.max(cx, w - cx), fy = Math.max(cy, h - cy)
    if (circle) rx = ry = Math.hypot(fx, fy)
    else { rx = fx * Math.SQRT2; ry = fy * Math.SQRT2 }
  }
  if (!(rx > 0 && ry > 0)) return
  ctx.save()
  ctx.translate(cx, cy)
  ctx.scale(1, ry / rx)
  const g = ctx.createRadialGradient(0, 0, 0, 0, 0, rx)
  addStops(g, parseStops(args, rx))
  ctx.fillStyle = g
  ctx.fillRect(-cx, (-cy * rx) / ry, w, (h * rx) / ry)
  ctx.restore()
}

const images = new Map() // url → HTMLImageElement
function cachedImage(url, onReady) {
  let img = images.get(url)
  if (!img) {
    if (images.size > 12) images.delete(images.keys().next().value)
    img = new Image()
    img.decoding = 'async'
    img.src = url
    images.set(url, img)
  }
  if (!(img.complete && img.naturalWidth)) img.addEventListener('load', onReady, { once: true })
  return img
}

function tileSize(size, W, H, natW, natH, isImage) {
  if (size === 'cover' || size === 'contain') {
    if (!isImage) return [W, H]
    const s = (size === 'cover' ? Math.max : Math.min)(W / natW, H / natH)
    return [natW * s, natH * s]
  }
  const [a = 'auto', b = 'auto'] = size.split(/\s+/)
  const len = (v, room) => (v === 'auto' ? null : v.endsWith('%') ? (parseFloat(v) / 100) * room : parseFloat(v))
  let tw = len(a, W), th = len(b, H)
  if (tw == null && th == null) return isImage ? [natW, natH] : [W, H]
  if (tw == null) tw = isImage ? (th * natW) / natH : W
  if (th == null) th = isImage ? (tw * natH) / natW : H
  return [tw, th]
}

/** Paint a background (computed style `cs`, in its own CSS px box, origin
 *  top-left) into ctx, whose transform maps those units to the texture. */
function paintCssBackground(ctx, cs, W, H, dpr, onReady) {
  const base = rgba(cs.backgroundColor)
  if (base[3] > 0) { ctx.fillStyle = css(base); ctx.fillRect(0, 0, W, H) }
  if (cs.backgroundImage === 'none') return
  const layers = splitTop(cs.backgroundImage)
  const sizes = splitTop(cs.backgroundSize)
  const positions = splitTop(cs.backgroundPosition)
  const repeats = splitTop(cs.backgroundRepeat)
  for (let i = layers.length - 1; i >= 0; i--) {
    const src = layers[i]
    const url = /^url\(\s*["']?(.*?)["']?\s*\)$/.exec(src)
    let img = null
    if (url) {
      img = cachedImage(url[1], onReady)
      if (!(img.complete && img.naturalWidth)) continue
    } else if (!/gradient\(/.test(src)) continue
    const [tw, th] = tileSize(sizes[i % sizes.length] || 'auto', W, H, img?.naturalWidth || 0, img?.naturalHeight || 0, !!img)
    if (!(tw > 0 && th > 0)) continue
    const [px, py] = (positions[i % positions.length] || '0% 0%').split(/\s+/)
    const ox = posValue(px, W - tw), oy = posValue(py ?? 'center', H - th)
    let rep = (repeats[i % repeats.length] || 'repeat').split(/\s+/)
    if (rep[0] === 'repeat-x') rep = ['repeat', 'no-repeat']
    else if (rep[0] === 'repeat-y') rep = ['no-repeat', 'repeat']
    else if (rep.length === 1) rep = [rep[0], rep[0]]
    const rx = rep[0] !== 'no-repeat' && tw < W, ry = rep[1] !== 'no-repeat' && th < H
    const drawTile = c => (img ? c.drawImage(img, 0, 0, tw, th) : fillGradient(c, src, tw, th))
    if (!rx && !ry) {
      ctx.save(); ctx.translate(ox, oy); drawTile(ctx); ctx.restore()
      continue
    }
    const tile = document.createElement('canvas')
    tile.width = Math.max(1, Math.round(tw * dpr))
    tile.height = Math.max(1, Math.round(th * dpr))
    const tc = tile.getContext('2d')
    tc.scale(tile.width / tw, tile.height / th)
    drawTile(tc)
    const pattern = ctx.createPattern(tile, rx && ry ? 'repeat' : rx ? 'repeat-x' : 'repeat-y')
    pattern.setTransform(new DOMMatrix().translate(ox, oy).scale(tw / tile.width, th / tile.height))
    ctx.fillStyle = pattern
    ctx.fillRect(0, 0, W, H)
  }
}


// ---------------------------------------------------------------- what's behind

const intersects = (a, b) => a.right > b.left && a.left < b.right && a.bottom > b.top && a.top < b.bottom
const covers = (a, b) => a.left <= b.left && a.top <= b.top && a.right >= b.right && a.bottom >= b.bottom
const frosted = cs => (cs.backdropFilter || cs.webkitBackdropFilter || 'none') !== 'none'
const blurOf = cs => parseFloat((/blur\(([\d.]+)px\)/.exec(cs.backdropFilter || cs.webkitBackdropFilter || '') || [])[1]) || 0
let frostCanvas = null
function zOf(n) {
  if (n.nodeType !== 1) return 0
  const cs = getComputedStyle(n)
  if (cs.position === 'static') return 0
  const z = parseInt(cs.zIndex, 10)
  return Number.isNaN(z) ? 0 : z
}
function radii(cs, w, h) {
  const one = v => {
    const n = parseFloat(v) || 0
    return Math.min(String(v).trim().endsWith('%') ? (n / 100) * Math.min(w, h) : n, w / 2, h / 2)
  }
  return [one(cs.borderTopLeftRadius), one(cs.borderTopRightRadius), one(cs.borderBottomRightRadius), one(cs.borderBottomLeftRadius)]
}
function clipTo(ctx, r, cs, s = 1) {
  const rr = radii(cs, r.width / s, r.height / s).map(v => v * s)
  ctx.beginPath()
  if (ctx.roundRect && rr.some(v => v > 0)) ctx.roundRect(r.left, r.top, r.width, r.height, rr)
  else ctx.rect(r.left, r.top, r.width, r.height)
  ctx.clip()
}

let range = null

/**
 * Paint what is behind `el` over `region` (screen px: left, top, right,
 * bottom, width, height) into ctx, whose transform maps screen px to the
 * texture at `k` texture px per screen px. Returns what the picture depends
 * on: the scroll containers whose content it shows, and whether it depends on
 * where `el` is at all (anything but one flat colour).
 */
export function paintBehind(ctx, el, region, k, onReady, page) {
  // positional: the picture depends on where el is; outside: some of that
  // comes from beyond the scroller el moves in (so its scrolling stales it)
  const dep = { scrollers: new Set(), positional: false, outside: false, outsideNodes: new Map(), start: null }
  let own = el.parentElement
  while (own && !/(auto|scroll)/.test(getComputedStyle(own).overflowX + getComputedStyle(own).overflowY)) own = own.parentElement
  // flat: a plain colour, which only matters for how much of the region it covers
  const at = (n, flat = false) => {
    dep.positional = true
    if (own && own.contains(n)) return
    dep.outside = true
    dep.outsideNodes.set(n, (dep.outsideNodes.get(n) ?? true) && flat)
  }
  let nodes = 700
  let words = 500
  range ||= document.createRange()
  const kx = ctx.canvas.width / region.width, ky = ctx.canvas.height / region.height

  // A backdrop-filter blur (the scroll edges' stacked blurs, frosted plates):
  // what is painted so far under it is blurred — shrunk and smoothly grown
  // back, which reads as the same blur and works everywhere.
  function frost(r, radius) {
    const cv = ctx.canvas
    const x0 = Math.max(0, Math.floor((r.left - region.left) * kx)), y0 = Math.max(0, Math.floor((r.top - region.top) * ky))
    const x1 = Math.min(cv.width, Math.ceil((r.right - region.left) * kx)), y1 = Math.min(cv.height, Math.ceil((r.bottom - region.top) * ky))
    const w = x1 - x0, h = y1 - y0
    const f = (radius * kx) / 2
    if (w < 2 || h < 2 || f < 1.5) return
    const sw = Math.max(1, Math.round(w / f)), sh = Math.max(1, Math.round(h / f))
    frostCanvas ||= document.createElement('canvas')
    if (frostCanvas.width < sw) frostCanvas.width = sw
    if (frostCanvas.height < sh) frostCanvas.height = sh
    const fc = frostCanvas.getContext('2d')
    fc.imageSmoothingEnabled = true
    fc.imageSmoothingQuality = 'high'
    fc.clearRect(0, 0, sw, sh)
    fc.drawImage(cv, x0, y0, w, h, 0, 0, sw, sh)
    ctx.save()
    ctx.setTransform(1, 0, 0, 1, 0, 0)
    ctx.globalAlpha = 1
    ctx.imageSmoothingEnabled = true
    ctx.imageSmoothingQuality = 'high'
    ctx.drawImage(frostCanvas, 0, 0, sw, sh, x0, y0, w, h)
    ctx.restore()
  }

  function paintBox(n, cs, r) {
    const img = cs.backgroundImage !== 'none'
    const col = rgba(cs.backgroundColor)
    if (!img && !(col[3] > 0)) return
    if (!intersects(r, region)) return
    if (img || !covers(r, region)) at(n, !img)
    const W = n.offsetWidth || r.width, H = n.offsetHeight || r.height
    const sx = r.width / W, sy = r.height / H
    ctx.save()
    clipTo(ctx, r, cs, sx)
    ctx.translate(r.left, r.top)
    ctx.scale(sx, sy)
    paintCssBackground(ctx, cs, W, H, k * sx, onReady)
    ctx.restore()
  }
  function paintUnder(A) {
    const u = getComputedStyle(A, '::before')
    if (u.content === 'none' || (u.position !== 'absolute' && u.position !== 'fixed') || !(parseInt(u.zIndex, 10) < 0)) return
    const r = A.getBoundingClientRect()
    const cs = getComputedStyle(A)
    const s = r.width / (A.offsetWidth || r.width)
    const w = parseFloat(u.width), h = parseFloat(u.height)
    if (!(w > 0 && h > 0)) return
    const x = r.left + ((parseFloat(cs.borderLeftWidth) || 0) + (parseFloat(u.left) || 0)) * s
    const y = r.top + ((parseFloat(cs.borderTopWidth) || 0) + (parseFloat(u.top) || 0)) * s
    at(A)
    ctx.save()
    ctx.globalAlpha *= parseFloat(u.opacity) || 0
    ctx.translate(x, y)
    ctx.scale(s, s)
    paintCssBackground(ctx, u, w, h, k * s, onReady)
    ctx.restore()
  }
  function paintMedia(n, cs, r) {
    let w, h
    if (n.tagName === 'IMG') {
      if (!n.complete || !n.naturalWidth) { n.addEventListener('load', onReady, { once: true }); return }
      w = n.naturalWidth; h = n.naturalHeight
    } else if (n.tagName === 'VIDEO') {
      if (n.readyState < 2) { n.addEventListener('loadeddata', onReady, { once: true }); return }
      w = n.videoWidth; h = n.videoHeight
    } else {
      w = n.width; h = n.height
    }
    if (!(w > 0 && h > 0)) return
    at(n)
    const fit = n.tagName === 'CANVAS' ? 'fill' : cs.objectFit || 'fill'
    let dw = r.width, dh = r.height
    if (fit !== 'fill') {
      const s = fit === 'cover' ? Math.max(r.width / w, r.height / h)
        : fit === 'none' ? 1
        : fit === 'scale-down' ? Math.min(1, r.width / w, r.height / h)
        : Math.min(r.width / w, r.height / h)
      dw = w * s; dh = h * s
    }
    const [px, py] = (cs.objectPosition || '50% 50%').split(/\s+/)
    ctx.save()
    clipTo(ctx, r, cs, r.width / (n.offsetWidth || r.width))
    try { ctx.drawImage(n, r.left + posValue(px, r.width - dw), r.top + posValue(py ?? '50%', r.height - dh), dw, dh) } catch {}
    ctx.restore()
  }
  function paintText(t) {
    const s = t.data
    if (!s || !s.trim()) return
    const p = t.parentElement
    if (!p) return
    range.selectNodeContents(t)
    if (!intersects(range.getBoundingClientRect(), region)) return
    const cs = getComputedStyle(p)
    const col = rgba(cs.color)
    if (!(col[3] > 0)) return
    at(p)
    ctx.save()
    ctx.font = `${cs.fontStyle} ${cs.fontWeight} ${cs.fontSize} ${cs.fontFamily}`
    ctx.fillStyle = css(col)
    ctx.textBaseline = 'middle'
    const re = /\S+/g
    let m
    while ((m = re.exec(s)) && words-- > 0) {
      range.setStart(t, m.index)
      range.setEnd(t, m.index + m[0].length)
      const q = range.getClientRects()[0]
      if (q && intersects(q, region)) ctx.fillText(m[0], q.left, q.top + q.height / 2, q.width + 1)
    }
    ctx.restore()
  }
  function paintNode(n) {
    if (nodes-- <= 0) return
    if (n.nodeType === 3) { if (words > 0) paintText(n); return }
    if (n.nodeType !== 1) return
    if (n.classList.contains('lg-btn')) return
    if (n.dataset.lg && n.dataset.lg !== 'probe' && n !== el) return // another glass button: its content is over its own glass
    const tag = n.tagName
    if (tag === 'SCRIPT' || tag === 'STYLE' || tag === 'TEMPLATE' || tag === 'TEXTAREA' || tag === 'INPUT') return
    const cs = getComputedStyle(n)
    if (cs.display === 'none') return
    const op = parseFloat(cs.opacity)
    if (!(op > 0)) return
    const r = n.getBoundingClientRect()
    const clips = cs.overflowX !== 'visible' || cs.overflowY !== 'visible'
    // what doesn't reach the region (and keeps its content to itself) is skipped
    if (!intersects(r, region) && (clips || cs.position === 'static' || !n.firstChild)) return
    if (/(auto|scroll)/.test(cs.overflowX + cs.overflowY)) dep.scrollers.add(n)
    ctx.save()
    ctx.globalAlpha *= op
    if (cs.visibility !== 'hidden' && cs.display !== 'contents') {
      const blur = blurOf(cs)
      if (blur > 0 && intersects(r, region)) { at(n); frost(r, blur) }
      paintBox(n, cs, r)
      if (tag === 'IMG' || tag === 'VIDEO' || tag === 'CANVAS') paintMedia(n, cs, r)
    }
    if (tag !== 'svg' && tag !== 'IMG' && tag !== 'VIDEO' && tag !== 'CANVAS') {
      if (clips) clipTo(ctx, r, cs, r.width / (n.offsetWidth || r.width))
      for (const c of n.childNodes) paintNode(c)
    }
    ctx.restore()
  }

  const chain = []
  for (let a = el.parentElement; a; a = a.parentElement) chain.push(a)
  // Painting starts at the nearest ancestor nothing shows through: opaque, or
  // frosted (whatever is behind a frosted surface reads as its own colour).
  let start = chain.length - 1
  for (let i = 0; i < chain.length; i++) {
    const cs = getComputedStyle(chain[i])
    if (rgba(cs.backgroundColor)[3] >= 0.999 || frosted(cs)) { start = i; break }
  }
  dep.start = chain[start] || null
  ctx.fillStyle = css(page)
  ctx.fillRect(region.left, region.top, region.width, region.height)
  for (let i = start; i >= 0; i--) {
    const A = chain[i]
    const child = i > 0 ? chain[i - 1] : el
    const cs = getComputedStyle(A)
    ctx.save()
    paintBox(A, cs, A.getBoundingClientRect())
    paintUnder(A)
    const zc = zOf(child)
    for (const c of A.childNodes) {
      if (c === child) break
      if (c.nodeType === 1 && zOf(c) > zc) continue
      paintNode(c)
    }
    ctx.restore()
  }
  return dep
}

export { rgba }
