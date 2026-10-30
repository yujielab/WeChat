// Sheets, anchored menus, confirmations and toasts.

import { h, icon, transitionEnd, reducedMotion, stagger } from '../ui/dom.js'
import { symbolEffect } from '../ui/symbols.js'
import { spring, velocityTracker, project, rubberband } from '../ui/spring.js'
import { getLayout } from '../ui/viewport.js'
import { placeOnSide, foldSide } from '../ui/fold.js'
import { haptic } from '../ui/haptics.js'
import { dimThemeColor } from '../ui/appearance.js'

const layer = () => document.getElementById('overlays')
const app = () => document.getElementById('app')
const open = new Set()
const topmost = () => [...open].at(-1)

// Only the frontmost surface receives keyboard navigation. In particular,
// Escape from an editor should return to Settings, rather than close both.
function trapTab(event, surface) {
  if (event.key !== 'Tab') return
  const targets = [...surface.querySelectorAll('button:not(:disabled), input:not(:disabled), textarea:not(:disabled), select:not(:disabled), a[href], [tabindex="0"]')]
    .filter(el => el.getClientRects().length && !el.closest('[hidden], [inert]'))
  const first = targets[0]
  const last = targets.at(-1)
  if (!first) {
    event.preventDefault()
    surface.focus({ preventScroll: true })
  } else if (event.shiftKey && (document.activeElement === first || !surface.contains(document.activeElement))) {
    event.preventDefault()
    last.focus({ preventScroll: true })
  } else if (!event.shiftKey && (document.activeElement === last || !surface.contains(document.activeElement))) {
    event.preventDefault()
    first.focus({ preventScroll: true })
  }
}

function restoreFocus(previous) {
  const front = topmost()
  if (front && !front.el.contains(previous)) {
    if (!front.el.contains(document.activeElement)) front.el.focus?.({ preventScroll: true })
    return
  }
  if (previous?.isConnected && !previous.closest?.('[inert]')) previous.focus?.({ preventScroll: true })
  else front?.el.focus?.({ preventScroll: true })
}

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

// The app recedes behind sheets on the folded screen (see .app.sheeted).
let receding = 0
function recede(on) {
  receding = Math.max(0, receding + (on ? 1 : -1))
  app().classList.toggle('sheeted', receding > 0)
  if (!receding) setPresence(null)
}
function setPresence(p) {
  if (p === null) {
    app().style.removeProperty('--sp')
    app().classList.remove('sheet-drag')
  } else {
    app().style.setProperty('--sp', String(Math.min(1, Math.max(0, p)).toFixed(4)))
  }
}

// ---------------------------------------------------------------- sheets

