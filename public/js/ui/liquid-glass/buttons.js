// Every button in the app, in one Liquid Glass.
//
// Finds each button wherever it appears (any screen, sheet, menu or overlay,
// now or later), reads the fill its own CSS gives it to choose its tone
// (tone.js: clear, a light dim over media, or tinted for a filled action), and
// draws it as the liquid-glass-studio glass: a small canvas behind the
// button's content, painted by one shared WebGL context (engine.js) from
// exactly what is behind the button (paint.js). The edge light follows the
// phone's tilt (tilt.js). Without WebGL (or with Settings › Real-time glass
// off) the same buttons get one CSS glass material instead; with Reduce
// Transparency, high contrast or the solid fallback, a solid surface.
//
// A button inside another (the + inside the message field, a capsule's items,
// a segmented control's segments) is part of that glass: it has none of its
// own unless it's a filled action, which gets its own tinted glass on top.

import { storage } from '../dom.js'
import { glassEngine, onEngine, uploadBackdrop, dropTexture, renderGlass } from './engine.js'
import { paintBehind, rgba } from './paint.js'
import { glassTone } from './tone.js'
import { subscribeTilt } from './tilt.js'

// The controls that are buttons. Tappable things that are content (chat rows,
// cards, photos, tiles, avatars, settings rows, switches, swatches, plain
// text links) are not here and keep their own look.
export const BUTTONS = [
  '.glass-btn', '.bar-item', '.bar-group.capsule', '.page-rail', '.composer .field', '.search-pill', '.seg',
  '.btn', '.solid-press', '.auth-tab', '.prompt-btn', '.jump-pill',
  '.filter-tab', '.list-requests', '.person-action', '.person-dismiss', '.list-moments', '.list-insights', '.page-item',
  '.mo-dots', '.mo-act', '.mo-pill', '.mo-compose', '.mo-message', '.mo-sound', '.mo-alt',
  '.me-tool', '.me-cancel', '.me-post', '.me-chip', '.me-card-btn', '.me-card-x',
  '.call-btn', '.call-icon-btn', '.note-reply-send'
].join(', ')
const NOT = '.thread-title, .switch, .lg-btn'

// The demo's default glass (src/Controls.tsx, with App.tsx's transforms).
const LOOK = {
  u_refThickness: 20, u_refDistance: 0.05, u_refFactor: 1.4, u_refDispersion: 7,
  u_refFresnelRange: 30, u_refFresnelHardness: 0.2, u_refFresnelFactor: 0.2,
  u_glareRange: 30, u_glareHardness: 0.2, u_glareConvergence: 0.5, u_glareOppositeFactor: 0.8, u_glareFactor: 0.9,
  u_blurEdge: 1
}
const GLARE = (-45 * Math.PI) / 180
// The demo's canvas is its whole window and its pixel-based controls are
// tuned against that; the shader takes its units against this window height.
const REF_VIEW_H = 900
// The demo's soft shadow (src/Controls.tsx: shadowExpand 25, shadowFactor 15, 10px down).
const SHADOW = { expand: 25, factor: 0.15, drop: 10 }
// The demo's glass is tuned in pixels for its 200px shape; a button is that
// same glass made smaller, by this factor.
const sizeOf = (W, H) => Math.min(1, Math.max(0.2, Math.min(W, H) / 200))
// css px the canvas reaches past the button (its rim's soft edge and its
// shadow), and the backdrop painted past it (the rim bends in what lies
// beyond the button: up to ~71px at the demo's size).
const bleedOf = s => Math.ceil(SHADOW.drop * s + 3 * SHADOW.expand * s + 3)
const marginOf = s => bleedOf(s) + Math.ceil(71 * s) + 4
const THROTTLE = 32 // ms between repaints of one button while things move under it
const THROTTLE_SCROLL = 50 // … when it's content scrolling under it (mostly under a scroll edge's fade)

const root = document.documentElement
const entries = new Map() // element → entry
const queue = new Set()
let mode = '' // 'gl' | 'css' | 'solid'
let raf = 0
let fullCheck = false
let tilt = 0
let untilt = null
let scratch = null
let page = [255, 255, 255, 1]

