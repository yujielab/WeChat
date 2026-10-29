// Full-screen photo / video viewer. The photo grows out of its bubble and
// returns into it; drag down to dismiss (velocity-projected), pinch or
// double-tap to zoom, single tap to hide the controls.

import { h, icon, reducedMotion } from '../ui/dom.js'
import { spring, velocityTracker, project, rubberband } from '../ui/spring.js'
import { toast } from './overlay.js'
import { placeOnSide, foldSide } from '../ui/fold.js'

export function openViewer({ kind = 'image', thumb, src, fullSrc, w = 0, h: hh = 0, findThumb, label = '图片', images, index = 0 }) {
  const previousFocus = document.activeElement
  const entries = kind === 'image' && Array.isArray(images) ? images.filter(image => image.src || image.fullSrc) : []
  const gallery = entries.length > 1 ? entries : []
  let selected = gallery.length ? Math.max(0, Math.min(gallery.length - 1, index)) : 0
  if (entries.length) ({ src, fullSrc, w = 0, h: hh = 0, label = '图片' } = entries[selected])
  src ||= fullSrc
  const layer = document.getElementById('overlays')
  const bg = h('div', { class: 'viewer-bg' })
  const media = kind === 'video'
    ? h('video', { class: 'viewer-media', src: fullSrc, controls: true, playsInline: true, autoplay: true, preload: 'metadata' })
    : h('img', { class: 'viewer-media', alt: label, draggable: false, src })
  const stage = h('div', { class: 'viewer-stage' }, media)
  const closeBtn = h('button', { class: 'glass glass-clear glass-btn', type: 'button', 'aria-label': '关闭' }, icon('xmark'))
  const shareBtn = h('button', { class: 'glass glass-clear glass-btn', type: 'button', 'aria-label': '分享或存储' }, icon('share'))
  const counter = gallery.length ? h('span', { class: 'viewer-gallery-count', 'aria-live': 'polite' }) : null
  const top = h('div', { class: 'viewer-bar top' }, closeBtn, counter, shareBtn)
  const root = h('div', { class: 'viewer', role: 'dialog', 'aria-modal': 'true', 'aria-label': label, tabindex: '-1' }, bg, stage, top)
  const previous = gallery.length ? h('button', { class: 'glass glass-clear glass-btn', type: 'button', 'aria-label': '上一张照片' }, icon('chevron-left')) : null
  const next = gallery.length ? h('button', { class: 'glass glass-clear glass-btn', type: 'button', 'aria-label': '下一张照片' }, icon('chevron-right')) : null
  const thumbnailBar = gallery.length ? h('div', { class: 'viewer-gallery-thumbnails', role: 'group', 'aria-label': '照片列表' }) : null
  const thumbnailButtons = gallery.map((image, i) => {
    const button = h('button', { class: 'viewer-gallery-thumb', type: 'button', 'aria-label': `查看第 ${i + 1} 张照片`, 'aria-pressed': String(i === selected) },
      h('img', { src: image.src || image.fullSrc, alt: '', loading: 'lazy', decoding: 'async', draggable: false }))
    button.addEventListener('click', () => select(i))
    thumbnailBar.append(button)
    return button
  })
  if (gallery.length) root.append(h('div', { class: 'viewer-bar bottom viewer-gallery-bottom' },
    h('div', { class: 'viewer-gallery-navigation' }, previous, next), thumbnailBar))
  layer.append(root)
  placeOnSide(root, foldSide(thumb))
  const app = document.getElementById('app')
  const wasInert = app.inert
  app.inert = true
  const pointers = new Map()
  let g = null
  let lastTap = 0
  let tapTimer = 0
  const vt = velocityTracker()

  let W = root.clientWidth
  let H = root.clientHeight
  const nat = { w: thumb?.naturalWidth || w || 1, h: thumb?.naturalHeight || hh || 1 }
  if (w && hh) {
    nat.w = w
    nat.h = hh
  }
  let fit = Math.min(W / nat.w, H / nat.h)
  let fw = nat.w * fit
  let fh = nat.h * fit
  media.style.width = `${fw}px`
  media.style.height = `${fh}px`
  const rest = { tx: (W - fw) / 2, ty: (H - fh) / 2, k: 1 }
  const s = { ...rest, bg: 0 }
  let activeAnimation = null
  let fullImageRequest = 0
  let navigated = false
  const animate = options => {
    activeAnimation?.stop()
    activeAnimation = spring(options)
    return activeAnimation
  }

  const apply = () => {
    media.style.transform = `translate3d(${s.tx}px, ${s.ty}px, 0) scale(${s.k})`
    bg.style.opacity = String(s.bg)
    root.style.setProperty('--shade', String(s.bg))
  }

  const thumbRect = el => {
    if (!el?.isConnected) return null
    const r = el.getBoundingClientRect()
    const o = root.getBoundingClientRect()
    if (r.bottom < o.top || r.top > o.bottom || r.width < 2) return null
    return { tx: r.left - o.left, ty: r.top - o.top, k: r.width / fw }
  }

  // ---------------------------------------------------------- open
  const from = thumbRect(thumb)
  if (thumb) thumb.style.visibility = 'hidden'
  if (from && !reducedMotion()) {
    Object.assign(s, from, { bg: 0 })
    apply()
    animate({
      from: 0,
      to: 1,
      damping: 0.86,
      response: 0.38,
      onUpdate: p => {
        s.tx = from.tx + (rest.tx - from.tx) * p
        s.ty = from.ty + (rest.ty - from.ty) * p
        s.k = from.k + (rest.k - from.k) * p
        s.bg = Math.min(1, p)
        apply()
      }
    })
  } else {
    Object.assign(s, rest, { bg: 1 })
    apply()
    root.animate?.([{ opacity: 0 }, { opacity: 1 }], { duration: 160, easing: 'linear' })
  }
  root.focus({ preventScroll: true })

  function loadFull() {
    const request = ++fullImageRequest
    if (kind !== 'image' || !fullSrc || fullSrc === src) return
    const full = new Image()
    full.decoding = 'async'
    const target = fullSrc
    full.onload = () => {
      if (root.isConnected && request === fullImageRequest) media.src = target
    }
    full.src = target
  }
  loadFull()

  function updateGallery() {
    if (!gallery.length) return
    counter.textContent = `${selected + 1} / ${gallery.length}`
    previous.disabled = selected === 0
    next.disabled = selected === gallery.length - 1
    thumbnailButtons.forEach((button, i) => button.setAttribute('aria-pressed', String(i === selected)))
    thumbnailButtons[selected]?.scrollIntoView({ block: 'nearest', inline: 'nearest' })
  }
  function fitMedia() {
    W = root.clientWidth
    H = root.clientHeight
    nat.w = w || media.naturalWidth || 1
    nat.h = hh || media.naturalHeight || 1
    fit = Math.min(W / nat.w, H / nat.h)
    fw = nat.w * fit
    fh = nat.h * fit
    media.style.width = `${fw}px`
    media.style.height = `${fh}px`
    Object.assign(rest, { tx: (W - fw) / 2, ty: (H - fh) / 2, k: 1 })
    Object.assign(s, rest, { bg: 1 })
    apply()
  }
  function select(i) {
    if (closing || i < 0 || i >= gallery.length || i === selected) return
    activeAnimation?.stop()
    clearTimeout(tapTimer)
    pointers.clear()
    g = null
    selected = i
    navigated = true
    ;({ src, fullSrc, w = 0, h: hh = 0, label = '图片' } = gallery[i])
    media.src = src || fullSrc
    media.alt = label
    root.setAttribute('aria-label', label)
    root.classList.remove('chrome-off')
    top.style.opacity = ''
    fitMedia()
    updateGallery()
    loadFull()
    if (!reducedMotion()) media.animate?.([{ opacity: .45 }, { opacity: 1 }], { duration: 160, easing: 'ease-out' })
  }
  previous?.addEventListener('click', () => select(selected - 1))
  next?.addEventListener('click', () => select(selected + 1))
  updateGallery()
  const onResize = () => {
    if (!closing && (root.clientWidth !== W || root.clientHeight !== H)) {
      activeAnimation?.stop()
      clearTimeout(tapTimer)
      pointers.clear()
      g = null
      fitMedia()
    }
  }
  const resizeObserver = new ResizeObserver(onResize)
  resizeObserver.observe(root)
  if (kind === 'image') media.addEventListener('load', () => {
    if (!closing && (!w || !hh)) { activeAnimation?.stop(); fitMedia() }
  })

  // ---------------------------------------------------------- close
  let closing = false
  async function close(velocityY = 0) {
    if (closing) return
    closing = true
    activeAnimation?.stop()
    fullImageRequest++
    resizeObserver.disconnect()
    clearTimeout(tapTimer)
    // A different photo has no geometric identity with the original cover.
    const target = navigated ? null : thumbRect(findThumb?.() || thumb)
    if (target && !reducedMotion()) {
      const start = { ...s }
      top.style.opacity = '0'
      await animate({
        from: 0,
        to: 1,
        velocity: Math.abs(velocityY) / Math.max(1, H),
        damping: 1,
        response: 0.32,
        onUpdate: p => {
          s.tx = start.tx + (target.tx - start.tx) * p
          s.ty = start.ty + (target.ty - start.ty) * p
          s.k = start.k + (target.k - start.k) * p
          s.bg = start.bg * (1 - p)
          apply()
        }
      }).done
    } else {
      root.style.transition = reducedMotion() ? 'none' : 'opacity 180ms ease-out'
      root.style.opacity = '0'
      if (!reducedMotion()) await new Promise(r => setTimeout(r, 180))
    }
    if (thumb) thumb.style.visibility = ''
    const t2 = findThumb?.()
    if (t2) t2.style.visibility = ''
    if (kind === 'video') media.pause()
    root.remove()
    app.inert = wasInert
    document.removeEventListener('keydown', onKey)
    if (previousFocus?.isConnected && !previousFocus.closest?.('[inert]')) previousFocus.focus?.({ preventScroll: true })
  }

  const onKey = e => {
    if (e.defaultPrevented) return
    if (e.key === 'Escape') { e.preventDefault(); e.stopImmediatePropagation(); close() }
    else if (gallery.length && ['ArrowLeft', 'ArrowRight'].includes(e.key)) {
      e.preventDefault()
      select(selected + (e.key === 'ArrowLeft' ? -1 : 1))
    } else if (kind === 'image' && e.key === 'Tab') {
      const buttons = [...root.querySelectorAll('button:not(:disabled)')].filter(button => button.getClientRects().length && !button.closest('[hidden]'))
      const first = buttons[0], last = buttons.at(-1)
      if (e.shiftKey && (document.activeElement === first || !buttons.includes(document.activeElement))) { e.preventDefault(); last?.focus() }
      else if (!e.shiftKey && (document.activeElement === last || !buttons.includes(document.activeElement))) { e.preventDefault(); first?.focus() }
    }
  }
  document.addEventListener('keydown', onKey)
  closeBtn.addEventListener('click', () => close())
  shareBtn.addEventListener('click', async () => {
    const source = fullSrc || src
    try {
      const res = await fetch(source)
      if (!res.ok) throw new Error('Media unavailable')
      const blob = await res.blob()
      const ext = (blob.type.split('/')[1] || 'jpg').replace('jpeg', 'jpg').replace('svg+xml', 'svg')
      const file = new File([blob], `${kind === 'video' ? 'VID' : 'IMG'}_${Date.now()}.${ext}`, { type: blob.type })
      if (navigator.canShare?.({ files: [file] })) await navigator.share({ files: [file] })
      else window.open(source, '_blank', 'noopener')
    } catch (err) {
      if (err?.name !== 'AbortError') toast('无法分享这张图片', { type: 'error' })
    }
  })

  if (kind === 'video') return { close }

  // ---------------------------------------------------------- gestures
  const clampRest = (velocity = { x: 0, y: 0 }) => {
    if (closing) return
    const k = Math.min(Math.max(s.k, 1), 4)
    const sw = fw * k
    const sh = fh * k
    const clamp = (v, size, view) => (size <= view ? (view - size) / 2 : Math.min(0, Math.max(view - size, v)))
    const target = k === 1 ? rest : { tx: clamp(s.tx, sw, W), ty: clamp(s.ty, sh, H), k }
    const start = { ...s }
    animate({
      from: 0,
      to: 1,
      damping: 1,
      response: 0.34,
      velocity: Math.hypot(velocity.x, velocity.y) / Math.max(W, H) / 2,
      onUpdate: p => {
        s.tx = start.tx + (target.tx - start.tx) * p
        s.ty = start.ty + (target.ty - start.ty) * p
        s.k = start.k + (target.k - start.k) * p
        s.bg = start.bg + (1 - start.bg) * p
        apply()
      }
    })
  }

  const zoomAt = (x, y, k) => {
    if (closing) return
    const start = { ...s }
    const ratio = k / s.k
    const target = { tx: x - (x - s.tx) * ratio, ty: y - (y - s.ty) * ratio, k }
    animate({
      from: 0,
      to: 1,
      damping: 1,
      response: 0.32,
      onUpdate: p => {
        s.tx = start.tx + (target.tx - start.tx) * p
        s.ty = start.ty + (target.ty - start.ty) * p
        s.k = start.k + (target.k - start.k) * p
        apply()
      }
    }).done.then(finished => { if (finished && !closing) clampRest() })
  }

  stage.addEventListener('pointerdown', e => {
    if (closing) return
    activeAnimation?.stop()
    try { stage.setPointerCapture(e.pointerId) } catch {}
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY })
    const o = root.getBoundingClientRect()
    if (pointers.size === 1) {
      vt.reset()
      vt.add(e.clientX, e.clientY)
      g = { mode: 'tap', x0: e.clientX, y0: e.clientY, start: { ...s }, ox: o.left, oy: o.top }
    } else if (pointers.size === 2) {
      const [a, b] = [...pointers.values()]
      g = {
        mode: 'pinch',
        d0: Math.hypot(a.x - b.x, a.y - b.y),
        mx: (a.x + b.x) / 2 - o.left,
        my: (a.y + b.y) / 2 - o.top,
        start: { ...s }
      }
    }
  })

  stage.addEventListener('pointermove', e => {
    if (!pointers.has(e.pointerId) || !g) return
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY })
    if (g.mode === 'pinch') {
      if (pointers.size < 2) return
      const [a, b] = [...pointers.values()]
      const k = Math.max(0.6, g.start.k * (Math.hypot(a.x - b.x, a.y - b.y) / g.d0))
      const ratio = k / g.start.k
      s.k = k
      s.tx = g.mx - (g.mx - g.start.tx) * ratio
      s.ty = g.my - (g.my - g.start.ty) * ratio
      apply()
      return
    }
    const dx = e.clientX - g.x0
    const dy = e.clientY - g.y0
    vt.add(e.clientX, e.clientY)
    if (g.mode === 'tap') {
      if (Math.hypot(dx, dy) < 8) return
      g.mode = s.k > 1.02 ? 'pan' : gallery.length && Math.abs(dx) > Math.abs(dy) * 1.3 ? 'navigate' : 'dismiss'
    }
    if (g.mode === 'pan') {
      s.tx = g.start.tx + dx
      s.ty = g.start.ty + dy
      const sw = fw * s.k
      const sh = fh * s.k
      const minX = Math.min(0, W - sw)
      const minY = Math.min(0, H - sh)
      if (s.tx > 0) s.tx = rubberband(s.tx, W)
      if (s.tx < minX) s.tx = minX + rubberband(s.tx - minX, W)
      if (s.ty > 0) s.ty = rubberband(s.ty, H)
      if (s.ty < minY) s.ty = minY + rubberband(s.ty - minY, H)
      apply()
    } else if (g.mode === 'navigate') {
      s.tx = rest.tx + rubberband(dx, W)
      apply()
    } else if (g.mode === 'dismiss') {
      const shrink = 1 - Math.min(0.35, Math.abs(dy) / H * 0.6)
      s.k = shrink
      s.tx = rest.tx + dx + (fw * (1 - shrink)) / 2
      s.ty = rest.ty + dy + (fh * (1 - shrink)) / 2
      s.bg = Math.max(0, 1 - Math.abs(dy) / (H * 0.5))
      top.style.opacity = String(s.bg)
      apply()
    }
  })

  const up = e => {
    if (closing) { pointers.clear(); g = null; return }
    if (!pointers.has(e.pointerId)) return
    pointers.delete(e.pointerId)
    if (!g) return
    if (g.mode === 'pinch') {
      if (pointers.size === 0) {
        g = null
        clampRest()
      }
      return
    }
    const mode = g.mode
    const at = { x: e.clientX - g.ox, y: e.clientY - g.oy }
    g = null
    const v = vt.velocity()
    if (e.type === 'pointercancel') {
      top.style.opacity = ''
      clampRest()
    } else if (mode === 'navigate') {
      const displacement = s.tx - rest.tx
      const target = selected + (displacement < 0 ? 1 : -1)
      if ((Math.abs(displacement) > 35 || Math.abs(v.x) > 500) && target >= 0 && target < gallery.length) select(target)
      else clampRest()
    } else if (mode === 'tap') {
      const now = performance.now()
      if (now - lastTap < 280) {
        clearTimeout(tapTimer)
        lastTap = 0
        zoomAt(at.x, at.y, s.k > 1.05 ? 1 : 2.5)
      } else {
        lastTap = now
        tapTimer = setTimeout(() => root.classList.toggle('chrome-off'), 280)
      }
    } else if (mode === 'dismiss') {
      const dy = s.ty - rest.ty
      if (Math.abs(dy + project(v.y)) > H * 0.22 || Math.abs(v.y) > 900) close(v.y)
      else {
        top.style.opacity = ''
        clampRest(v)
      }
    } else if (mode === 'pan') {
      clampRest(v)
    }
  }
  stage.addEventListener('pointerup', up)
  stage.addEventListener('pointercancel', up)

  return { close, select, get index() { return selected } }
}
