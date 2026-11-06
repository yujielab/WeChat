// Skeletons that follow the UI (css/skeleton.css).
//
// A placeholder drawn by hand drifts away from what it stands for as soon as
// the real thing changes. These are made from the real things instead: a view
// builds its rows, messages, cards or cells with its own builders and
// placeholder data, and ghost() turns them into a skeleton — every run of text
// becomes a bar exactly as long as that text (wrapping where it would wrap),
// every picture, avatar, swatch and symbol a block of its own shape, and the
// containers keep their own size, padding, radius and spacing. Change a row's
// layout, a bubble's radius or a card's spacing and its skeleton changes with
// it, with nothing to update here.
//
// The nodes stay out of reach while they stand in: hidden from assistive
// technology, inert, and marked .skeleton so views can find and drop them.

const BLOCKS = 'img, video, canvas, picture, .avatar, .bd-swatch, .toggle, .mem-recap, .mo-media'
const WORDS = [3, 5, 4, 7, 2, 6, 4, 8, 3, 5, 6, 4]

/** Placeholder words, about `count` of them, of varied length (seeded, so a skeleton doesn't flicker). */
export function filler(count = 3, seed = 0) {
  const out = []
  for (let i = 0; i < Math.max(1, count); i++) out.push('n'.repeat(WORDS[(seed + i * 5) % WORDS.length]))
  return out.join(' ')
}

/** Turn nodes built by the app's own builders into a skeleton (in place); returns them. */
export function ghost(...nodes) {
  const list = nodes.flat().filter(Boolean)
  for (const n of list) {
    if (!(n instanceof Element)) continue
    n.classList.add('skeleton')
    n.setAttribute('aria-hidden', 'true')
    n.inert = true
    // Text: each run wrapped, so its bar is as long as the run and wraps with it.
    const walker = document.createTreeWalker(n, NodeFilter.SHOW_TEXT)
    const runs = []
    while (walker.nextNode()) if (walker.currentNode.nodeValue.trim()) runs.push(walker.currentNode)
    for (const t of runs) {
      if (t.parentElement?.closest('.sk-b')) continue
      const bar = document.createElement('span')
      bar.className = 'sk-t'
      t.replaceWith(bar)
      bar.append(t)
    }
    // Pictures, avatars, swatches, switches: blocks in their own shape.
    for (const b of n.querySelectorAll(BLOCKS)) if (!b.parentElement?.closest('.sk-b')) b.classList.add('sk-b')
    for (const v of n.querySelectorAll('img, video')) { v.removeAttribute('src'); v.removeAttribute('srcset') }
  }
  return list
}

/** Drop every skeleton node inside `root` (the real content has arrived). */
export function unghost(root) {
  for (const n of root.querySelectorAll(':scope > .skeleton')) n.remove()
}

/** Whether `root` is showing a skeleton right now. */
export const ghosted = root => Boolean(root.querySelector(':scope > .skeleton'))
