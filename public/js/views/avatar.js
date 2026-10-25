import { h } from '../ui/dom.js'
import { initials } from '../ui/format.js'

/** Avatar with a monogram placeholder that cross-fades to the photo once loaded. */
export function avatar(id, name, { room = false, size, inRoom } = {}) {
  const el = h('span', {
    class: ['avatar', room && 'room'],
    style: size ? { '--size': `${size}px` } : undefined,
    'aria-hidden': 'true'
  }, initials(name))
  if (!id) return el
  const img = new Image()
  img.alt = ''
  img.decoding = 'async'
  img.loading = 'lazy'
  img.draggable = false
  img.addEventListener('load', () => img.classList.add('loaded'))
  img.addEventListener('error', () => img.remove())
  img.src = `/api/avatar/${encodeURIComponent(id)}${inRoom ? `?in=${encodeURIComponent(inRoom)}` : ''}`
  el.append(img)
  return el
}
