// Press feedback for every tappable surface, applied on touch-down (not on
// release) like iOS. Rows and list items wait a beat so a scroll doesn't
// flash highlights; buttons respond immediately. Glass controls also get a
// light bloom positioned under the finger (--gx / --gy).

const IMMEDIATE = '.glass-btn, .glass-pill, .solid-press, .composer-action, .composer-tool, .menu-item, .menu-reaction, .m-reactions, .photo-stack-open, .switch, .seg button, .btn, .btn-outline, .auth-tab, .password-toggle, .filter-tab'
const DELAYED = '.row, .pin, .contact-row, button.cell, a.cell, .member'
const SLOP = 10

let active = null

function clearActive() {
  if (!active) return
  clearTimeout(active.timer)
  active.el.classList.remove('is-pressed')
  active = null
}

function onDown(e) {
  if (e.button > 0) return
  const el = e.target.closest(`${IMMEDIATE}, ${DELAYED}`)
  if (!el || el.disabled || el.closest('[data-no-press]')) return
  clearActive()
  const immediate = el.matches(IMMEDIATE)
  active = { el, x: e.clientX, y: e.clientY, id: e.pointerId, timer: 0 }
  if (el.classList.contains('glass')) {
    const r = el.getBoundingClientRect()
    el.style.setProperty('--gx', `${((e.clientX - r.left) / r.width) * 100}%`)
    el.style.setProperty('--gy', `${((e.clientY - r.top) / r.height) * 100}%`)
  }
  if (immediate) el.classList.add('is-pressed')
  else active.timer = setTimeout(() => active?.el.classList.add('is-pressed'), 70)
}

function onMove(e) {
  if (!active || e.pointerId !== active.id) return
  if (Math.hypot(e.clientX - active.x, e.clientY - active.y) > SLOP) clearActive()
  else if (active.el.classList.contains('glass')) {
    const r = active.el.getBoundingClientRect()
    active.el.style.setProperty('--gx', `${((e.clientX - r.left) / r.width) * 100}%`)
    active.el.style.setProperty('--gy', `${((e.clientY - r.top) / r.height) * 100}%`)
  }
}

function onUp(e) {
  if (!active || (e.pointerId !== undefined && e.pointerId !== active.id)) return
  const el = active.el
  clearTimeout(active.timer)
  // A quick tap on a delayed row still deserves a visible flash.
  if (!el.classList.contains('is-pressed') && e.type === 'pointerup') {
    el.classList.add('is-pressed')
    setTimeout(() => el.classList.remove('is-pressed'), 90)
    active = null
    return
  }
  setTimeout(() => el.classList.remove('is-pressed'), e.type === 'pointerup' ? 40 : 0)
  active = null
}

export function initPress() {
  document.addEventListener('pointerdown', onDown, { passive: true })
  document.addEventListener('pointermove', onMove, { passive: true })
  document.addEventListener('pointerup', onUp, { passive: true })
  document.addEventListener('pointercancel', onUp, { passive: true })
  // Scrolling, or the app losing focus mid-press, lets go.
  document.addEventListener('scroll', clearActive, { capture: true, passive: true })
  window.addEventListener('blur', clearActive)
  document.addEventListener('visibilitychange', clearActive)
  // iOS only applies :active styles when a touch listener exists.
  document.addEventListener('touchstart', () => {}, { passive: true })
}

export function cancelPress() {
  clearActive()
}
