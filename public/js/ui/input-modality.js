// Marks the root with data-input="keyboard" while the user is driving the app
// from a keyboard, so the strong focus ring also shows where the pointer is
// coarse (an iPad with a hardware keyboard but no trackpad). Any pointer or
// touch press clears it again. Typing text does not count: only navigation keys.
const NAV_KEYS = new Set(['Tab', 'ArrowUp', 'ArrowDown', 'ArrowLeft', 'ArrowRight', 'Home', 'End', 'PageUp', 'PageDown'])

export function initInputModality(root = document.documentElement) {
  const set = on => {
    if (on) root.dataset.input = 'keyboard'
    else if (root.dataset.input) delete root.dataset.input
  }
  addEventListener('keydown', e => {
    if (e.metaKey || e.ctrlKey || e.altKey) return
    if (NAV_KEYS.has(e.key)) set(true)
  }, true)
  addEventListener('pointerdown', () => set(false), true)
}
