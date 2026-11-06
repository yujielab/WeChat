// Drawing board — a clean white canvas you sketch on and send. Strokes are
// velocity-smoothed (slower = thicker) and drawn through midpoints for a fluid,
// ink-like line. Exports a PNG and hands it back via onSend(blob, {w,h}).
// It lives in the details column, beside the conversation it's drawn for.

import { h, icon } from '../ui/dom.js'
import { symbolEffect } from '../ui/symbols.js'
import { haptic } from '../ui/haptics.js'

const COLORS = [
  { c: '#18181b', name: 'Black' }, { c: '#ff3b30', name: 'Red' }, { c: '#ff9500', name: 'Orange' },
  { c: '#ffcc00', name: 'Yellow' }, { c: '#34c759', name: 'Green' }, { c: '#007aff', name: 'Blue' },
  { c: '#5856d6', name: 'Purple' }, { c: '#ff2d92', name: 'Pink' }, { c: '#ffffff', name: 'White' }
]
const SIZES = [3, 6, 12, 22]
const SIZE_NAMES = ['Thin', 'Medium', 'Thick', 'Extra thick']

/** Build the board into `host`; onClose() when Close or Send is chosen. Returns { el, destroy }. */
export function createDrawing(host, { onSend, onClose }) {
  // Focusable (not in the tab order) so a kept drawing can have the focus back.
  const canvas = h('canvas', { class: 'draw-canvas', tabindex: '-1', role: 'img', 'aria-label': 'Canvas' })
  const stage = h('div', { class: 'draw-stage' }, canvas)

  const swatches = COLORS.map(({ c, name }) => {
    const b = h('button', { class: 'draw-color', type: 'button', style: { '--c': c }, 'aria-label': name, 'aria-pressed': 'false' })
    b.addEventListener('click', () => setColor(c, b))
    return b
  })
  const sizeBtns = SIZES.map((sz, i) => {
    const b = h('button', { class: 'draw-size', type: 'button', 'aria-label': SIZE_NAMES[i], 'aria-pressed': 'false' }, h('span', { style: { width: `${Math.min(sz, 18)}px`, height: `${Math.min(sz, 18)}px` } }))
    b.addEventListener('click', () => setSize(sz, b))
    return b
  })

  const undoBtn = toolBtn('undo', 'Undo', () => undo())
  const clearBtn = toolBtn('trash', 'Clear', () => clearAll())
  const closeBtn = h('button', { class: 'glass glass-btn draw-close', type: 'button', 'aria-label': 'Close' }, icon('xmark'))
  const sendBtn = h('button', { class: 'draw-send solid-press', type: 'button', title: 'Send', 'aria-label': 'Send', disabled: true }, icon('arrow-up'), h('span', { class: 'draw-send-label', 'aria-hidden': 'true' }, 'Send'))

  const palette = h('div', { class: 'draw-palette glass glass-thick', role: 'group', 'aria-label': 'Brush color' }, ...swatches)
  const sizes = h('div', { class: 'draw-sizes glass glass-thick', role: 'group', 'aria-label': 'Brush size' }, ...sizeBtns)
  // Like every column, the board ends in one bar: Close leads, Undo and
  // Clear share a capsule, Send ends it.
  const tools = h('div', { class: 'draw-tools' }, undoBtn, clearBtn)
  const dock = h('div', { class: 'draw-dock' }, closeBtn, tools, sendBtn)
  const head = h('div', { class: 'draw-head' }, h('div', { class: 'draw-title' }, 'Drawing board'))
  const root = h('div', { class: 'draw on', role: 'region', 'aria-label': 'Drawing board' }, head, stage, h('div', { class: 'draw-bar' }, sizes, palette, dock))
  host.append(root)

  // ---- canvas setup (HiDPI, white paper)
  const ctx = canvas.getContext('2d')
  let dpr = 1, W = 0, H = 0
  const undoStack = []
  let dirty = false
  let color = COLORS[0].c
  let size = SIZES[1]
  setColor(color, swatches[0])
  setSize(size, sizeBtns[1])

  function fit() {
    const r = stage.getBoundingClientRect()
    dpr = Math.min(3, window.devicePixelRatio || 1)
    W = Math.round(r.width); H = Math.round(r.height)
    const prev = dirty ? ctx.getImageData(0, 0, canvas.width, canvas.height) : null
    canvas.width = Math.round(W * dpr); canvas.height = Math.round(H * dpr)
    canvas.style.width = `${W}px`; canvas.style.height = `${H}px`
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    ctx.fillStyle = '#ffffff'; ctx.fillRect(0, 0, W, H)
    ctx.lineCap = 'round'; ctx.lineJoin = 'round'
    if (prev) { const tmp = document.createElement('canvas'); tmp.width = prev.width; tmp.height = prev.height; tmp.getContext('2d').putImageData(prev, 0, 0); ctx.drawImage(tmp, 0, 0, W, H) }
  }
  const ro = new ResizeObserver(() => fit())
  ro.observe(stage)
  requestAnimationFrame(fit)

  // ---- drawing
  let drawing = null
  const pt = e => { const r = canvas.getBoundingClientRect(); return { x: e.clientX - r.left, y: e.clientY - r.top, t: e.timeStamp } }

  canvas.addEventListener('pointerdown', e => {
    if (e.button > 0) return
    canvas.setPointerCapture(e.pointerId)
    snapshot()
    const p = pt(e)
    drawing = { last: p, mid: p, width: size }
    ctx.strokeStyle = color
    // a dot for a tap
    ctx.beginPath(); ctx.fillStyle = color; ctx.arc(p.x, p.y, size / 2, 0, Math.PI * 2); ctx.fill()
    markDirty()
  })
  canvas.addEventListener('pointermove', e => {
    if (!drawing) return
    const events = e.getCoalescedEvents ? e.getCoalescedEvents() : [e]
    for (const ev of events) stroke(pt(ev))
  })
  const stroke = p => {
    const d = Math.hypot(p.x - drawing.last.x, p.y - drawing.last.y)
    const dt = Math.max(1, p.t - drawing.last.t)
    const speed = d / dt
    const target = Math.max(size * 0.45, size * (1.3 - Math.min(1, speed * 0.6)))
    drawing.width += (target - drawing.width) * 0.3
    const mid = { x: (drawing.last.x + p.x) / 2, y: (drawing.last.y + p.y) / 2 }
    ctx.lineWidth = drawing.width
    ctx.beginPath()
    ctx.moveTo(drawing.mid.x, drawing.mid.y)
    ctx.quadraticCurveTo(drawing.last.x, drawing.last.y, mid.x, mid.y)
    ctx.stroke()
    drawing.last = p; drawing.mid = mid
  }
  const endStroke = () => { drawing = null }
  canvas.addEventListener('pointerup', endStroke)
  canvas.addEventListener('pointercancel', endStroke)
  canvas.addEventListener('pointerleave', endStroke)

  // Each step back remembers whether there was ink on the board then, so
  // undoing a Clear brings back Send and the question before closing.
  function setDirty(on) { dirty = on; sendBtn.disabled = !on }
  function markDirty() { if (!dirty) setDirty(true) }
  function snapshot() {
    undoStack.push({ img: ctx.getImageData(0, 0, canvas.width, canvas.height), inked: dirty })
    if (undoStack.length > 24) undoStack.shift()
  }
  function undo() {
    const step = undoStack.pop()
    if (!step) return
    ctx.setTransform(1, 0, 0, 1, 0, 0)
    ctx.putImageData(step.img, 0, 0)
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    haptic()
    setDirty(step.inked)
  }
  function clearAll() {
    snapshot()
    ctx.fillStyle = '#ffffff'; ctx.fillRect(0, 0, W, H)
    setDirty(false)
    haptic()
  }
  function setColor(c, btn) {
    color = c
    for (const b of swatches) {
      b.classList.toggle('on', b === btn)
      b.setAttribute('aria-pressed', String(b === btn))
    }
  }
  function setSize(sz, btn) {
    size = sz
    for (const b of sizeBtns) {
      b.classList.toggle('on', b === btn)
      b.setAttribute('aria-pressed', String(b === btn))
    }
  }

  closeBtn.addEventListener('click', () => onClose())
  // Not disabled while it sends: a focused button that turns disabled drops
  // focus to the page, and the shell's focus fallback then has nothing to follow.
  let sending = false
  sendBtn.addEventListener('click', async () => {
    if (!dirty || sending) return
    sending = true
    const blob = await new Promise(r => canvas.toBlob(r, 'image/png'))
    if (blob) onSend(blob, { w: canvas.width, h: canvas.height })
    // Sent: nothing left to lose, so closing asks nothing.
    dirty = false
    onClose({ sent: true })
  })

  return {
    el: root,
    /** Ink on the board that hasn't been sent (closing would lose it). */
    get dirty() { return dirty },
    closeButton: closeBtn,
    canvas,
    destroy() {
      ro.disconnect()
      root.remove()
    }
  }
}

function toolBtn(ic, label, onClick) {
  const b = h('button', { class: 'draw-tool glass glass-btn', type: 'button', 'aria-label': label }, icon(ic))
  b.addEventListener('click', () => {
    symbolEffect(b.querySelector('.icon'), 'bounce')
    onClick()
  })
  return b
}
