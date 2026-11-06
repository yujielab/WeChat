// Drawing board — paper you sketch on and send, after the reference: the
// paper (plain, lined or a grid) with a floating capsule of tools under it —
// the pens standing in a row (pen, marker, highlighter, pencil, eraser; the
// one in hand stands taller, its tip in the colour), the colours with a
// wheel for any other, and "…" for the size, the paper and clearing — then
// Close, Undo and Redo, and Send. Strokes are velocity-smoothed and drawn
// through midpoints; the highlighter lays one even translucent band per
// stroke. Exports a PNG and hands it back via onSend(blob, {w,h}). It lives
// in the details column, beside the conversation it's drawn for.

import { h, icon } from '../ui/dom.js'
import { symbolEffect } from '../ui/symbols.js'
import { haptic } from '../ui/haptics.js'
import { openMenu } from './overlay.js'

const COLORS = [
  { c: '#18181b', name: 'Black' }, { c: '#007aff', name: 'Blue' }, { c: '#34c759', name: 'Green' },
  { c: '#ffcc00', name: 'Yellow' }, { c: '#ff3b30', name: 'Red' }
]
const SIZES = [3, 6, 12, 22]
const SIZE_NAMES = ['Thin', 'Medium', 'Thick', 'Extra thick']
/** The pens: how wide (× the size), how opaque, and how the line ends. */
const TOOLS = [
  { id: 'pen', name: 'Pen', k: 1, alpha: 1, cap: 'round', velocity: true },
  { id: 'marker', name: 'Marker', k: 2.2, alpha: 1, cap: 'round' },
  { id: 'highlighter', name: 'Highlighter', k: 4, alpha: 0.35, cap: 'butt', band: true },
  { id: 'pencil', name: 'Pencil', k: 0.6, alpha: 0.8, cap: 'round' },
  { id: 'eraser', name: 'Eraser', k: 3.5, alpha: 1, cap: 'round', erase: true }
]
const PAPERS = [['plain', 'Plain'], ['lines', 'Lines'], ['grid', 'Grid']]