const mq = q => { try { return matchMedia(q).matches } catch { return false } }
function currentMode() {
  if (root.getAttribute('data-glass') === 'solid' || storage('ui:glass-auto') === 'solid' ||
      mq('(prefers-reduced-transparency: reduce)') || mq('(prefers-contrast: more)')) return 'solid'
  if (storage('ui:glass-engine') !== 'css' && glassEngine()) return 'gl'
  return 'css'
}
function readPage() {
  const c = rgba(getComputedStyle(document.body).backgroundColor)
  page = c[3] > 0 ? c : rgba(getComputedStyle(root).getPropertyValue('--bg').trim() || '#fff')
}

// ---------------------------------------------------------------- entries

function consider(el) {
  if (entries.has(el) || !el.isConnected || !el.matches(BUTTONS) || el.matches(NOT)) return
  const e = { el, visible: false, tone: 'clear', tint: [1, 1, 1, 0], inner: false, canvas: null, ctx: null, tex: null, drawn: false, key: '', dep: null, region: null, last: 0 }
  entries.set(el, e)
  io.observe(el)
  ro.observe(el)
  fresh.push(e)
}
// New buttons have their tone read together, once the batch they came in is done.
let fresh = []
function settleFresh() {
  if (!fresh.length) return
  const list = fresh.filter(e => entries.has(e.el))
  fresh = []
  if (list.length) classify(...list)
}
function forget(e) {
  entries.delete(e.el)
  queue.delete(e)
  io.unobserve(e.el)
  ro.unobserve(e.el)
  dropTexture(glassEngine(), e.tex)
  e.canvas?.remove()
  delete e.el.dataset.lg
  delete e.el.dataset.lgTone
  delete e.el.dataset.lgPos
}
const isInner = el => {
  const outer = el.parentElement?.closest(BUTTONS)
  return Boolean(outer && !outer.matches(NOT))
}

/** Read the fill each button's own CSS gives it (the glass rules off), and
 *  so its tone; then put the glass back on in the current mode. All at once:
 *  one style recalculation for the lot, not one each. */
function classify(...list) {
  for (const e of list) e.el.dataset.lg = 'probe'
  const read = list.map(e => {
    const cs = getComputedStyle(e.el)
    return [rgba(cs.backgroundColor), cs.position === 'static']
  })
  list.forEach((e, i) => {
    const [fill, isStatic] = read[i]
    const t = glassTone(fill, page)
    const changed = t.tone !== e.tone || String(t.tint) !== String(e.tint)
    e.tone = t.tone
    e.tint = t.tint
    e.inner = isInner(e.el)
    if (isStatic) e.el.dataset.lgPos = ''
    else delete e.el.dataset.lgPos
    apply(e)
    if (changed || !e.drawn) invalidate(e)
  })
}
const ownGlass = e => !(e.inner && e.tone === 'clear')
function apply(e) {
  const el = e.el
  el.dataset.lgTone = e.tone
  if (!ownGlass(e)) el.dataset.lg = 'inner'
  else if (mode === 'gl') el.dataset.lg = e.drawn ? 'gl' : 'wait' // its own look until its glass is drawn
  else el.dataset.lg = mode
}

// ---------------------------------------------------------------- drawing

function invalidate(e, gap = THROTTLE) {
  if (!e) return
  e.gap = queue.has(e) ? Math.min(e.gap || gap, gap) : gap
  queue.add(e)
  schedule()
}
function schedule() {
  if (!raf) raf = requestAnimationFrame(run)
}
function run() {
  raf = 0
  if (fullCheck) check()
  const t0 = performance.now()
  const later = []
  for (const e of queue) {
    queue.delete(e)
    if (performance.now() - t0 > 8) { later.push(e); continue }
    if (t0 - e.last < (e.gap || THROTTLE) && e.drawn) { later.push(e); continue }
    update(e)
  }
  for (const e of later) queue.add(e)
  if (queue.size) schedule()
}

