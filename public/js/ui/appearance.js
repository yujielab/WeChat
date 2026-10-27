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
  for (const m of document.querySelectorAll('meta[name="theme-color"]')) m.setAttribute('content', dark ? '#101012' : '#ffffff')
}

/**
 * Watches real frame times while the user scrolls. If blurred layers make
 * scrolling drop frames repeatedly, switch to the solid interface and
 * remember it (Settings can turn glass back on).
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
      markSlow('frames')
      document.removeEventListener('scroll', onScroll, true)
    } else if (windows >= 8) {
      document.removeEventListener('scroll', onScroll, true)
    }
  }
  document.addEventListener('scroll', onScroll, { capture: true, passive: true })
}

function markSlow(reason) {
  storage('ui:glass-auto', 'solid')
  storage('ui:glass-auto-reason', reason)
  root.setAttribute('data-glass', 'solid')
}
