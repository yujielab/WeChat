// Drawing board — a clean white canvas you sketch on and send. Strokes are
// velocity-smoothed (slower = thicker) and drawn through midpoints for a fluid,
// ink-like line. Exports a PNG and hands it back via onSend(blob, {w,h}).

import { h, icon } from '../ui/dom.js'
import { haptic } from '../ui/haptics.js'

const COLORS = ['#18181b', '#ff3b30', '#ff9500', '#ffcc00', '#34c759', '#007aff', '#5856d6', '#ff2d92', '#ffffff']
const SIZES = [3, 6, 12, 22]

export function openDrawing({ onSend }) {
  const canvas = h('canvas', { class: 'draw-canvas' })
  const stage = h('div', { class: 'draw-stage' }, canvas)

  const swatches = COLORS.map(c => {
    const b = h('button', { class: 'draw-color', type: 'button', style: { '--c': c }, 'aria-label': `颜色 ${c}` })
    b.addEventListener('click', () => setColor(c, b))
    return b
  })
  const sizeBtns = SIZES.map(sz => {
    const b = h('button', { class: 'draw-size', type: 'button', 'aria-label': `画笔 ${sz}` }, h('span', { style: { width: `${Math.min(sz, 18)}px`, height: `${Math.min(sz, 18)}px` } }))
    b.addEventListener('click', () => setSize(sz, b))
    return b
  })

  const undoBtn = toolBtn('undo', '撤销', () => undo())
  const clearBtn = toolBtn('trash', '清空', () => clearAll())
  const closeBtn = h('button', { class: 'glass glass-btn draw-close', type: 'button', 'aria-label': '关闭' }, icon('xmark'))
  const sendBtn = h('button', { class: 'draw-send solid-press', type: 'button', disabled: true }, icon('arrow-up'), '发送')

  const palette = h('div', { class: 'draw-palette glass glass-thick' }, ...swatches)
  const sizes = h('div', { class: 'draw-sizes glass glass-thick' }, ...sizeBtns)
  const tools = h('div', { class: 'draw-tools' }, undoBtn, clearBtn)
  // Brush sizes share a row with undo / clear, so the canvas keeps the height.
  const row = h('div', { class: 'draw-row' }, sizes, tools)
  const head = h('div', { class: 'draw-head' }, closeBtn, h('div', { class: 'draw-title' }, '画板'), sendBtn)
  const root = h('div', { class: 'draw', role: 'dialog', 'aria-modal': 'true', 'aria-label': '画板' }, head, stage, h('div', { class: 'draw-bar' }, row, palette))

  const overlays = document.getElementById('overlays')
  overlays.append(root)
  requestAnimationFrame(() => root.classList.add('on'))

  // ---- canvas setup (HiDPI, white paper)
  const ctx = canvas.getContext('2d')
  let dpr = 1, W = 0, H = 0
  const undoStack = []
  let dirty = false
  let color = COLORS[0]
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
    undoStack.push(ctx.getImageData(0, 0, canvas.width, canvas.height))
    if (undoStack.length > 24) undoStack.shift()
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

  function markDirty() { if (!dirty) { dirty = true; sendBtn.disabled = false } }
  function undo() {
    const img = undoStack.pop()
    if (!img) return
    ctx.setTransform(1, 0, 0, 1, 0, 0)
    ctx.putImageData(img, 0, 0)
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0)
    haptic()
    if (!undoStack.length) { dirty = false; sendBtn.disabled = true }
  }
  function clearAll() {
    undoStack.push(ctx.getImageData(0, 0, canvas.width, canvas.height))
    ctx.fillStyle = '#ffffff'; ctx.fillRect(0, 0, W, H)
    dirty = false; sendBtn.disabled = true
    haptic()
  }
  function setColor(c, btn) {
    color = c
    for (const b of swatches) b.classList.toggle('on', b === btn)
  }
  function setSize(sz, btn) {
    size = sz
    for (const b of sizeBtns) b.classList.toggle('on', b === btn)
  }

  function close() {
    ro.disconnect()
    root.classList.remove('on')
    setTimeout(() => root.remove(), 260)
  }
  closeBtn.addEventListener('click', close)
  sendBtn.addEventListener('click', async () => {
    if (!dirty) return
    sendBtn.disabled = true
    const blob = await new Promise(r => canvas.toBlob(r, 'image/png'))
    if (blob) onSend(blob, { w: canvas.width, h: canvas.height })
    close()
  })
  document.addEventListener('keydown', function esc(e) {
    if (e.key === 'Escape') { close(); document.removeEventListener('keydown', esc) }
  })
}

function toolBtn(ic, label, onClick) {
  const b = h('button', { class: 'draw-tool glass glass-btn', type: 'button', 'aria-label': label }, icon(ic))
  b.addEventListener('click', onClick)
  return b
}
