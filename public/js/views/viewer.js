// Full-screen photo / video viewer. The photo grows out of its bubble and
// returns into it; drag down to dismiss (velocity-projected), pinch or
// double-tap to zoom, single tap to hide the controls.

import { h, icon, reducedMotion } from '../ui/dom.js'
import { spring, velocityTracker, project, rubberband } from '../ui/spring.js'
import { toast, lockApp, unlockApp, openMenu } from './overlay.js'
import { placeOnSide, foldSide } from '../ui/fold.js'

/**
 * actions: [{ id, icon, label, read?() → { count, on }, onSelect(viewer) }] — capsules along the foot, before
 * Save and Share (a chat's photo: Reply and Like; a moment's: Comment and Like; a memory: its chat).
 * reply: { placeholder, onSend(text), sent } — a field under them that answers the photo (a reply in the
 * chat, a comment on the moment).
 */
export function openViewer({ kind = 'image', thumb, src, fullSrc, w = 0, h: hh = 0, findThumb, label = 'Photo', images, index = 0, actions = [], reply = null }) {
  const previousFocus = document.activeElement
  const entries = kind === 'image' && Array.isArray(images) ? images.filter(image => image.src || image.fullSrc) : []
  const gallery = entries.length > 1 ? entries : []
  let selected = gallery.length ? Math.max(0, Math.min(gallery.length - 1, index)) : 0
  if (entries.length) ({ src, fullSrc, w = 0, h: hh = 0, label = 'Photo' } = entries[selected])
  src ||= fullSrc
  const layer = document.getElementById('overlays')
  const bg = h('div', { class: 'viewer-bg' })
  const media = kind === 'video'
    ? h('video', { class: 'viewer-media', src: fullSrc, controls: true, playsInline: true, autoplay: true, preload: 'metadata' })
    : h('img', { class: 'viewer-media', alt: label, draggable: false, src })
  const stage = h('div', { class: 'viewer-stage' }, media)
  // Back at the top's leading corner, everything else about the photo in "…" at the other.
  const closeBtn = h('button', { class: 'viewer-round', type: 'button', 'aria-label': 'Close' }, icon('arrow-left'))
  const moreBtn = h('button', { class: 'viewer-round', type: 'button', 'aria-label': 'More', 'aria-haspopup': 'menu' }, icon('ellipsis'))
  const counter = gallery.length ? h('span', { class: 'viewer-gallery-count sr-only', 'aria-live': 'polite' }) : null
  const top = h('div', { class: 'viewer-bar top' }, closeBtn, moreBtn)
  const shade = h('div', { class: 'viewer-shade', 'aria-hidden': 'true' })
  const root = h('div', { class: 'viewer', role: 'dialog', 'aria-modal': 'true', 'aria-label': label, tabindex: '-1', dataset: { kind } }, bg, stage, shade, top, counter)
  // Along the foot: which photo of how many (a dot each), what can be done with it — the caller's
  // capsules, then Save and Share — and, where it can be answered, a field to answer it.
  const dots = gallery.length ? h('div', { class: 'viewer-dots', role: 'group', 'aria-label': 'Photos' }) : null
  const dotButtons = gallery.map((image, i) => {
    const b = h('button', { class: 'viewer-dot', type: 'button', 'aria-label': `View photo ${i + 1}`, 'aria-pressed': String(i === selected) })
    b.addEventListener('click', () => select(i))
    dots.append(b)
    return b
  })
  const viewerApi = { close: () => close(), focusReply: () => replyInput?.focus() }
  const capsules = actions.map(a => {
    const count = h('span', { class: 'viewer-act-count tabular' })
    const b = h('button', { class: 'viewer-act', type: 'button', dataset: { act: a.id }, 'aria-label': a.label }, icon(a.icon), count)
    const paint = () => {
      const r = a.read?.() || {}
      count.textContent = r.count ? String(r.count) : ''
      b.classList.toggle('on', Boolean(r.on))
      if (r.on !== undefined) b.setAttribute('aria-pressed', String(Boolean(r.on)))
      b.setAttribute('aria-label', r.count ? `${a.label}, ${r.count}` : a.label)
    }
    b.addEventListener('click', async () => {
      await a.onSelect?.(viewerApi)
      paint()
      setTimeout(paint, 700) // and again once the server has answered
    })
    b.addEventListener('repaint', paint)
    paint()
    return b
  })
  const saveBtn = h('button', { class: 'viewer-act round', type: 'button', 'aria-label': 'Save' }, icon('download'))
  const shareBtn = h('button', { class: 'viewer-act round', type: 'button', 'aria-label': 'Share' }, icon('share'))
  const actRow = h('div', { class: 'viewer-acts' }, ...capsules, saveBtn, shareBtn)
  let replyInput = null
  let replyForm = null
  if (reply) {
    replyInput = h('input', { class: 'viewer-reply-input', type: 'text', enterkeyhint: 'send', autocomplete: 'off', placeholder: reply.placeholder || 'Reply', 'aria-label': reply.placeholder || 'Reply' })
    const send = h('button', { class: 'viewer-reply-send', type: 'submit', 'aria-label': 'Send', hidden: true }, icon('arrow-up'))
    replyForm = h('form', { class: 'viewer-reply' }, replyInput, send)
    replyInput.addEventListener('input', () => { send.hidden = !replyInput.value.trim() })
    replyForm.addEventListener('submit', async e => {
      e.preventDefault()
      const text = replyInput.value.trim()
      if (!text || send.disabled) return
      send.disabled = true
      try {
        await reply.onSend(text)
        replyInput.value = ''
        send.hidden = true
        replyInput.blur()
        toast(reply.sent || 'Sent', { type: 'ok' })
        for (const c of capsules) c.dispatchEvent(new Event('repaint'))
      } catch (err) {
        toast(err?.message || "Couldn't send", { type: 'error' })
      } finally { send.disabled = false }
    })
  }
  const dock = h('div', { class: 'viewer-bar bottom viewer-dock' }, dots, actRow, replyForm)
  root.append(dock)
  // The controls fade together (while the photo is dragged away, and as it closes).
  const chrome = v => { for (const el of [top, dock, shade]) el.style.opacity = v }
  layer.append(root)
  placeOnSide(root, foldSide(thumb))
  // The app behind can't be reached while the photo is up (held by the
  // viewer itself, so a sheet closing meanwhile doesn't change that, and
  // closing the viewer doesn't put back a lock that has since gone).
  lockApp(root)
  const pointers = new Map()
  let g = null
  let lastTap = 0
  let tapTimer = 0
  const vt = velocityTracker()

  // The photo fits its stage: the whole screen, or, standing half open like
  // a laptop, the upper half above the hinge (css/posture.css).
  let W = stage.clientWidth || root.clientWidth
  let H = stage.clientHeight || root.clientHeight
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
  // ix/iy/r: the crop and corner radius the photo still has from its bubble
  // (in the photo's own pixels), easing to none as it opens.
  const rest = { tx: (W - fw) / 2, ty: (H - fh) / 2, k: 1, ix: 0, iy: 0, r: 0 }
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
    media.style.clipPath = s.ix > 0.5 || s.iy > 0.5 || s.r > 0.5 ? `inset(${s.iy}px ${s.ix}px round ${s.r}px)` : ''
    bg.style.opacity = String(s.bg)
    root.style.setProperty('--shade', String(s.bg))
  }

  // The photo as its bubble shows it: scaled to cover the bubble, cropped
  // and rounded to it, so opening and closing carry the crop and corners
  // through rather than cutting from one shape to the other.
  const thumbRect = el => {
    if (!el?.isConnected) return null
    const r = el.getBoundingClientRect()
    const o = root.getBoundingClientRect()
    if (r.bottom < o.top || r.top > o.bottom || r.width < 2) return null
    const k = Math.max(r.width / fw, r.height / fh)
    const radius = parseFloat(getComputedStyle(el.closest('.bubble') || el).borderTopLeftRadius) || 0
    return {
      tx: r.left - o.left + r.width / 2 - (fw * k) / 2,
      ty: r.top - o.top + r.height / 2 - (fh * k) / 2,
      k,
      ix: Math.max(0, (fw - r.width / k) / 2),
      iy: Math.max(0, (fh - r.height / k) / 2),
      r: radius / k
    }
  }
  const crop = (a, b, p) => {
    s.ix = a.ix + ((b.ix || 0) - a.ix) * p
    s.iy = a.iy + ((b.iy || 0) - a.iy) * p
    s.r = a.r + ((b.r || 0) - a.r) * p
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
      damping: 0.9,
      response: 0.32,
      onUpdate: p => {
        s.tx = from.tx + (rest.tx - from.tx) * p
        s.ty = from.ty + (rest.ty - from.ty) * p
        s.k = from.k + (rest.k - from.k) * p
        crop(from, rest, Math.min(1, p))
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
    dotButtons.forEach((button, i) => {
      button.setAttribute('aria-pressed', String(i === selected))
      button.classList.toggle('on', i === selected)
    })
  }
  function fitMedia() {
    W = stage.clientWidth || root.clientWidth
    H = stage.clientHeight || root.clientHeight
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
    ;({ src, fullSrc, w = 0, h: hh = 0, label = 'Photo' } = gallery[i])
    media.src = src || fullSrc
    media.alt = label
    root.setAttribute('aria-label', label)
    root.classList.remove('chrome-off')
    chrome('')
    fitMedia()
    updateGallery()
    loadFull()
    if (!reducedMotion()) media.animate?.([{ opacity: .45 }, { opacity: 1 }], { duration: 160, easing: 'ease-out' })
  }
  updateGallery()
  const onResize = () => {
    if (!closing && ((stage.clientWidth || root.clientWidth) !== W || (stage.clientHeight || root.clientHeight) !== H)) {
      activeAnimation?.stop()
      clearTimeout(tapTimer)
      pointers.clear()
      g = null
      fitMedia()
    }
  }
  const resizeObserver = new ResizeObserver(onResize)
  resizeObserver.observe(root)
  resizeObserver.observe(stage)
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
      chrome('0')
      await animate({
        from: 0,
        to: 1,
        velocity: Math.abs(velocityY) / Math.max(1, H),
        damping: 1,
        response: 0.28,
        onUpdate: p => {
          s.tx = start.tx + (target.tx - start.tx) * p
          s.ty = start.ty + (target.ty - start.ty) * p
          s.k = start.k + (target.k - start.k) * p
          crop(start, target, p)
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
    unlockApp(root)
    document.removeEventListener('keydown', onKey)
    if (previousFocus?.isConnected && !previousFocus.closest?.('[inert]')) previousFocus.focus?.({ preventScroll: true })
  }

  const onKey = e => {
    if (e.defaultPrevented) return
    // Typing an answer: Escape leaves the field first, and the arrows move in the text.
    if (e.target === replyInput) {
      if (e.key === 'Escape') { e.preventDefault(); e.stopImmediatePropagation(); replyInput.blur() }
      return
    }
    if (e.key === 'Escape') { e.preventDefault(); e.stopImmediatePropagation(); close() }
    else if (gallery.length && ['ArrowLeft', 'ArrowRight'].includes(e.key)) {
      e.preventDefault()
      select(selected + (e.key === 'ArrowLeft' ? -1 : 1))
    } else if (kind === 'image' && e.key === 'Tab') {
      const buttons = [...root.querySelectorAll('button:not(:disabled), input')].filter(button => button.getClientRects().length && !button.closest('[hidden]'))
      const first = buttons[0], last = buttons.at(-1)
      if (e.shiftKey && (document.activeElement === first || !buttons.includes(document.activeElement))) { e.preventDefault(); last?.focus() }
      else if (!e.shiftKey && (document.activeElement === last || !buttons.includes(document.activeElement))) { e.preventDefault(); first?.focus() }
    }
  }
  document.addEventListener('keydown', onKey)
  closeBtn.addEventListener('click', () => close())
  // The photo as a file: to share (the share sheet, where Save Image lives on iPhone) or to keep.
  async function asFile() {
    const source = fullSrc || src
    const res = await fetch(source)
    if (!res.ok) throw new Error('Media unavailable')
    const blob = await res.blob()
    const ext = (blob.type.split('/')[1] || 'jpg').replace('jpeg', 'jpg').replace('svg+xml', 'svg')
    return new File([blob], `${kind === 'video' ? 'VID' : 'IMG'}_${Date.now()}.${ext}`, { type: blob.type })
  }
  async function share() {
    try {
      const file = await asFile()
      if (navigator.canShare?.({ files: [file] })) await navigator.share({ files: [file] })
      else window.open(fullSrc || src, '_blank', 'noopener')
    } catch (err) {
      if (err?.name !== 'AbortError') toast(`Couldn't share this ${kind === 'video' ? 'video' : 'photo'}`, { type: 'error' })
    }
  }
  async function save() {
    try {
      const file = await asFile()
      // iPhone keeps pictures through the share sheet (Save Image); elsewhere, a download.
      if (/iPhone|iPad/.test(navigator.userAgent) && navigator.canShare?.({ files: [file] })) return void await navigator.share({ files: [file] })
      const url = URL.createObjectURL(file)
      const a = h('a', { href: url, download: file.name })
      document.body.append(a)
      a.click()
      a.remove()
      setTimeout(() => URL.revokeObjectURL(url), 4000)
      toast('Saved', { type: 'ok' })
    } catch (err) {
      if (err?.name !== 'AbortError') toast(`Couldn't save this ${kind === 'video' ? 'video' : 'photo'}`, { type: 'error' })
    }
  }
  async function copyPhoto() {
    try {
      const file = await asFile()
      await navigator.clipboard.write([new ClipboardItem({ [file.type]: file })])
      toast('Copied', { type: 'ok' })
    } catch { toast("Couldn't copy this photo", { type: 'error' }) }
  }
  shareBtn.addEventListener('click', share)
  saveBtn.addEventListener('click', save)
  moreBtn.addEventListener('click', () => openMenu(moreBtn, [[
    { label: 'Save', icon: 'download', onSelect: save },
    { label: 'Share', icon: 'share', onSelect: share },
    ...(kind === 'image' && window.ClipboardItem ? [{ label: 'Copy', icon: 'copy', onSelect: copyPhoto }] : [])
  ]]))

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
      chrome(String(s.bg))
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
      chrome('')
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
        chrome('')
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