const stats = { paints: 0, draws: 0, paintMs: 0, drawMs: 0 }
function update(e) {
  const el = e.el
  if (!el.isConnected) return forget(e)
  if (mode !== 'gl' || !ownGlass(e)) return
  if (!e.visible) return // drawn when it comes into view
  const eng = glassEngine()
  if (!eng) return setMode()
  if (!e.canvas || e.canvas.parentElement !== el) {
    // The button's glass: a canvas reaching past it (its rim and shadow), in a
    // button-sized holder whose layout containment keeps that overhang out of
    // every scrollable area (it is painted, never scrolled to).
    if (!e.canvas) {
      e.canvas = Object.assign(document.createElement('span'), { className: 'lg-btn' })
      e.canvas.setAttribute('aria-hidden', 'true')
      e.pane = Object.assign(document.createElement('canvas'), { className: 'lg-canvas' })
      e.canvas.append(e.pane)
      e.ctx = e.pane.getContext('2d')
    }
    el.insertBefore(e.canvas, el.firstChild)
  }
  const t0 = performance.now()
  if (!paint(e, eng)) return
  const t1 = performance.now()
  draw(e, eng)
  const t2 = performance.now()
  stats.paints++; stats.paintMs += t1 - t0
  e.paints = (e.paints || 0) + 1
  stats.draws++; stats.drawMs += t2 - t1
  e.last = t2
  if (!e.drawn) { e.drawn = true; apply(e) }
}

