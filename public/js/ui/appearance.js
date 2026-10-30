// Appearance preferences (theme, transparency, motion, haptics) and the
// automatic fallback to a solid interface when the device can't keep up.

import { storage } from './dom.js'

const root = document.documentElement

export function getPrefs() {
  return {
    // White is the default look; 跟随系统 and 深色 remain a choice in Settings.
    theme: storage('ui:theme') || 'light', // light | system | dark
    glass: storage('ui:glass') || 'auto', // auto | solid
    glassAuto: storage('ui:glass-auto') === 'solid',
    motion: storage('ui:motion') || 'system', // system | reduce
    haptics: storage('ui:haptics') !== 'off'
  }
}

function applyAttr(name, value) {
  if (value) root.setAttribute(name, value)
  else root.removeAttribute(name)
}

export function setTheme(theme) {
  storage('ui:theme', theme === 'light' ? null : theme)
  // Don't let every color transition fire during the swap.
  root.classList.add('no-anim')
  applyAttr('data-theme', theme === 'system' ? null : theme)
  syncThemeColor()
  requestAnimationFrame(() => requestAnimationFrame(() => root.classList.remove('no-anim')))
}

export function setGlass(mode) {
  storage('ui:glass', mode === 'auto' ? null : mode)
  if (mode === 'auto') storage('ui:glass-auto', null)
  applyAttr('data-glass', mode === 'solid' ? 'solid' : null)
}

export function setMotion(mode) {
  storage('ui:motion', mode === 'system' ? null : mode)
  applyAttr('data-motion', mode === 'system' ? null : mode)
}

export function setHaptics(on) {
  storage('ui:haptics', on ? null : 'off')
}

/** Status bar / browser chrome color follows the effective theme. */
export function syncThemeColor() {
  const dark = root.dataset.theme === 'dark' || (!root.dataset.theme && matchMedia('(prefers-color-scheme: dark)').matches)
  const color = dim ? dimmed(dim) : dark ? '#000000' : '#ffffff'
  for (const m of document.querySelectorAll('meta[name="theme-color"]')) m.setAttribute('content', color)
}

// While a sheet's scrim dims the app, the status area the system keeps
// beside the page takes the colour at the app's edge under that scrim, so
// the screen still reads as one surface.
let dim = null
export function dimThemeColor(scrim) {
  dim = scrim
  syncThemeColor()
}
const rgba = value => (value.match(/[\d.]+/g) || []).map(Number)
function dimmed(scrim) {
  const [r, g, b, a = 1] = rgba(getComputedStyle(scrim).backgroundColor)
  const base = rgba(getComputedStyle(document.getElementById('app')).backgroundColor)
  const mix = (over, under) => Math.round(over * a + under * (1 - a))
  return '#' + [mix(r, base[0]), mix(g, base[1]), mix(b, base[2])].map(v => v.toString(16).padStart(2, '0')).join('')
}

/**
 * Watches real frame times while the user scrolls. If blurred layers make
 * scrolling drop frames repeatedly, switch to the solid interface and
 * remember it (Settings can turn glass back on). The switch waits until the
 * app is out of sight: every material on screen changing at once mid-scroll
 * would read as a flash.
 */
export function startPerfProbe() {
  if (getPrefs().glass === 'solid' || storage('ui:glass-auto')) return
  if (navigator.connection?.saveData) return markSlow('save-data')
  if ((navigator.deviceMemory && navigator.deviceMemory <= 2) || (navigator.hardwareConcurrency && navigator.hardwareConcurrency <= 2)) {
    return markSlow('low-end')
  }
  let sampling = false
  let frames = []
  let last = 0
  let windows = 0
  let slowWindows = 0
  const tick = now => {
    if (last) frames.push(now - last)
    last = now
    if (sampling) requestAnimationFrame(tick)
  }
  let stopTimer = 0
  const onScroll = () => {
    if (!sampling) {
      sampling = true
      frames = []
      last = 0
      requestAnimationFrame(tick)
    }
    clearTimeout(stopTimer)
    stopTimer = setTimeout(evaluate, 220)
  }
  const evaluate = () => {
    sampling = false
    if (frames.length < 20) return
    const sorted = [...frames].sort((a, b) => a - b)
    const median = sorted[Math.floor(sorted.length / 2)]
    const long = frames.filter(f => f > 34).length / frames.length
    windows++
    if (median > 22 || long > 0.2) slowWindows++
    if (windows >= 3 && slowWindows >= 2) {
      markSlow('frames', { later: true })
      document.removeEventListener('scroll', onScroll, true)
    } else if (windows >= 8) {
      document.removeEventListener('scroll', onScroll, true)
    }
  }
  document.addEventListener('scroll', onScroll, { capture: true, passive: true })
}

function markSlow(reason, { later = false } = {}) {
  storage('ui:glass-auto', 'solid')
  storage('ui:glass-auto-reason', reason)
  if (!later) return root.setAttribute('data-glass', 'solid')
  const swap = () => {
    if (document.visibilityState !== 'hidden') return
    document.removeEventListener('visibilitychange', swap)
    // Settings may have turned glass back on in the meantime.
    if (storage('ui:glass-auto') === 'solid') root.setAttribute('data-glass', 'solid')
  }
  document.addEventListener('visibilitychange', swap)
}
