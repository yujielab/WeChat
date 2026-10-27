import { h } from '../ui/dom.js'
import { initials } from '../ui/format.js'

/**
 * Avatar with a monogram placeholder that cross-fades to the photo once loaded.
 * `src` is an image URL (a user's uploaded avatar) or falsy for the monogram.
 */
export function avatar(src, name, { room = false, size } = {}) {
  const hash = [...String(name || '')].reduce((n, c) => (n * 31 + c.codePointAt(0)) >>> 0, 0)
  const hue = [27, 75, 145, 205, 265][hash % 5]
  const el = h('span', {
    class: ['avatar', room && 'room'],
    style: { '--avatar-hue': String(hue), ...(size ? { '--size': `${size}px` } : {}) },
    'aria-hidden': 'true'
  }, initials(name))
  if (!src) return el
  const img = new Image()
  img.alt = ''
  img.decoding = 'async'
  img.loading = 'lazy'
  img.draggable = false
  img.addEventListener('load', () => img.classList.add('loaded'))
  img.addEventListener('error', () => img.remove())
  img.src = src
  el.append(img)
  return el
}
