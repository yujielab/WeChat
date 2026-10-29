// A finite, interactive halftone illustration. Source masks are procedural;
// only pointer movement or a chosen shape wakes the canvas animation.
import { h, icon, reducedMotion } from './dom.js'

const WIDTH = 320
const HEIGHT = 210
const GAP = 5.5
const SHAPES = [
  { id: 'conversation', label: '对话' },
  { id: 'heart', label: '心意' },
  { id: 'drawing', label: '随手画' }
]

function bubble(g, x, y, rx, ry, angle, ink) {
  g.save()
  g.translate(x, y)
  g.rotate(angle)
  g.beginPath()
  g.moveTo(0, -ry)
  g.bezierCurveTo(rx * .6, -ry, rx, -ry * .3, rx, 0)
  g.bezierCurveTo(rx, ry * .6, rx * .4, ry, -rx * .08, ry)
  g.quadraticCurveTo(-rx * .35, ry, -rx * .47, ry * .9)
  g.lineTo(-rx * .85, ry * 1.27)
  g.quadraticCurveTo(-rx * .7, ry * .85, -rx * .72, ry * .68)
  g.bezierCurveTo(-rx * 1.2, ry * .1, -rx, -ry * .9, 0, -ry)
  g.closePath()
  g.fillStyle = '#fff'
  g.fill()
  g.strokeStyle = ink
  g.lineWidth = 9
  g.stroke()
  g.restore()
}

function masks(points) {
  const source = document.createElement('canvas')
  source.width = WIDTH
  source.height = HEIGHT
  const g = source.getContext('2d', { willReadFrequently: true })
  if (!g) return SHAPES.map(() => new Float32Array(points.length))
  return SHAPES.map(({ id }) => {
    g.clearRect(0, 0, WIDTH, HEIGHT)
    g.fillStyle = '#fff'
    g.fillRect(0, 0, WIDTH, HEIGHT)
    g.strokeStyle = '#171717'
    g.lineCap = 'round'
    g.lineJoin = 'round'
    if (id === 'conversation') {
      bubble(g, 128, 83, 72, 46, -.09, '#171717')
      bubble(g, 193, 126, 70, 44, .07, '#727272')
    } else if (id === 'heart') {
      g.beginPath()
      g.moveTo(160, 180)
      g.bezierCurveTo(141, 165, 73, 120, 73, 84)
      g.bezierCurveTo(73, 42, 132, 33, 160, 74)
      g.bezierCurveTo(188, 33, 247, 42, 247, 84)
      g.bezierCurveTo(247, 120, 179, 165, 160, 180)
      const shade = g.createLinearGradient(85, 55, 240, 175)
      shade.addColorStop(0, '#171717')
      shade.addColorStop(1, '#8a8a8a')
      g.fillStyle = shade
      g.fill()
    } else {
      g.lineWidth = 13
      g.beginPath()
      g.moveTo(48, 122)
      g.bezierCurveTo(90, 38, 91, 180, 139, 96)
      g.bezierCurveTo(164, 50, 160, 155, 202, 112)
      g.bezierCurveTo(219, 93, 231, 84, 255, 96)
      g.stroke()
      g.lineWidth = 6
      g.beginPath()
      g.moveTo(258, 38); g.lineTo(254, 62)
      g.moveTo(244, 47); g.lineTo(269, 53)
      g.moveTo(66, 163); g.quadraticCurveTo(156, 183, 235, 155)
      g.strokeStyle = '#808080'
      g.stroke()
    }
    const data = g.getImageData(0, 0, WIDTH, HEIGHT).data
    return Float32Array.from(points, ({ x, y }) => {
      let ink = 0
      let count = 0
      for (let dy = -2; dy <= 2; dy += 2) {
        for (let dx = -2; dx <= 2; dx += 2) {
          const px = Math.max(0, Math.min(WIDTH - 1, Math.round(x + dx)))
          const py = Math.max(0, Math.min(HEIGHT - 1, Math.round(y + dy)))
          ink += 1 - data[(py * WIDTH + px) * 4] / 255
          count++
        }
      }
      return ink / count
    })
  })
}

