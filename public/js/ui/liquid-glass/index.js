// The real Liquid Glass — the liquid-glass-studio WebGL2 engine (renderer.js +
// shaders.js) driving the app's floating buttons. A canvas sits behind a group
// of controls and refracts what is behind them through rounded-rect shapes
// placed at each control's rect, with the project's default look (refraction,
// dispersion, Fresnel, glare) and, like the project, no tint: the glass has no
// fill of its own. The controls' CSS material is turned off (data-lg-gl) so
// only the shader shows. Falls back silently to the CSS glass when WebGL2 or
// the float-buffer extension is missing.

import { MultiPassRenderer, gaussianKernel, textureFromSource, updateTexture } from './renderer.js'
import * as S from './shaders.js'
import { reducedMotion, storage } from '../dom.js'

// The demo's canvas is its whole window, and its pixel-based controls are
// tuned against that; ours covers only a bar of buttons, so the shader takes
// its units against this reference window height (css px) instead.
const REF_VIEW_H = 900
// At its rim the glass bends in what lies up to ~70px away; the canvas (and
// the backdrop it refracts) reach this far past the host so that is real
// backdrop, not a smear of the texture's edge. Transparent outside the shapes.
const MARGIN = 72

// The demo's default controls (src/Controls.tsx), with the /100 and deg→rad
// transforms applied as in src/App.tsx.
const PARAMS = {
  blurRadius: 1,
  tint: [1, 1, 1, 0],
  refThickness: 20,
  refDistance: 0.05,
  refFactor: 1.4,
  refDispersion: 7,
  refFresnelRange: 30,
  refFresnelHardness: 0.2,
  refFresnelFactor: 0.2,
  glareRange: 30,
  glareHardness: 0.2,
  glareConvergence: 0.5,
  glareOppositeFactor: 0.8,
  glareFactor: 0.9,
  glareAngle: (-45 * Math.PI) / 180,
  blurEdge: 1
}

let supportCache = null
export function liquidGlassSupported() {
  if (supportCache !== null) return supportCache
  try {
    const c = document.createElement('canvas')
    const gl = c.getContext('webgl2')
    supportCache = !!(gl && gl.getExtension('EXT_color_buffer_float'))
  } catch {
    supportCache = false
  }
  return supportCache
}

const root = document.documentElement

/** Whether the WebGL glass should run now: supported, not turned off, and not
 *  overridden by the accessibility / perf fallbacks that drop to a flat
 *  surface (in which case the CSS glass — itself flat there — stays). */
export function liquidGlassActive() {
  if (!liquidGlassSupported()) return false
  if (storage('ui:glass-engine') === 'css') return false
  if (root.getAttribute('data-glass') === 'solid' || storage('ui:glass-auto') === 'solid') return false
  try {
    if (matchMedia('(prefers-reduced-transparency: reduce)').matches) return false
    if (matchMedia('(prefers-contrast: more)').matches) return false
  } catch {}
  return true
}

// ---------------------------------------------------------------- the backdrop
// The glass must refract exactly what is behind it, or the difference reads as
// a fill. So the texture is the backdrop element's own computed CSS background
// (wallpaper colour + doodle, a preset's gradients, a photo under its wash),
// painted layer by layer the way the browser paints it.

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

// ---------------------------------------------------------------- a surface

/**
 * Attach the WebGL glass to a host element, drawing shapes for `shapeEls()`
 * (the controls to render as glass). Returns a controller, or null when
 * unsupported. The CSS (liquid.css) keeps those controls free of their own
 * material while the host carries data-lg-gl.
 */