export function openSheet({ title, content, tall = false, start = null, end = null, label, side, onClose }) {
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
  // Sections settle in one after another once the sheet lands.
  const sections = content instanceof Element && content.children.length > 1 ? [...content.children] : [content].filter(n => n instanceof Element)
  for (const el of sections.slice(0, 12)) el.classList.add('sheet-reveal')
  stagger(sections.slice(0, 12))
  const sheet = h('div', {
    class: ['sheet', 'glass', 'glass-thick', tall && 'tall'],
    role: 'dialog',
    'aria-modal': 'true',
    'aria-label': label || title || '面板',
    tabindex: '-1'
  }, h('div', { class: 'grabber' }), head, body)

  const ctl = { el: sheet, body, scrim, closed: false, close }
  let settleRun = null
  open.add(ctl)
  const prevFocus = document.activeElement
  root.append(scrim, sheet)
  placeOnSide(sheet, side)
  lockApp()
  const recedes = getLayout() === 'stack' && !reducedMotion()
  let receded = false
  nextFrame().then(() => {
    if (ctl.closed) return
    scrim.classList.add('on')
    sheet.classList.add('on')
    if (recedes) {
      receded = true
      recede(true)
    }
    dimThemeColor(scrim)
    sheet.focus({ preventScroll: true })
  })
  const unrecede = () => {
    if (!receded) return
    receded = false
    recede(false)
  }
  // Sheet travel → app presence, while the finger or a spring moves it.
  const track = y => {
    if (receded) setPresence(1 - y / Math.max(1, sheet.offsetHeight))
  }

  async function close(velocity = 0) {
    if (ctl.closed) return
    ctl.closed = true
    settleRun?.stop()
    document.removeEventListener('keydown', onKey)
    scrim.classList.remove('on')
    dimThemeColor([...open].reverse().find(o => o !== ctl && o.scrim)?.scrim || null)
    // The app is back in use the moment the sheet starts to leave: taps go
    // through the fading scrim and the sheet, and focus returns now.
    scrim.style.pointerEvents = sheet.style.pointerEvents = 'none'
    open.delete(ctl)
    unlockApp()
    restoreFocus(prevFocus)
    // Folded, the sheet always leaves on the spring a drag hands off to, so
    // Close, Escape, the scrim and a flick all feel the same; a flick keeps
    // its momentum.
    if (getLayout() === 'stack' && !reducedMotion()) {
      const from = currentY()
      const to = sheet.offsetHeight + 60
      sheet.classList.add('dragging')
      // The app grows back frame by frame with the sheet, not on its own timing.
      if (receded) app().classList.add('sheet-drag')
      const run = spring({ from, to, velocity, damping: 1, response: 0.3, onUpdate: y => { sheet.style.transform = `translate3d(0, ${y}px, 0)`; track(y) } })
      await run.done
      unrecede()
    } else {
      sheet.classList.remove('on')
      unrecede()
      // Leaving is quicker than arriving: don't wait out the whole spring.
      if (!reducedMotion()) await transitionEnd(sheet, 'transform', 420)
    }
    scrim.remove()
    sheet.remove()
    onClose?.()
  }

  const onKey = e => {
    if (topmost() !== ctl || e.defaultPrevented) return
    if (e.key === 'Escape') {
      e.preventDefault()
      e.stopImmediatePropagation()
      close()
    } else trapTab(e, sheet)
  }
  document.addEventListener('keydown', onKey)
  scrim.addEventListener('click', () => close())
  closeBtn.addEventListener('click', () => close())

  // Drag down to dismiss (folded layout), with velocity projection.
  let drag = null
  const currentY = () => {
    const transform = getComputedStyle(sheet).transform
    return transform === 'none' ? 0 : new DOMMatrixReadOnly(transform).m42
  }
  sheet.addEventListener('pointerdown', e => {
    if (getLayout() !== 'stack' || e.button > 0 || ctl.closed || topmost() !== ctl) return
    const inBody = body.contains(e.target)
    if (inBody && body.scrollTop > 0) return
    if (e.target.closest('input, textarea, .switch, .seg')) return
    drag = { id: e.pointerId, y0: e.clientY, x0: e.clientX, active: false, vt: velocityTracker(), inBody, from: currentY() }
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
      drag.from = currentY()
      settleRun?.stop()
      drag.active = true
      drag.y0 = e.clientY
      try { sheet.setPointerCapture(e.pointerId) } catch {}
      sheet.classList.add('dragging')
      if (receded) app().classList.add('sheet-drag')
    }
    const d = e.clientY - drag.y0 + drag.from
    const y = d >= 0 ? d : rubberband(d, sheet.offsetHeight)
    drag.vt.add(0, e.clientY)
    sheet.style.transform = `translate3d(0, ${y}px, 0)`
    track(Math.max(0, y))
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
    const run = settleRun = spring({ from: y, to: 0, velocity: v, damping: 0.86, response: 0.32, onUpdate: val => { sheet.style.transform = `translate3d(0, ${val}px, 0)`; track(Math.max(0, val)) } })
    run.done.then(finished => {
        if (!finished || ctl.closed || settleRun !== run) return
        settleRun = null
        sheet.classList.remove('dragging')
        sheet.style.transform = ''
        if (receded && !ctl.closed) {
          app().classList.remove('sheet-drag')
          setPresence(1)
        }
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
let nextMenuId = 0

export function openMenu(anchor, sections, { title, header, preferAbove = false, onClose } = {}) {
  const root = layer()
  const scrim = h('div', { class: 'scrim clear' })
  const safeFrame = h('span', { class: 'menu-safe-frame', 'aria-hidden': 'true', inert: true })
  const highlight = h('span', { class: 'menu-highlight', 'aria-hidden': 'true' })
  const menu = h('div', {
    class: 'menu glass glass-thick', role: 'menu', tabindex: '-1',
    id: `duo-menu-${++nextMenuId}`, 'aria-label': title || '操作'
  }, highlight)
  const prevFocus = document.activeElement
  const trigger = anchor instanceof Element ? anchor : null
  const previousExpanded = trigger?.getAttribute('aria-expanded')
  const previousControls = trigger?.getAttribute('aria-controls')
  trigger?.setAttribute('aria-haspopup', 'menu')
  trigger?.setAttribute('aria-expanded', 'true')
  trigger?.setAttribute('aria-controls', menu.id)
  if (title) menu.append(h('div', { class: 'menu-title' }, title))
  const ctl = { el: menu, closed: false, close }
  // A custom first row (e.g. reactions) closes the menu like an item does.
  if (header) menu.append(header(async run => {
    if (ctl.closed) return
    await close(false)
    try { run?.() } finally { onClose?.() }
  }))
  const choices = []
  let active = null
  let placementFrame = 0
  let highlightFrame = 0
  let resizeObserver = null
  let closing = null
  let typed = ''
  let typedAt = 0

  sections.filter(s => s.length).forEach((items, i) => {
    if (i > 0) menu.append(h('div', { class: 'menu-sep', role: 'separator' }))
    for (const it of items) {
      const checkable = it.checked !== undefined
      const btn = h('button', {
        class: ['menu-item', it.destructive && 'destructive'],
        type: 'button',
        role: checkable ? (it.toggle ? 'menuitemcheckbox' : 'menuitemradio') : 'menuitem',
        'aria-checked': checkable ? String(Boolean(it.checked)) : undefined,
        disabled: it.disabled
      },
      checkable ? h('span', { class: 'menu-choice', 'aria-hidden': 'true' }, it.checked ? icon('check') : null) : null,
      it.icon ? icon(it.icon, 'menu-action-icon') : null,
      h('span', { class: 'label' }, it.label))
      btn.addEventListener('click', async () => {
        if (ctl.closed) return
        await close(false)
        try { it.onSelect?.() } finally { onClose?.() }
      })
      menu.append(btn)
      if (!it.disabled) choices.push(btn)
    }
  })
  menu.style.visibility = 'hidden'
  root.append(scrim, safeFrame, menu)
  placeOnSide(safeFrame, foldSide(trigger))
  open.add(ctl)

  // The same surface follows pointer and keyboard focus. Its geometry is
  // measured from the real row, so text scaling and scrolling stay aligned.
  function placeHighlight() {
    if (!active || !active.isConnected || ctl.closed) return
    highlight.style.width = `${active.offsetWidth}px`
    highlight.style.height = `${active.offsetHeight}px`
    highlight.style.transform = `translate3d(${active.offsetLeft}px, ${active.offsetTop}px, 0)`
    menu.classList.toggle('destructive-focus', active.classList.contains('destructive'))
    menu.classList.add('has-highlight')
    if (!highlight.classList.contains('ready')) {
      cancelAnimationFrame(highlightFrame)
      highlightFrame = requestAnimationFrame(() => highlight.classList.add('ready'))
    }
  }
  function focusChoice(btn) {
    if (!btn) return
    btn.focus({ preventScroll: true })
    btn.scrollIntoView({ block: 'nearest', inline: 'nearest' })
  }
  menu.addEventListener('focusin', e => {
    const btn = e.target.closest('.menu-item')
    if (!btn || btn.disabled || !menu.contains(btn)) return
    active = btn
    placeHighlight()
  })
  menu.addEventListener('pointermove', e => {
    if ((e.pointerType && e.pointerType !== 'mouse') || ctl.closed) return
    const btn = e.target.closest('.menu-item')
    if (btn && !btn.disabled && menu.contains(btn) && btn !== active) btn.focus({ preventScroll: true })
  })

  // Re-read the anchor on resize instead of retaining geometry from the old
  // posture. Keep the menu inside the visual viewport when the keyboard moves.
  function positionMenu() {
    placementFrame = 0
    if (ctl.closed) return
    if (trigger && (!trigger.isConnected || !trigger.getClientRects().length)) { close(); return }
    const raw = trigger ? trigger.getBoundingClientRect() : anchor
    const origin = root.getBoundingClientRect()
    const r = {
      x: (raw.x ?? raw.left) - origin.left,
      y: (raw.y ?? raw.top) - origin.top,
      w: raw.w ?? raw.width ?? 0,
      h: raw.h ?? raw.height ?? 0
    }
    const bounds = safeFrame.getBoundingClientRect()
    const minX = bounds.left - origin.left, minY = bounds.top - origin.top
    const maxX = bounds.right - origin.left, maxY = bounds.bottom - origin.top
    menu.style.maxWidth = `${Math.max(0, bounds.width)}px`
    menu.style.maxHeight = `${Math.max(0, bounds.height)}px`
    const mw = menu.offsetWidth, mh = menu.offsetHeight
    const anchorCenter = r.x + r.w / 2
    // From a bar at the foot of a column, the menu grows upward out of it.
    const up = preferAbove || Boolean(trigger?.closest('.list-bottombar, .composer, .side-bottombar, .art-bottombar'))
    const below = r.y + r.h + 6
    const above = r.y - 6 - mh
    let top = !up && below + mh <= maxY ? below : above >= minY ? above : Math.max(minY, maxY - mh)
    let left = anchorCenter < (minX + maxX) / 2 ? r.x : r.x + r.w - mw
    left = Math.max(minX, Math.min(left, maxX - mw))
    top = Math.max(minY, Math.min(top, maxY - mh))
    menu.style.setProperty('--ox', `${Math.min(Math.max(anchorCenter - left, 0), mw)}px`)
    menu.style.setProperty('--oy', `${top >= r.y ? 0 : mh}px`)
    menu.style.setProperty('--menu-lift', top >= r.y ? '-4px' : '4px')
    menu.style.left = `${Math.round(left)}px`
    menu.style.top = `${Math.round(top)}px`
    placeHighlight()
  }
  function schedulePosition() {
    if (!placementFrame && !ctl.closed) placementFrame = requestAnimationFrame(positionMenu)
  }
  positionMenu()
  menu.style.visibility = ''
  if (!ctl.closed) {
    resizeObserver = new ResizeObserver(schedulePosition)
    resizeObserver.observe(root)
    resizeObserver.observe(safeFrame)
    resizeObserver.observe(menu)
    window.addEventListener('resize', schedulePosition)
    window.visualViewport?.addEventListener('resize', schedulePosition)
    window.visualViewport?.addEventListener('scroll', schedulePosition)
    document.addEventListener('scroll', schedulePosition, { capture: true, passive: true })
    document.addEventListener('keydown', onKey)
  }
  nextFrame().then(() => {
    if (ctl.closed) return
    menu.classList.add('on')
    ;(choices[0] || menu).focus({ preventScroll: true })
  })

  function close(notify = true) {
    if (ctl.closed) return closing || Promise.resolve()
    ctl.closed = true
    cancelAnimationFrame(placementFrame)
    cancelAnimationFrame(highlightFrame)
    resizeObserver?.disconnect()
    document.removeEventListener('keydown', onKey)
    document.removeEventListener('scroll', schedulePosition, true)
    window.removeEventListener('resize', schedulePosition)
    window.visualViewport?.removeEventListener('resize', schedulePosition)
    window.visualViewport?.removeEventListener('scroll', schedulePosition)
    menu.classList.remove('on')
    // Release ownership before waiting, so an older menu cannot clear the
    // expanded state of a newer menu opened from the same button.
    if (trigger?.isConnected) {
      if (previousExpanded === null) trigger.removeAttribute('aria-expanded')
      else trigger.setAttribute('aria-expanded', previousExpanded)
      if (previousControls === null) trigger.removeAttribute('aria-controls')
      else trigger.setAttribute('aria-controls', previousControls)
    }
    closing = (async () => {
      if (!reducedMotion()) await transitionEnd(menu, 'opacity', 220)
      menu.remove()
      scrim.remove()
      safeFrame.remove()
      open.delete(ctl)
      restoreFocus(prevFocus)
      if (notify) onClose?.()
    })()
    return closing
  }
  function onKey(e) {
    if (topmost() !== ctl || e.defaultPrevented || ctl.closed) return
    if (e.key === 'Escape') {
      e.preventDefault()
      e.stopImmediatePropagation()
      close()
    } else if (['ArrowDown', 'ArrowUp', 'Home', 'End'].includes(e.key)) {
      e.preventDefault()
      if (!choices.length) return
      const current = choices.indexOf(document.activeElement)
      const next = e.key === 'Home' ? 0 : e.key === 'End' ? choices.length - 1 : current < 0 ? (e.key === 'ArrowUp' ? choices.length - 1 : 0) : (current + (e.key === 'ArrowUp' ? -1 : 1) + choices.length) % choices.length
      focusChoice(choices[next])
    } else if (e.key === 'Tab') {
      trapTab(e, menu)
    } else if (!e.isComposing && e.key.length === 1 && e.key.trim() && !e.ctrlKey && !e.metaKey && !e.altKey) {
      const now = performance.now()
      typed = now - typedAt > 650 ? e.key.toLocaleLowerCase() : typed + e.key.toLocaleLowerCase()
      typedAt = now
      const chars = [...typed]
      const prefix = chars.every(char => char === chars[0]) ? chars[0] : typed
      const current = choices.indexOf(document.activeElement)
      const start = prefix.length === 1 ? current + 1 : Math.max(current, 0)
      for (let i = 0; i < choices.length; i++) {
        const btn = choices[(start + i) % choices.length]
        if (btn.querySelector('.label').textContent.normalize('NFKC').toLocaleLowerCase().startsWith(prefix.normalize('NFKC'))) {
          e.preventDefault()
          focusChoice(btn)
          break
        }
      }
    }
  }
  scrim.addEventListener('pointerdown', e => { e.preventDefault(); close() })
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
  placeOnSide(el)
  if (type === 'error') haptic()
  const t = { dismiss }
  current = t
  requestAnimationFrame(() => requestAnimationFrame(() => {
    el.classList.add('on')
    // A check draws on; anything else bounces to say it needs a look.
    const sym = el.querySelector('.icon')
    if (sym) symbolEffect(sym, sym.dataset.symbol === 'check' ? 'draw-on' : 'bounce')
  }))
  const timer = setTimeout(dismiss, duration)
  async function dismiss() {
    clearTimeout(timer)
    if (current === t) current = null
    if (el.classList.contains('out')) return
    el.classList.remove('on')
    el.classList.add('out')
    await new Promise(resolve => {
      el.addEventListener('animationend', resolve, { once: true })
      setTimeout(resolve, 360)
    })
    el.remove()
  }
  return t
}