function paint(e, eng) {
  const el = e.el
  const W = el.offsetWidth, H = el.offsetHeight
  const r = el.getBoundingClientRect()
  if (!W || !H || !r.width || !r.height) return false
  const dpr = Math.min(2, window.devicePixelRatio || 1)
  const size = sizeOf(W, H), BLEED = bleedOf(size), MARGIN = marginOf(size)
  const sx = r.width / W, sy = r.height / H
  const cx = r.left + r.width / 2, cy = r.top + r.height / 2
  const hw = (W / 2 + MARGIN) * sx, hh = (H / 2 + MARGIN) * sy
  const region = { left: cx - hw, top: cy - hh, right: cx + hw, bottom: cy + hh, width: 2 * hw, height: 2 * hh }
  const texW = Math.round((W + 2 * MARGIN) * dpr), texH = Math.round((H + 2 * MARGIN) * dpr)
  scratch ||= document.createElement('canvas')
  if (scratch.width !== texW) scratch.width = texW
  if (scratch.height !== texH) scratch.height = texH
  const ctx = scratch.getContext('2d')
  const kx = texW / region.width, ky = texH / region.height
  ctx.setTransform(1, 0, 0, 1, 0, 0)
  ctx.globalAlpha = 1
  ctx.clearRect(0, 0, texW, texH)
  ctx.setTransform(kx, 0, 0, ky, -region.left * kx, -region.top * ky)
  try {
    e.dep = paintBehind(ctx, el, region, kx, () => invalidate(e), page)
  } catch {
    e.dep = { scrollers: new Set(), positional: true, start: null }
  }
  try {
    e.tex = uploadBackdrop(eng, e.tex, scratch)
  } catch {
    return false // a picture that can't be read back (cross-origin): keep the CSS look
  }
  const outW = Math.round((W + 2 * BLEED) * dpr), outH = Math.round((H + 2 * BLEED) * dpr)
  if (e.pane.width !== outW) e.pane.width = outW
  if (e.pane.height !== outH) e.pane.height = outH
  if (e.bleed !== BLEED) {
    e.pane.style.setProperty('inset', `-${BLEED}px`)
    e.pane.style.setProperty('width', `calc(100% + ${2 * BLEED}px)`)
    e.pane.style.setProperty('height', `calc(100% + ${2 * BLEED}px)`)
  }
  const radius = radiusOf(el, W, H)
  Object.assign(e, {
    texW, texH, outW, outH, dpr, region, size, bleed: BLEED, margin: MARGIN, room: roomOf(el, r),
    shape: [outW / 2, outH / 2, (W / 2) * dpr, (H / 2) * dpr],
    radius: radius * dpr
  })
  e.key = keyOf(e)
  return true
}
// Where what it shows from beyond its own scroller lies, seen from the button:
// a plain colour by the part of the region it covers, anything else by its
// place. Unchanged as it scrolls, nothing needs repainting.
function outsideKey(e) {
  if (!e.dep?.outsideNodes?.size || !e.region) return ''
  const r = e.el.getBoundingClientRect()
  const cx = r.left + r.width / 2, cy = r.top + r.height / 2
  const g = { left: cx - e.region.width / 2, top: cy - e.region.height / 2, right: cx + e.region.width / 2, bottom: cy + e.region.height / 2 }
  const out = []
  for (const [n, flat] of e.dep.outsideNodes) {
    const b = n.getBoundingClientRect()
    if (flat) {
      out.push([Math.max(b.left, g.left) - g.left, Math.max(b.top, g.top) - g.top, Math.min(b.right, g.right) - g.left, Math.min(b.bottom, g.bottom) - g.top].map(Math.round).join(','))
    } else out.push(`${Math.round(b.left - g.left)},${Math.round(b.top - g.top)}`)
  }
  return out.join('|')
}
// How far a shadow can reach before something clips it (a scrolling strip of
// tabs, a pane's edge): a shadow is never cut off flat, it shrinks to fit.
function roomOf(el, r) {
  const k = r.width / (el.offsetWidth || r.width) || 1
  let room = Infinity
  for (let a = el.parentElement; a && a !== document.body; a = a.parentElement) {
    const cs = getComputedStyle(a)
    if (cs.overflowX === 'visible' && cs.overflowY === 'visible') continue
    const b = a.getBoundingClientRect()
    room = Math.min(room, (r.left - b.left) / k, (b.right - r.right) / k, (r.top - b.top) / k, (b.bottom - r.bottom) / k)
    if (room <= 0) break
  }
  return Math.max(0, room)
}
// Liquid glass is always rounded: a button drawn square (or nearly) gets a
// capsule; a radius of its own (the multi-line field's) is kept.
function radiusOf(el, W, H) {
  const v = getComputedStyle(el).borderTopLeftRadius
  const n = parseFloat(v) || 0
  const own = v.trim().endsWith('%') ? (n / 100) * Math.min(W, H) : n
  return Math.min(own < 8 ? Infinity : own, W / 2, H / 2)
}
function draw(e, eng) {
  if (!e.tex || !e.ctx) return
  // The button is the demo's glass made smaller: its thickness, bend and
  // shadow shrink with it, and its Fresnel and glare bands (whose ranges enter
  // squared) by the square root.
  const s = e.size
  const k = Math.sqrt(s)
  renderGlass(eng, {
    tex: e.tex, texW: e.texW, texH: e.texH, outW: e.outW, outH: e.outH,
    pad: (e.margin - e.bleed) * e.dpr, shape: e.shape, radius: e.radius, target: e.ctx,
    uniforms: {
      ...LOOK,
      u_refThickness: LOOK.u_refThickness * s, u_refDistance: LOOK.u_refDistance * s,
      u_refFresnelRange: LOOK.u_refFresnelRange * k, u_glareRange: LOOK.u_glareRange * k,
      ...shadowFor(e),
      u_tint: e.tint, u_glareAngle: GLARE + tilt, u_dpr: e.dpr, u_viewH: REF_VIEW_H * e.dpr
    }
  })
}
function shadowFor(e) {
  const s = e.size
  // within the room before something clips it: its reach is ~3× expand plus the drop
  const fit = Math.min(1, e.room / (3 * SHADOW.expand * s + SHADOW.drop * s))
  return {
    // under the glass: the whole shadow (it stays inside the button)
    u_shadowExpand: SHADOW.expand * s, u_shadowFactor: SHADOW.factor, u_shadowOffset: [0, SHADOW.drop * s * e.dpr],
    // around it: only what fits before something clips it
    u_shadowOutExpand: Math.max(0.5, SHADOW.expand * s * fit),
    u_shadowOutFactor: fit < 0.15 ? 0 : SHADOW.factor,
    u_shadowOutOffset: [0, SHADOW.drop * s * fit * e.dpr]
  }
}
/** Only the light moved (tilt): redraw every visible glass, no repainting —
 *  at most 30 times a second, which is plenty for a light sliding round a rim. */