export function createHalftone({ compact = false } = {}) {
  const canvas = h('canvas', { 'aria-hidden': 'true' })
  const stage = h('button', { class: 'halftone-stage', type: 'button', 'aria-label': '换个心情' }, canvas,
    h('span', { class: 'halftone-fallback', 'aria-hidden': 'true' }, icon('bubble')))
  const controls = h('div', { class: 'halftone-controls', role: 'group', 'aria-label': '插画心情' })
  const live = h('span', { class: 'sr-only', 'aria-live': 'polite' })
  const el = h('div', { class: ['halftone-art', compact && 'compact'] }, stage, controls, live)
  const buttons = SHAPES.map((shape, index) => {
    const button = h('button', { type: 'button', 'aria-pressed': index === 0 ? 'true' : 'false' }, shape.label)
    button.addEventListener('click', () => select(index))
    controls.append(button)
    return button
  })
  const ctx = canvas.getContext('2d')
  const points = []
  for (let y = GAP / 2; y < HEIGHT; y += GAP) {
    for (let x = GAP / 2; x < WIDTH; x += GAP) points.push({ x, y })
  }
  const targets = masks(points)
  let current = targets[0].slice()
  let selected = 0
  let morph = null
  let raf = 0
  let visible = false
  let seenConnected = false
  let destroyed = false
  let ink = '#171717'
  let scale = 1
  let lastTime = 0
  const pointer = { x: WIDTH / 2, y: HEIGHT / 2, tx: WIDTH / 2, ty: HEIGHT / 2, k: 0, target: 0 }
  const finePointer = matchMedia('(hover: hover) and (pointer: fine)')
  const motionQuery = matchMedia('(prefers-reduced-motion: reduce)')
  const themeQuery = matchMedia('(prefers-color-scheme: dark)')
  if (ctx) el.dataset.canvas = 'ready'

  const drawable = () => !destroyed && visible && !document.hidden && el.isConnected && stage.getClientRects().length > 0
  const stop = () => {
    cancelAnimationFrame(raf)
    raf = 0
    if (morph) current = targets[selected].slice()
    morph = null
    pointer.k = pointer.target = 0
  }
  function colors() {
    ink = getComputedStyle(el).getPropertyValue('--label').trim() || '#171717'
    if (reducedMotion()) stop()
    draw()
  }
  function resize() {
    const width = stage.getBoundingClientRect().width
    if (!width || !ctx) return
    const dpr = Math.min(2, devicePixelRatio || 1)
    canvas.width = Math.round(width * dpr)
    canvas.height = Math.round(width * HEIGHT / WIDTH * dpr)
    scale = canvas.width / WIDTH
    draw()
  }
  function draw(now = performance.now()) {
    if (!ctx || !drawable()) return
    ctx.setTransform(scale, 0, 0, scale, 0, 0)
    ctx.clearRect(0, 0, WIDTH, HEIGHT)
    ctx.fillStyle = ink
    let moving = false
    const dt = Math.min(40, lastTime ? now - lastTime : 16)
    const follow = 1 - Math.exp(-dt / 65)
    pointer.x += (pointer.tx - pointer.x) * follow
    pointer.y += (pointer.ty - pointer.y) * follow
    pointer.k += (pointer.target - pointer.k) * follow
    if (Math.abs(pointer.k - pointer.target) > .003 || Math.abs(pointer.tx - pointer.x) + Math.abs(pointer.ty - pointer.y) > .2) moving = true
    for (let i = 0; i < points.length; i++) {
      const p = points[i]
      let burst = 0
      if (morph) {
        const distance = Math.hypot(p.x - morph.x, p.y - morph.y)
        const t = Math.min(1, Math.max(0, (now - morph.start - distance * .55) / 620))
        const ease = 1 - Math.pow(1 - t, 3)
        current[i] = morph.from[i] + (targets[selected][i] - morph.from[i]) * ease
        burst = Math.sin(t * Math.PI) * (1 - Math.min(1, distance / 270)) * 11
        if (t < 1) moving = true
      }
      let x = p.x, y = p.y
      const dx = x - pointer.x, dy = y - pointer.y
      const distance = Math.hypot(dx, dy)
      if (pointer.k > .001 && distance < 72) {
        const push = Math.pow(1 - distance / 72, 2) * pointer.k * 8
        x += dx / Math.max(1, distance) * push
        y += dy / Math.max(1, distance) * push
      }
      if (burst && morph) {
        const bx = p.x - morph.x, by = p.y - morph.y, length = Math.hypot(bx, by) || 1
        x += bx / length * burst
        y += by / length * burst
      }
      const edge = Math.max(0, Math.min(1, p.x / 28, (WIDTH - p.x) / 28, p.y / 20, (HEIGHT - p.y) / 20))
      const tone = current[i]
      ctx.globalAlpha = Math.min(.94, (.085 + tone * .84) * edge)
      ctx.beginPath()
      ctx.arc(x, y, .48 + Math.pow(tone, .74) * 2.05, 0, Math.PI * 2)
      ctx.fill()
    }
    ctx.globalAlpha = 1
    lastTime = now
    if (!moving) morph = null
    el.dataset.animating = moving ? 'true' : 'false'
    return moving
  }
  function frame(now) {
    raf = 0
    if (!drawable()) { stop(); return }
    if (draw(now)) raf = requestAnimationFrame(frame)
  }
  function wake() {
    if (reducedMotion()) { stop(); draw(); return }
    if (!raf && drawable()) raf = requestAnimationFrame(frame)
  }
  function select(index, origin = { x: WIDTH / 2, y: HEIGHT / 2 }) {
    if (destroyed || index === selected) return
    selected = index
    buttons.forEach((button, i) => button.setAttribute('aria-pressed', String(i === index)))
    stage.setAttribute('aria-label', `切换点阵插画，当前：${SHAPES[index].label}`)
    live.textContent = `插画：${SHAPES[index].label}`
    if (reducedMotion() || !drawable()) {
      current = targets[index].slice()
      morph = null
      draw()
    } else {
      morph = { from: current.slice(), start: performance.now(), ...origin }
      wake()
    }
  }
  stage.setAttribute('aria-label', '切换点阵插画，当前：对话')
  const position = event => {
    const r = stage.getBoundingClientRect()
    return { x: (event.clientX - r.left) / Math.max(1, r.width) * WIDTH, y: (event.clientY - r.top) / Math.max(1, r.height) * HEIGHT }
  }
  function move(event) {
    if (!finePointer.matches || reducedMotion()) return
    const p = position(event)
    pointer.tx = p.x; pointer.ty = p.y; pointer.target = 1
    wake()
  }
  function leave() { pointer.target = 0; wake() }
  function click(event) {
    const origin = event.detail ? position(event) : { x: WIDTH / 2, y: HEIGHT / 2 }
    select((selected + 1) % SHAPES.length, origin)
  }
  stage.addEventListener('pointermove', move, { passive: true })
  stage.addEventListener('pointerleave', leave, { passive: true })
  stage.addEventListener('click', click)
  function visibility() {
    if (document.hidden) stop()
    else { resize(); colors() }
  }
  document.addEventListener('visibilitychange', visibility)
  const resizeObserver = new ResizeObserver(resize)
  resizeObserver.observe(stage)
  const intersection = new IntersectionObserver(([entry]) => {
    visible = entry.isIntersecting
    if (visible) { resize(); colors() }
    else stop()
  })
  intersection.observe(el)
  const preferences = new MutationObserver(colors)
  preferences.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme', 'data-motion'] })
  const lifecycle = new MutationObserver(() => {
    if (el.isConnected) seenConnected = true
    else if (seenConnected) destroy()
  })
  lifecycle.observe(document.documentElement, { childList: true, subtree: true })
  motionQuery.addEventListener('change', colors)
  themeQuery.addEventListener('change', colors)
  function destroy() {
    if (destroyed) return
    stop()
    destroyed = true
    resizeObserver.disconnect()
    intersection.disconnect()
    preferences.disconnect()
    lifecycle.disconnect()
    motionQuery.removeEventListener('change', colors)
    themeQuery.removeEventListener('change', colors)
    document.removeEventListener('visibilitychange', visibility)
    stage.removeEventListener('pointermove', move)
    stage.removeEventListener('pointerleave', leave)
    stage.removeEventListener('click', click)
  }
  el.destroy = destroy
  return el
}