export function attachLiquidGlass(host, shapeEls, { maxShapes = S.MAX_SHAPES } = {}) {
  if (!liquidGlassSupported()) return null

  // The canvas reaches MARGIN past the host for the refraction, but what it
  // draws lies inside the host; a host-sized clip keeps the overflow out of
  // layout (no scrollable area grows, nothing can be scrolled by focus).
  const clip = document.createElement('div')
  clip.className = 'lg-gl-clip'
  clip.setAttribute('aria-hidden', 'true')
  const canvas = document.createElement('canvas')
  canvas.className = 'lg-gl'
  clip.append(canvas)
  host.insertBefore(clip, host.firstChild)
  host.dataset.lgGl = ''

  let renderer
  try {
    renderer = new MultiPassRenderer(canvas, [
      { name: 'bgPass', shader: { vertex: S.VERTEX, fragment: S.BG } },
      { name: 'vBlurPass', shader: { vertex: S.VERTEX, fragment: S.VBLUR }, inputs: { u_prevPassTexture: 'bgPass' } },
      { name: 'hBlurPass', shader: { vertex: S.VERTEX, fragment: S.HBLUR }, inputs: { u_prevPassTexture: 'vBlurPass' } },
      { name: 'mainPass', shader: { vertex: S.VERTEX, fragment: S.MAIN }, inputs: { u_blurredBg: 'hBlurPass', u_bg: 'bgPass' }, outputToScreen: true }
    ])
  } catch {
    clip.remove()
    delete host.dataset.lgGl
    return null
  }
  const gl = renderer.gl
  const blurWeights = gaussianKernel(PARAMS.blurRadius)

  const bgCanvas = document.createElement('canvas')
  const bgCtx = bgCanvas.getContext('2d')
  let bgTex = null

  // What is behind the host: the conversation's backdrop layer (it carries the
  // wallpaper when no backdrop is chosen), over the page it sits on.
  const thread = host.closest('.thread')
  const bdEl = thread?.querySelector(':scope > .thread-backdrop') || null

  let W = 0, H = 0, dpr = 1
  const box = new Array(maxShapes * 4).fill(0)
  const rad = new Array(maxShapes).fill(0)
  let count = 0
  let lastKey = ''
  let raf = 0
  let destroyed = false

  function paintTexture(hostBox, sx, sy) {
    bgCtx.setTransform(1, 0, 0, 1, 0, 0)
    bgCtx.globalAlpha = 1
    const page = thread ? rgba(getComputedStyle(thread).backgroundColor) : [0, 0, 0, 0]
    bgCtx.fillStyle = page[3] > 0 ? css(page) : getComputedStyle(root).getPropertyValue('--bg').trim() || '#fff'
    bgCtx.fillRect(0, 0, W, H)
    if (bdEl) {
      const bd = bdEl.getBoundingClientRect()
      const bw = bdEl.offsetWidth, bh = bdEl.offsetHeight
      const opacity = parseFloat(getComputedStyle(bdEl).opacity)
      if (bw && bh && opacity > 0) {
        bgCtx.globalAlpha = opacity
        bgCtx.setTransform(dpr, 0, 0, dpr, ((bd.left - hostBox.left) / sx + MARGIN) * dpr, ((bd.top - hostBox.top) / sy + MARGIN) * dpr)
        paintCssBackground(bgCtx, getComputedStyle(bdEl), bw, bh, dpr, invalidate)
        bgCtx.setTransform(1, 0, 0, 1, 0, 0)
        bgCtx.globalAlpha = 1
      }
    }
    // The host's own underlay, under the glass too (the composer fades the
    // messages out beneath itself with a ::before at z-index -1).
    const under = getComputedStyle(host, '::before')
    if (under.content !== 'none' && under.position === 'absolute' && parseInt(under.zIndex, 10) < 0) {
      const hs = getComputedStyle(host)
      const w = parseFloat(under.width), h = parseFloat(under.height)
      const x = (parseFloat(hs.borderLeftWidth) || 0) + (parseFloat(under.left) || 0) + MARGIN
      const y = (parseFloat(hs.borderTopWidth) || 0) + (parseFloat(under.top) || 0) + MARGIN
      if (w > 0 && h > 0) {
        bgCtx.globalAlpha = parseFloat(under.opacity) || 0
        bgCtx.setTransform(dpr, 0, 0, dpr, x * dpr, y * dpr)
        paintCssBackground(bgCtx, under, w, h, dpr, invalidate)
        bgCtx.setTransform(1, 0, 0, 1, 0, 0)
        bgCtx.globalAlpha = 1
      }
    }
    try {
      if (!bgTex) ({ texture: bgTex } = textureFromSource(gl, bgCanvas, W, H))
      else updateTexture(gl, bgTex, bgCanvas)
    } catch {}
  }

  function layout() {
    const hostBox = host.getBoundingClientRect()
    const cssW = host.offsetWidth
    const cssH = host.offsetHeight
    if (!hostBox.width || !hostBox.height || !cssW || !cssH) { count = 0; return false }
    // Everything is measured in the host's own layout px, so a transform on an
    // ancestor (the app shrinking behind a sheet, a column sliding) can't skew
    // the shapes: the canvas moves and scales with the host.
    const sx = hostBox.width / cssW
    const sy = hostBox.height / cssH
    dpr = Math.min(2, window.devicePixelRatio || 1)
    const nW = Math.max(1, Math.round((cssW + 2 * MARGIN) * dpr))
    const nH = Math.max(1, Math.round((cssH + 2 * MARGIN) * dpr))
    if (nW !== W || nH !== H) {
      W = nW; H = nH
      renderer.resize(W, H)
      bgCanvas.width = W; bgCanvas.height = H
    }
    // the clip covers the host's border box; the canvas, the margin past it
    const hs = getComputedStyle(host)
    clip.style.left = `${-(parseFloat(hs.borderLeftWidth) || 0)}px`
    clip.style.top = `${-(parseFloat(hs.borderTopWidth) || 0)}px`
    clip.style.width = `${cssW}px`
    clip.style.height = `${cssH}px`
    canvas.style.left = `${-MARGIN}px`
    canvas.style.top = `${-MARGIN}px`
    canvas.style.width = `${cssW + 2 * MARGIN}px`
    canvas.style.height = `${cssH + 2 * MARGIN}px`
    // shapes: each control rect → centre/half in physical px, y-up (fragCoord space)
    count = 0
    for (const el of shapeEls()) {
      if (!el || el.hidden || count >= maxShapes) continue
      const r = el.getBoundingClientRect()
      if (!r.width || !r.height) continue
      const w = r.width / sx, h = r.height / sy
      const cx = ((r.left - hostBox.left) / sx + w / 2 + MARGIN) * dpr
      const cy = H - ((r.top - hostBox.top) / sy + h / 2 + MARGIN) * dpr // flip to y-up
      const radius = parseFloat(getComputedStyle(el).borderTopLeftRadius) || Math.min(w, h) / 2
      box[count * 4] = cx
      box[count * 4 + 1] = cy
      box[count * 4 + 2] = (w / 2) * dpr
      box[count * 4 + 3] = (h / 2) * dpr
      rad[count] = Math.min(radius, Math.min(w, h) / 2) * dpr
      count++
    }
    if (count) paintTexture(hostBox, sx, sy)
    return count > 0
  }

  function draw() {
    if (destroyed) return
    if (!count) { canvas.style.opacity = '0'; return }
    canvas.style.opacity = '1'
    renderer.setUniforms({
      u_resolution: [W, H], u_dpr: dpr, u_viewH: REF_VIEW_H * dpr,
      u_blurRadius: PARAMS.blurRadius, u_blurWeights: blurWeights,
      u_shapeCount: count, u_shapeBox: box, u_shapeR: rad
    })
    renderer.render({
      bgPass: { u_bgTexture: bgTex },
      mainPass: {
        u_tint: PARAMS.tint,
        u_refThickness: PARAMS.refThickness, u_refDistance: PARAMS.refDistance, u_refFactor: PARAMS.refFactor, u_refDispersion: PARAMS.refDispersion,
        u_refFresnelRange: PARAMS.refFresnelRange, u_refFresnelHardness: PARAMS.refFresnelHardness, u_refFresnelFactor: PARAMS.refFresnelFactor,
        u_glareRange: PARAMS.glareRange, u_glareHardness: PARAMS.glareHardness, u_glareConvergence: PARAMS.glareConvergence,
        u_glareOppositeFactor: PARAMS.glareOppositeFactor, u_glareFactor: PARAMS.glareFactor, u_glareAngle: PARAMS.glareAngle, u_blurEdge: PARAMS.blurEdge
      }
    })
  }

  function update() {
    if (destroyed) return
    layout()
    draw()
  }

  const rectKey = el => {
    if (!el || el.hidden) return '-'
    const r = el.getBoundingClientRect()
    return `${Math.round(r.left)},${Math.round(r.top)},${Math.round(r.width)},${Math.round(r.height)}`
  }
  // Follow transitions (buttons appearing, the field growing) for a short
  // while after any change, then settle — no permanent RAF.
  let settleUntil = 0
  function pulse(ms = 520) {
    settleUntil = Math.max(settleUntil, performance.now() + (reducedMotion() ? 0 : ms))
    if (raf) return
    const tick = () => {
      raf = 0
      if (destroyed) return
      const key = `${rectKey(host)}:${shapeEls().map(rectKey).join('|')}`
      if (key !== lastKey) { lastKey = key; update() }
      if (performance.now() < settleUntil) raf = requestAnimationFrame(tick)
    }
    raf = requestAnimationFrame(tick)
  }
  // What's behind changed (backdrop, theme, an image loaded): repaint even
  // though no button moved.
  function invalidate() {
    lastKey = ''
    pulse()
  }

  const ro = 'ResizeObserver' in window ? new ResizeObserver(() => pulse()) : null
  ro?.observe(host)
  // A button shown, hidden, docked or switched on (ink) without moving.
  const so = new MutationObserver(() => pulse())
  so.observe(host, { subtree: true, attributes: true, attributeFilter: ['class', 'hidden'] })
  const co = new MutationObserver(() => pulse())
  co.observe(host, { childList: true })
  const mo = new MutationObserver(invalidate)
  if (bdEl) mo.observe(bdEl, { attributes: true, attributeFilter: ['data-backdrop', 'style', 'class'] })
  if (thread) mo.observe(thread, { attributes: true, attributeFilter: ['class'] })
  mo.observe(root, { attributes: true, attributeFilter: ['data-theme'] })
  bdEl?.addEventListener('transitionend', invalidate)
  const scheme = matchMedia('(prefers-color-scheme: dark)')
  scheme.addEventListener?.('change', invalidate)
  const onWin = () => pulse()
  window.addEventListener('resize', onWin)

  update()

  return {
    canvas,
    refresh: pulse,
    invalidate,
    destroy() {
      destroyed = true
      cancelAnimationFrame(raf)
      ro?.disconnect()
      so.disconnect()
      co.disconnect()
      mo.disconnect()
      bdEl?.removeEventListener('transitionend', invalidate)
      scheme.removeEventListener?.('change', invalidate)
      window.removeEventListener('resize', onWin)
      try { renderer.dispose() } catch {}
      try { gl.getExtension('WEBGL_lose_context')?.loseContext() } catch {}
      clip.remove()
      delete host.dataset.lgGl
    }
  }
}
