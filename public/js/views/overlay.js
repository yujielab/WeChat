// Sheets, anchored menus, confirmations and toasts.

import { h, icon, transitionEnd, reducedMotion } from '../ui/dom.js'
import { spring, velocityTracker, project, rubberband } from '../ui/spring.js'
import { getLayout } from '../ui/viewport.js'
import { haptic } from '../ui/haptics.js'

const layer = () => document.getElementById('overlays')
const app = () => document.getElementById('app')
const open = new Set()

function lockApp() {
  app().inert = true
  app().setAttribute('aria-hidden', 'true')
}

function unlockApp() {
  if (open.size) return
  app().inert = false
  app().removeAttribute('aria-hidden')
}

const nextFrame = () => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(r)))

// ---------------------------------------------------------------- sheets

export function openSheet({ title, content, tall = false, start = null, end = null, label, onClose }) {
  const root = layer()
  root.dataset.layout = getLayout()
  const scrim = h('div', { class: 'scrim' })
  const closeBtn = end || h('button', { class: 'glass glass-btn', type: 'button', 'aria-label': '关闭' }, icon('xmark'))
  const head = h('div', { class: 'sheet-head' },
    start ? h('div', { class: 'start' }, start) : null,
    title ? h('h2', {}, title) : null,
    h('div', { class: 'end' }, closeBtn)
  )
  const body = h('div', { class: 'sheet-body' }, content)
  const sheet = h('div', {
    class: ['sheet', 'glass', 'glass-thick', tall && 'tall'],
    role: 'dialog',
    'aria-modal': 'true',
    'aria-label': label || title || '面板',
    tabindex: '-1'
  }, h('div', { class: 'grabber' }), head, body)

  const ctl = { el: sheet, body, closed: false, close }
  open.add(ctl)
  const prevFocus = document.activeElement
  root.append(scrim, sheet)
  lockApp()
  nextFrame().then(() => {
    scrim.classList.add('on')
    sheet.classList.add('on')
    sheet.focus({ preventScroll: true })
  })

  async function close(velocity = 0) {
    if (ctl.closed) return
    ctl.closed = true
    document.removeEventListener('keydown', onKey)
    scrim.classList.remove('on')
    if (velocity && getLayout() === 'stack' && !reducedMotion()) {
      const from = currentY()
      const to = sheet.offsetHeight + 60
      sheet.classList.add('dragging')
      await spring({ from, to, velocity, damping: 1, response: 0.3, onUpdate: y => { sheet.style.transform = `translate3d(0, ${y}px, 0)` } }).done
    } else {
      sheet.classList.remove('on')
      await transitionEnd(sheet, 'transform', 520)
    }
    scrim.remove()
    sheet.remove()
    open.delete(ctl)
    unlockApp()
    if (prevFocus?.isConnected) prevFocus.focus?.({ preventScroll: true })
    onClose?.()
  }

  const onKey = e => {
    if (e.key === 'Escape') close()
  }
  document.addEventListener('keydown', onKey)
  scrim.addEventListener('click', () => close())
  closeBtn.addEventListener('click', () => close())

  // Drag down to dismiss (folded layout), with velocity projection.
  let drag = null
  const currentY = () => {
    const m = /translate3d\(0px?, ([-\d.]+)px/.exec(sheet.style.transform)
    return m ? Number(m[1]) : 0
  }
  sheet.addEventListener('pointerdown', e => {
    if (getLayout() !== 'stack' || e.button > 0) return
    const inBody = body.contains(e.target)
    if (inBody && body.scrollTop > 0) return
    if (e.target.closest('input, textarea, .switch, .seg')) return
    drag = { id: e.pointerId, y0: e.clientY, x0: e.clientX, active: false, vt: velocityTracker(), inBody }
    drag.vt.add(0, e.clientY)
  })
  sheet.addEventListener('pointermove', e => {
    if (!drag || e.pointerId !== drag.id) return
    const dy = e.clientY - drag.y0
    const dx = e.clientX - drag.x0
    if (!drag.active) {
      if (Math.abs(dy) < 8 || Math.abs(dx) > Math.abs(dy)) return
      if (drag.inBody && (dy < 0 || body.scrollTop > 0)) {
        drag = null
        return
      }
      drag.active = true
      drag.y0 = e.clientY
      try { sheet.setPointerCapture(e.pointerId) } catch {}
      sheet.classList.add('dragging')
    }
    const d = e.clientY - drag.y0
    const y = d >= 0 ? d : rubberband(d, sheet.offsetHeight)
    drag.vt.add(0, e.clientY)
    sheet.style.transform = `translate3d(0, ${y}px, 0)`
  })
  const onDragEnd = e => {
    if (!drag || e.pointerId !== drag.id) return
    const was = drag
    drag = null
    if (!was.active) return
    const v = was.vt.velocity().y
    const y = currentY()
    if (y + project(v) > sheet.offsetHeight * 0.4 || v > 1100) {
      close(v)
      return
    }
    spring({ from: y, to: 0, velocity: v, damping: 0.86, response: 0.32, onUpdate: val => { sheet.style.transform = `translate3d(0, ${val}px, 0)` } })
      .done.then(() => {
        sheet.classList.remove('dragging')
        sheet.style.transform = ''
      })
  }
  sheet.addEventListener('pointerup', onDragEnd)
  sheet.addEventListener('pointercancel', onDragEnd)

  return ctl
}

export function closeAllOverlays() {
  for (const c of [...open]) c.close()
}

// ---------------------------------------------------------------- menus

/**
 * A glass menu anchored to `anchor` (an element or a {x, y, w, h} rect),
 * scaling out of it. `sections` is an array of item arrays:
 *   { label, icon, destructive, checked, disabled, onSelect }
 */
export function openMenu(anchor, sections, { title, preferAbove = false, onClose } = {}) {
  const root = layer()
  const scrim = h('div', { class: 'scrim clear' })
  const menu = h('div', { class: 'menu glass glass-thick', role: 'menu' })
  if (title) menu.append(h('div', { class: 'menu-title' }, title))
  const ctl = { el: menu, closed: false, close }
  sections.filter(s => s.length).forEach((items, i) => {
    if (i > 0) menu.append(h('div', { class: 'menu-sep', role: 'separator' }))
    for (const it of items) {
      const btn = h('button', {
        class: ['menu-item', it.destructive && 'destructive'],
        type: 'button',
        role: it.checked !== undefined ? 'menuitemradio' : 'menuitem',
        'aria-checked': it.checked !== undefined ? String(Boolean(it.checked)) : undefined,
        disabled: it.disabled
      },
      it.checked !== undefined ? (it.checked ? icon('check', 'check') : h('span', { class: 'check' })) : null,
      h('span', { class: 'label' }, it.label),
      it.icon ? icon(it.icon) : null)
      btn.addEventListener('click', async () => {
        await close()
        it.onSelect?.()
      })
      menu.append(btn)
    }
  })
  menu.style.visibility = 'hidden'
  root.append(scrim, menu)
  open.add(ctl)

  // Position next to the anchor, inside the safe frame.
  const raw = anchor instanceof Element ? anchor.getBoundingClientRect() : anchor
  const origin = root.getBoundingClientRect()
  const r = {
    x: (raw.x ?? raw.left) - origin.left,
    y: (raw.y ?? raw.top) - origin.top,
    w: raw.w ?? raw.width ?? 0,
    h: raw.h ?? raw.height ?? 0
  }
  const vw = root.clientWidth
  const vh = root.clientHeight
  const mw = menu.offsetWidth
  const mh = menu.offsetHeight
  const margin = 10
  const below = r.y + r.h + 8
  const above = r.y - 8 - mh
  let top = !preferAbove && below + mh < vh - margin ? below : above >= margin ? above : Math.max(margin, vh - mh - margin)
  const anchorCenter = r.x + r.w / 2
  let left = anchorCenter < vw / 2 ? r.x : r.x + r.w - mw
  left = Math.min(Math.max(margin, left), vw - mw - margin)
  top = Math.min(Math.max(margin, top), vh - mh - margin)
  menu.style.left = `${left}px`
  menu.style.top = `${top}px`
  menu.style.setProperty('--ox', `${Math.min(Math.max(anchorCenter - left, 0), mw)}px`)
  menu.style.setProperty('--oy', `${top >= r.y ? 0 : mh}px`)
  menu.style.visibility = ''
  nextFrame().then(() => menu.classList.add('on'))
  menu.querySelector('.menu-item:not(:disabled)')?.focus({ preventScroll: true })

  async function close() {
    if (ctl.closed) return
    ctl.closed = true
    document.removeEventListener('keydown', onKey)
    menu.classList.remove('on')
    await transitionEnd(menu, 'opacity', 260)
    menu.remove()
    scrim.remove()
    open.delete(ctl)
    onClose?.()
  }
  const onKey = e => {
    if (e.key === 'Escape') close()
  }
  document.addEventListener('keydown', onKey)
  scrim.addEventListener('pointerdown', e => {
    e.preventDefault()
    close()
  })
  return ctl
}

/** Confirmation for destructive actions, shown as a menu from its trigger. */
export function confirmAction(anchor, { title, confirm, destructive = true }) {
  return new Promise(resolve => {
    let chosen = false
    openMenu(anchor, [[{ label: confirm, destructive, onSelect: () => { chosen = true; resolve(true) } }], [{ label: '取消' }]], {
      title,
      onClose: () => { if (!chosen) resolve(false) }
    })
  })
}

// ---------------------------------------------------------------- toasts

let current = null

export function toast(text, { type = '', iconName, duration = 2400 } = {}) {
  current?.dismiss()
  const el = h('div', { class: ['toast', 'glass', type], role: 'status' },
    iconName || type ? icon(iconName || (type === 'error' ? 'exclaim' : 'check')) : null,
    h('span', {}, text))
  layer().append(el)
  if (type === 'error') haptic()
  const t = { dismiss }
  current = t
  requestAnimationFrame(() => requestAnimationFrame(() => el.classList.add('on')))
  const timer = setTimeout(dismiss, duration)
  async function dismiss() {
    clearTimeout(timer)
    if (current === t) current = null
    el.classList.remove('on')
    await transitionEnd(el, 'opacity', 400)
    el.remove()
  }
  return t
}