/** Build the board into `host`; onClose() when Close or Send is chosen. Returns { el, destroy }. */
export function createDrawing(host, { onSend, onClose }) {
  // Focusable (not in the tab order) so a kept drawing can have the focus back.
  const canvas = h('canvas', { class: 'draw-canvas', tabindex: '-1', role: 'img', 'aria-label': 'Canvas' })
  // The highlighter's band while it's being drawn, laid on the paper once lifted.
  const live = h('canvas', { class: 'draw-live', 'aria-hidden': 'true' })
  const stage = h('div', { class: 'draw-stage', dataset: { paper: 'plain' } }, canvas, live)

  // ------------------------------------------------------------ the capsule of tools
  const nibs = TOOLS.map(t => {
    const b = h('button', { class: 'draw-nib', type: 'button', dataset: { tool: t.id }, 'aria-label': t.name, 'aria-pressed': 'false' },
      h('span', { class: 'nib-body', 'aria-hidden': 'true' }, h('span', { class: 'nib-tip' }), h('span', { class: 'nib-band' })),
      h('span', { class: 'nib-size tabular', 'aria-hidden': 'true' }))
    b.addEventListener('click', () => setTool(t.id))
    return b
  })
  const swatches = COLORS.map(({ c, name }) => {
    const b = h('button', { class: 'draw-color', type: 'button', style: { '--c': c }, 'aria-label': name, 'aria-pressed': 'false' })
    b.addEventListener('click', () => setColor(c, b))
    return b
  })
  const wheelInput = h('input', { type: 'color', value: '#5856d6', tabindex: '-1', 'aria-hidden': 'true' })
  const wheel = h('label', { class: 'draw-color draw-wheel', 'aria-label': 'Any colour', role: 'button', tabindex: '0' }, wheelInput)
  wheelInput.addEventListener('input', () => { wheel.style.setProperty('--c', wheelInput.value); setColor(wheelInput.value, wheel) })
  wheel.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); wheelInput.click() } })
  const more = h('button', { class: 'draw-more glass glass-btn', type: 'button', 'aria-label': 'More', 'aria-haspopup': 'menu' }, icon('ellipsis'))
  more.addEventListener('click', () => openMenu(more, [
    SIZES.map((sz, i) => ({ label: SIZE_NAMES[i], checked: size === sz, onSelect: () => setSize(sz) })),
    PAPERS.map(([id, label]) => ({ label: `${label} paper`, checked: stage.dataset.paper === id, onSelect: () => { stage.dataset.paper = id } })),
    [{ label: 'Clear', icon: 'trash', destructive: true, onSelect: () => clearAll() }]
  ], { title: 'Drawing' }))
  const palette = h('div', { class: 'draw-palette glass glass-thick', role: 'toolbar', 'aria-label': 'Pens and colours' },
    h('div', { class: 'draw-nibs', role: 'group', 'aria-label': 'Pens' }, ...nibs),
    h('span', { class: 'draw-divider', 'aria-hidden': 'true' }),
    h('div', { class: 'draw-colors', role: 'group', 'aria-label': 'Brush color' }, ...swatches, wheel),
    more)

  const undoBtn = toolBtn('undo', 'Undo', () => undo())
  const redoBtn = toolBtn('redo', 'Redo', () => redo())
  const closeBtn = h('button', { class: 'glass glass-btn draw-close', type: 'button', 'aria-label': 'Close' }, icon('xmark'))
  const sendBtn = h('button', { class: 'draw-send solid-press', type: 'button', title: 'Send', 'aria-label': 'Send', disabled: true }, icon('arrow-up'), h('span', { class: 'draw-send-label', 'aria-hidden': 'true' }, 'Send'))
  // Like every column, the board ends in one bar: Close leads, Undo and
  // Redo share a capsule, Send ends it.
  const tools = h('div', { class: 'draw-tools' }, undoBtn, redoBtn)
  const dock = h('div', { class: 'draw-dock' }, closeBtn, tools, sendBtn)
  const head = h('div', { class: 'draw-head' }, h('div', { class: 'draw-title' }, 'Drawing board'))
  const root = h('div', { class: 'draw on', role: 'region', 'aria-label': 'Drawing board' }, head, stage, h('div', { class: 'draw-bar' }, palette, dock))
  host.append(root)

  // ---- canvas setup (HiDPI, white paper)
  const ctx = canvas.getContext('2d')
  const lctx = live.getContext('2d')
  let dpr = 1, W = 0, H = 0
  const undoStack = []
  const redoStack = []
  let dirty = false
  let color = COLORS[0].c
  let size = SIZES[1]
  let tool = TOOLS[0]
  setColor(color, swatches[0])
  setSize(size)
  setTool('pen')

  function fit() {
    const r = stage.getBoundingClientRect()
    dpr = Math.min(3, window.devicePixelRatio || 1)
    W = Math.round(r.width); H = Math.round(r.height)
    const prev = dirty ? ctx.getImageData(0, 0, canvas.width, canvas.height) : null
    for (const c of [canvas, live]) { c.width = Math.round(W * dpr); c.height = Math.round(H * dpr); c.style.width = `${W}px`; c.style.height = `${H}px` }
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    lctx.setTransform(dpr, 0, 0, dpr, 0, 0)
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
  const ink = () => (tool.erase ? '#ffffff' : color)

  canvas.addEventListener('pointerdown', e => {
    if (e.button > 0) return
    canvas.setPointerCapture(e.pointerId)
    snapshot()
    redoStack.length = 0
    paintHistory()
    const p = pt(e)
    const width = size * tool.k
    drawing = { last: p, mid: p, width, points: [p] }
    if (tool.band) {
      // The band: drawn whole on the overlay, laid down translucent when lifted.
      live.style.opacity = String(tool.alpha)
      lctx.clearRect(0, 0, W, H)
      return
    }
    ctx.globalAlpha = tool.alpha
    ctx.strokeStyle = ink()
    ctx.lineCap = tool.cap
    // a dot for a tap
    ctx.beginPath(); ctx.fillStyle = ink(); ctx.arc(p.x, p.y, width / 2, 0, Math.PI * 2); ctx.fill()
    if (!tool.erase) markDirty()
  })
  canvas.addEventListener('pointermove', e => {
    if (!drawing) return
    const events = e.getCoalescedEvents ? e.getCoalescedEvents() : [e]
    for (const ev of events) stroke(pt(ev))
  })
  const stroke = p => {
    if (tool.band) {
      drawing.points.push(p)
      lctx.clearRect(0, 0, W, H)
      lctx.strokeStyle = color
      lctx.lineWidth = size * tool.k
      lctx.lineCap = 'butt'
      lctx.lineJoin = 'round'
      lctx.beginPath()
      drawing.points.forEach((q, i) => (i ? lctx.lineTo(q.x, q.y) : lctx.moveTo(q.x, q.y)))
      lctx.stroke()
      drawing.last = p
      return
    }
    const d = Math.hypot(p.x - drawing.last.x, p.y - drawing.last.y)
    const dt = Math.max(1, p.t - drawing.last.t)
    const base = size * tool.k
    if (tool.velocity) {
      const speed = d / dt
      const target = Math.max(base * 0.45, base * (1.3 - Math.min(1, speed * 0.6)))
      drawing.width += (target - drawing.width) * 0.3
    } else drawing.width = base
    const mid = { x: (drawing.last.x + p.x) / 2, y: (drawing.last.y + p.y) / 2 }
    ctx.lineWidth = drawing.width
    ctx.beginPath()
    ctx.moveTo(drawing.mid.x, drawing.mid.y)
    ctx.quadraticCurveTo(drawing.last.x, drawing.last.y, mid.x, mid.y)
    ctx.stroke()
    drawing.last = p; drawing.mid = mid
  }
  const endStroke = () => {
    if (!drawing) return
    if (tool.band && drawing.points.length) {
      ctx.save()
      ctx.setTransform(1, 0, 0, 1, 0, 0)
      ctx.globalAlpha = tool.alpha
      ctx.drawImage(live, 0, 0)
      ctx.restore()
      lctx.clearRect(0, 0, W, H)
      markDirty()
    }
    ctx.globalAlpha = 1
    ctx.lineCap = 'round'
    drawing = null
  }
  canvas.addEventListener('pointerup', endStroke)
  canvas.addEventListener('pointercancel', endStroke)
  canvas.addEventListener('pointerleave', endStroke)

  // Each step back remembers whether there was ink on the board then, so
  // undoing a Clear brings back Send and the question before closing.
  function setDirty(on) { dirty = on; sendBtn.disabled = !on }
  function markDirty() { if (!dirty) setDirty(true) }
  const state = () => ({ img: ctx.getImageData(0, 0, canvas.width, canvas.height), inked: dirty })
  function snapshot() {
    undoStack.push(state())
    if (undoStack.length > 24) undoStack.shift()
  }
  function restore(step) {
    ctx.setTransform(1, 0, 0, 1, 0, 0)
    ctx.putImageData(step.img, 0, 0)
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    setDirty(step.inked)
  }
  function undo() {
    const step = undoStack.pop()
    if (!step) return
    redoStack.push(state())
    restore(step)
    haptic()
    paintHistory()
  }
  function redo() {
    const step = redoStack.pop()
    if (!step) return
    undoStack.push(state())
    restore(step)
    haptic()
    paintHistory()
  }
  function paintHistory() {
    undoBtn.disabled = !undoStack.length
    redoBtn.disabled = !redoStack.length
  }
  function clearAll() {
    snapshot()
    redoStack.length = 0
    ctx.fillStyle = '#ffffff'; ctx.fillRect(0, 0, W, H)
    setDirty(false)
    haptic()
    paintHistory()
  }
  function setColor(c, btn) {
    color = c
    for (const b of [...swatches, wheel]) {
      b.classList.toggle('on', b === btn)
      b.setAttribute('aria-pressed', String(b === btn))
    }
    palette.style.setProperty('--pen', c)
    // A colour picks up a pen again if the eraser was in hand.
    if (tool.erase) setTool('pen')
  }
  function setSize(sz) {
    size = sz
    for (const b of nibs) b.querySelector('.nib-size').textContent = String(Math.round(sz * TOOLS.find(t => t.id === b.dataset.tool).k))
  }
  function setTool(id) {
    tool = TOOLS.find(t => t.id === id) || TOOLS[0]
    for (const b of nibs) {
      const on = b.dataset.tool === tool.id
      b.classList.toggle('on', on)
      b.setAttribute('aria-pressed', String(on))
    }
    canvas.dataset.tool = tool.id
  }
  paintHistory()
  redoBtn.disabled = true

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
