// Backdrops: what someone sees behind their conversations and their calls,
// and the cover at the top of their profile. Each is one of the app's own
// (below, drawn in backdrops.css for light and dark), a photo they chose, or
// '' for none. Which one is kept on the server (src/prefs.js, and the
// profile's cover), so each of their devices shows the same.

export const PRESETS = [
  { id: 'mist', label: '晨雾' },
  { id: 'dawn', label: '朝霞' },
  { id: 'mint', label: '薄荷' },
  { id: 'sand', label: '沙丘' },
  { id: 'ocean', label: '深海' },
  { id: 'dusk', label: '暮色' },
  { id: 'dots', label: '圆点' },
  { id: 'night', label: '星夜' }
]
const PHOTO = /^\/api\/media\/(bg|cover)\/[\w-]+\/[\w-]+$/

/** What a stored value shows: { preset } or { photo }, or null for none. */
export function readBackdrop(value) {
  const v = String(value || '')
  if (v.startsWith('preset:')) {
    const id = v.slice(7)
    return PRESETS.some(p => p.id === id) ? { preset: id } : null
  }
  return PHOTO.test(v) ? { photo: v } : null
}

/** The name of a backdrop, for a setting's value. */
export function backdropLabel(value, none = '默认') {
  const b = readBackdrop(value)
  return b?.preset ? PRESETS.find(p => p.id === b.preset).label : b?.photo ? '照片' : none
}

/**
 * Paint `value` into `el` (a .backdrop). A photo appears once it has
 * loaded, never half-drawn; until then (and if it can't load) whatever was
 * there stays.
 */
export function paintBackdrop(el, value) {
  const b = readBackdrop(value)
  const key = b?.preset || b?.photo || ''
  if (el._backdrop === key) return
  el._backdrop = key
  if (!b?.photo) {
    el.dataset.backdrop = b?.preset || ''
    el.style.removeProperty('--photo')
    return
  }
  const img = new Image()
  img.src = b.photo
  const show = () => {
    if (el._backdrop !== key) return
    el.style.setProperty('--photo', `url("${b.photo}")`)
    el.dataset.backdrop = 'photo'
  }
  img.decode().then(show, () => { if (img.complete && img.naturalWidth) show() })
}

/** A backdrop layer for `value`. */
export function backdropLayer(value, cls = '') {
  const el = document.createElement('div')
  el.className = `backdrop${cls ? ` ${cls}` : ''}`
  el.setAttribute('aria-hidden', 'true')
  paintBackdrop(el, value)
  return el
}
