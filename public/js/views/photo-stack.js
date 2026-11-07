// Adjacent, completed photos can share one visual album without changing
// their message identities. The thread decides which messages may group.
import { reveal } from '../ui/reveal.js'
import { h, icon } from '../ui/dom.js'
import { mediaSize } from './bubbles.js'
import { openViewer } from './viewer.js'

export function openPhotoStack({ messages, thumb, findThumb, index = 0 } = {}) {
  const images = (messages || []).filter(m => m.url).map((m, i, list) => ({
    src: m.url, fullSrc: m.url, w: m.w || 0, h: m.h || 0,
    label: `${m.name || 'Photo'}, ${i + 1} of ${list.length}`
  }))
  if (!images.length) return null
  return openViewer({ thumb, findThumb, images, index, label: 'Photos' })
}

/** Room the fanned cards take beside the cover. */
export const STACK_FAN = 30

/** Display size of a stack's cover for the available media width. */
export function stackSize(photo, maxMedia = 240) {
  return mediaSize(photo.w, photo.h, Math.max(100, maxMedia - STACK_FAN), 270)
}

export function renderPhotoStack(messages, ctx = {}, { onExpand, sender } = {}) {
  const photos = messages.filter(m => m.url)
  const first = photos[0]
  if (!first) return h('div', { class: 'bubble text' }, 'Photo unavailable')
  const [width, height] = stackSize(first, ctx.maxMedia)
  const cover = h('img', { src: first.url, alt: first.name || 'Photo album cover', decoding: 'async', draggable: false, width, height })
  const fallback = h('span', { class: 'photo-stack-fallback', hidden: true, 'aria-hidden': 'true' }, icon('photo'))
  cover.addEventListener('error', () => { cover.hidden = true; fallback.hidden = false }, { once: true })
  // Arriving, it opens out of its frame (ui/reveal.js), once the frame is in the page.
  queueMicrotask(() => cover.parentElement && reveal(cover, cover.parentElement))
  const layers = photos.slice(1, 3).reverse().map((photo, i, list) => {
    const depth = list.length - i
    return h('span', { class: 'photo-stack-layer', style: { '--depth': depth }, 'aria-hidden': 'true' },
      h('img', { src: photo.url, alt: '', loading: 'lazy', decoding: 'async', draggable: false }))
  })
  const button = h('button', { class: 'photo-stack-open', type: 'button', 'aria-label': `View ${photos.length} photos` },
    ...layers, h('span', { class: 'photo-stack-cover' }, cover, fallback))
  const caption = h('div', { class: 'photo-stack-caption' },
    h('span', {}, icon('photo'), `${photos.length} photos`))
  if (onExpand) {
    const expand = h('button', { class: 'photo-stack-expand', type: 'button', 'aria-label': `Expand ${photos.length} photos` }, 'Expand')
    expand.addEventListener('click', e => { e.stopPropagation(); onExpand(photos) })
    caption.append(expand)
  }
  // The sender's avatar sits on the cover's top corner with their name above
  // the edge, so the album reads as one thing someone shared (sketch 1).
  const head = sender ? h('div', { class: 'photo-stack-head' },
    h('span', { class: 'photo-stack-avatar', 'aria-hidden': 'true' }, sender.avatar),
    h('span', { class: 'photo-stack-from' }, sender.label)) : null
  const el = h('div', { class: ['bubble media photo-stack', head && 'has-head'], dataset: { kind: 'image-stack', count: photos.length }, style: { '--w': `${width}px`, '--h': `${height}px`, '--photo-ratio': `${width} / ${height}` } }, head, button, caption)
  button.addEventListener('click', e => {
    e.stopPropagation()
    openPhotoStack({ messages: photos, thumb: cover, findThumb: () => el.isConnected ? cover : null })
  })
  return el
}