let lit = 0
let relightTimer = 0
function relight() {
  const eng = glassEngine()
  if (!eng || mode !== 'gl') return
  const now = performance.now()
  if (now - lit < 33) {
    clearTimeout(relightTimer)
    relightTimer = setTimeout(relight, 33 - (now - lit))
    return
  }
  lit = now
  for (const e of entries.values()) if (e.visible && e.drawn && ownGlass(e)) draw(e, eng)
}

// When does a button's picture go stale? When it changes size; and when
// something it shows from beyond its own scroller (a backdrop, a pane's
// colour) is no longer where it was, seen from the button. What it shows
// from inside its own scroller moves with it, and never stales it.
function keyOf(e) {
  const el = e.el
  const size = `${el.offsetWidth}x${el.offsetHeight}`
  if (!e.dep?.positional) return size
  if (!e.dep.outside) return `${size}|in`
  return `${size}|${outsideKey(e)}`
}
function check() {
  fullCheck = false
  for (const e of entries.values()) {
    if (!e.el.isConnected) { forget(e); continue }
    if (!e.visible || !e.drawn || mode !== 'gl' || !ownGlass(e)) continue
    if (keyOf(e) !== e.key) invalidate(e, scrolling ? THROTTLE_SCROLL : THROTTLE)
  }
}
function recheck() {
  fullCheck = true
  schedule()
}

// ---------------------------------------------------------------- modes

function setMode() {
  readPage()
  const next = currentMode()
  if (next !== mode) {
    mode = next
    for (const e of entries.values()) {
      e.drawn = false
      e.tex = null // a lost or rebuilt context's textures are gone
      if (mode !== 'gl') e.canvas?.remove()
    }
  }
  classify(...entries.values())
  // a theme, a glass setting or the engine changed what is behind every
  // button (or how it's drawn): all of them are drawn again
  for (const e of entries.values()) invalidate(e)
  if (mode === 'gl' && !untilt) untilt = subscribeTilt(rad => { tilt = rad; relight() })
  if (mode !== 'gl' && untilt) { untilt(); untilt = null; tilt = 0 }
}

// ---------------------------------------------------------------- watching

const io = new IntersectionObserver(records => {
  for (const r of records) {
    const e = entries.get(r.target)
    if (!e) continue
    e.visible = r.isIntersecting
    if (e.visible && (!e.drawn || keyOf(e) !== e.key)) invalidate(e)
  }
}, { rootMargin: '96px' })
const ro = new ResizeObserver(records => {
  for (const r of records) invalidate(entries.get(r.target))
})

const ours = n => n.nodeType === 1 && (n.classList.contains('lg-btn') || n.classList.contains('lg-canvas'))
function onMutations(records) {
  const retone = new Set()
  const touched = new Set()
  let remode = false
  for (const rec of records) {
    const t = rec.target
    if (rec.type === 'childList') {
      // A button's content was replaced (textContent, replaceChildren) and took
      // its glass with it: put it straight back, before the page is painted —
      // a canvas keeps its picture — so the button never shows without it.
      const own = entries.get(t)
      if (own?.canvas && own.drawn && own.canvas.parentElement !== t && mode === 'gl') t.insertBefore(own.canvas, t.firstChild)
      if ([...rec.addedNodes, ...rec.removedNodes].every(n => ours(n) || n.nodeType === 3 && t.closest?.('.field-twin'))) continue
      for (const n of rec.addedNodes) {
        if (n.nodeType !== 1 || ours(n)) continue
        consider(n)
        for (const b of n.querySelectorAll(BUTTONS)) consider(b)
      }
      if (rec.removedNodes.length) fullCheck = true
      if (own) invalidate(own) // its content changed size or place, maybe
      touched.add(t.nodeType === 1 ? t : t.parentElement)
    } else if (rec.type === 'attributes') {
      if (ours(t)) continue
      if (t === root) {
        if (/^data-(theme|glass)/.test(rec.attributeName)) remode = true
        continue
      }
      if (t.nodeType === 1 && !entries.has(t) && t.matches?.(BUTTONS)) consider(t)
      if (rec.attributeName !== 'style') retone.add(t)
      touched.add(t)
    } else if (rec.type === 'characterData') {
      touched.add(t.parentElement)
    }
  }
  settleFresh()
  if (remode) setMode()
  else if (retone.size) {
    const hit = []
    for (const e of entries.values()) {
      for (const t of retone) if (t === e.el || t.contains(e.el)) { hit.push(e); break }
    }
    if (hit.length) classify(...hit)
  }
  // something changed where a glass shows it: repaint that glass
  const rects = []
  for (const t of touched) {
    if (!t || t.nodeType !== 1 || rects.length > 64) continue
    const r = t.getBoundingClientRect()
    if (r.width || r.height) rects.push([t, r])
  }
  for (const e of entries.values()) {
    if (!e.drawn || !e.visible || !e.dep?.positional || !e.region) continue
    const g = e.region
    for (const [t, r] of rects) {
      if (e.el.contains(t)) continue // its own content is drawn over the glass, not in it
      const holder = t.closest('[data-lg]:not([data-lg="probe"])')
      if (holder && holder !== e.el) continue // nor is another glass button's
      // what comes after it in the page is painted over it, not behind it
      if (!t.contains(e.el) && t.compareDocumentPosition(e.el) & Node.DOCUMENT_POSITION_PRECEDING) continue
      if (r.right > g.left && r.left < g.right && r.bottom > g.top && r.top < g.bottom) { invalidate(e); break }
    }
  }
  recheck()
}
const mo = new MutationObserver(onMutations)

let scrollEnd = 0
let scrolling = false
function onScroll(ev) {
  scrolling = true
  const s = ev.target === document ? document.scrollingElement : ev.target
  if (!s || s.nodeType !== 1) return
  for (const e of entries.values()) {
    if (!e.visible || !e.drawn || !e.dep) continue
    // it shows that scroller's content, or moves over something that doesn't
    if (e.dep.scrollers.has(s) || (e.dep.outside && s.contains(e.el) && keyOf(e) !== e.key)) invalidate(e, THROTTLE_SCROLL)
  }
  clearTimeout(scrollEnd)
  scrollEnd = setTimeout(() => { scrolling = false; recheck() }, 160)
}

let started = false
/** Start the Liquid Glass on every button (main.js, once). */
export function initLiquidGlass() {
  if (started) return
  started = true
  readPage()
  mode = currentMode()
  for (const el of document.querySelectorAll(BUTTONS)) consider(el)
  settleFresh()
  mo.observe(root, {
    subtree: true, childList: true, characterData: true, attributes: true,
    attributeFilter: ['class', 'hidden', 'style', 'disabled', 'aria-checked', 'aria-pressed', 'aria-selected', 'data-backdrop', 'data-theme', 'data-glass', 'data-glass-tint']
  })
  document.addEventListener('scroll', onScroll, { capture: true, passive: true })
  for (const ev of ['transitionend', 'animationend']) document.addEventListener(ev, recheck, { capture: true, passive: true })
  window.addEventListener('resize', () => { for (const e of entries.values()) invalidate(e) })
  window.addEventListener('cuven:glass', setMode)
  for (const q of ['(prefers-reduced-transparency: reduce)', '(prefers-contrast: more)', '(prefers-color-scheme: dark)']) {
    try { matchMedia(q).addEventListener('change', setMode) } catch {}
  }
  onEngine(setMode)
  document.fonts?.ready.then(() => { for (const e of entries.values()) if (e.dep?.positional) invalidate(e) })
  setMode()
}

/** For tests and diagnostics: work done so far. */
export function glassStats() {
  return { ...stats, buttons: entries.size, mode }
}
/** For tests and diagnostics: how each button is drawn now. */
export function glassButtons() {
  return [...entries.values()].map(e => ({ el: e.el, tone: e.tone, inner: e.inner, mode: e.el.dataset.lg, drawn: e.drawn, visible: e.visible, paints: e.paints || 0 }))
}
