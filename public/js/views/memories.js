// Memories: every photo, video and drawing shared in your chats — by you or
// to you — kept here without anyone saving them (src/hub.js: /api/memories),
// after the reference. A heading (a chevron to close it, Memories, "…" for
// the order), a search for a chat or a person, tabs (All, Photos, Videos,
// Drawings), a card for the latest month's recap (its best picture large;
// tap for a slideshow), then each month under its name in a tight grid of
// squares — a video with its length — newest first, more as you scroll.

import { h, icon, reducedMotion } from '../ui/dom.js'
import { ghost, filler } from '../ui/skeleton.js'
import { tip } from '../ui/guides.js'
import { reveal } from '../ui/reveal.js'
import { api } from '../api.js'
import { openSheet, openMenu } from './overlay.js'
import { openViewer } from './viewer.js'

const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']
const TABS = [['all', 'All'], ['photo', 'Photos'], ['video', 'Videos'], ['drawing', 'Drawings']]
const monthKey = ts => { const d = new Date(ts); return `${d.getFullYear()}-${d.getMonth()}` }
const monthName = (ts, now = new Date()) => {
  const d = new Date(ts)
  return d.getFullYear() === now.getFullYear() ? MONTHS[d.getMonth()] : `${MONTHS[d.getMonth()]} ${d.getFullYear()}`
}
const duration = s => `${Math.floor(s / 60)}:${String(Math.round(s % 60)).padStart(2, '0')}`

/** page, swap: shown as one of the app's pages from the rail (ui/pages.js). */
export function openMemories({ origin, page = false, swap = false } = {}) {
  let tab = 'all'
  let order = 'newest'
  let items = []
  let loading = false
  let done = false
  let query = ''

  const close = h('button', { class: 'glass glass-btn mem-close', type: 'button', 'aria-label': 'Close' }, icon('chevron-down'))
  const more = h('button', { class: 'glass glass-btn mem-more', type: 'button', 'aria-label': 'More', 'aria-haspopup': 'menu' }, icon('ellipsis'))
  const head = h('header', { class: 'mem-head' }, close, h('h1', { class: 'mem-title' }, 'Memories'), more)
  const search = h('input', { class: 'mem-search-input', type: 'search', placeholder: 'Search', enterkeyhint: 'search', autocomplete: 'off', 'aria-label': 'Search memories by chat or person' })
  const searchPill = h('label', { class: 'mem-search' }, icon('search'), search)
  const tabBar = h('div', { class: 'mem-tabs', role: 'tablist', 'aria-label': 'Memories' },
    h('span', { class: 'mem-tab-line', 'aria-hidden': 'true' }),
    TABS.map(([id, label]) => h('button', { class: 'mem-tab', type: 'button', role: 'tab', dataset: { tab: id }, 'aria-selected': String(id === tab) }, label)))
  const recap = h('div', { class: 'mem-recap-slot' })
  const months = h('div', { class: 'mem-months' })
  const foot = h('div', { class: 'mem-foot', 'aria-hidden': 'true' })
  const content = h('div', { class: 'mem-page' }, head, searchPill, tabBar, recap, months, foot)

  const sheet = openSheet({ label: 'Memories', content, tall: true, origin, page, swap })
  sheet.el.classList.add('memories-page')
  close.addEventListener('click', () => sheet.close())
  more.addEventListener('click', () => openMenu(more, [[
    { label: 'Newest first', checked: order === 'newest', onSelect: () => { order = 'newest'; paint() } },
    { label: 'Oldest first', checked: order === 'oldest', onSelect: () => { order = 'oldest'; paint() } }
  ]], { title: 'Order' }))
  search.addEventListener('input', () => { query = search.value.trim().toLowerCase(); paint() })
  tabBar.addEventListener('click', e => {
    const b = e.target.closest('.mem-tab')
    if (!b || b.dataset.tab === tab) return
    tab = b.dataset.tab
    for (const x of tabBar.querySelectorAll('.mem-tab')) x.setAttribute('aria-selected', String(x === b))
    placeLine()
    reload()
  })
  function placeLine() {
    const b = tabBar.querySelector(`[data-tab="${tab}"]`)
    const line = tabBar.querySelector('.mem-tab-line')
    requestAnimationFrame(() => {
      line.style.width = `${b.offsetWidth}px`
      line.style.transform = `translateX(${b.offsetLeft}px)`
    })
  }
  sheet.body.addEventListener('scroll', () => {
    sheet.el.classList.toggle('mem-scrolled', sheet.body.scrollTop > 4)
    if (!loading && !done && sheet.body.scrollTop + sheet.body.clientHeight > sheet.body.scrollHeight - 700) load()
  }, { passive: true })

  async function load(first = false) {
    if (loading || (done && !first)) return
    loading = true
    const before = !first && items.length ? `&before=${items[items.length - 1].ts}` : ''
    const asked = tab
    try {
      const r = await api.get(`/api/memories?limit=90${tab === 'all' ? '' : `&type=${tab}`}${before}`)
      if (asked !== tab) return
      if (first) items = []
      items.push(...r.memories)
      done = !r.more
      paint()
      // A short first page with more to come: fill the screen.
      if (!done && sheet.body.scrollHeight <= sheet.body.clientHeight + 200) setTimeout(() => load(), 0)
    } catch (err) {
      if (first) months.replaceChildren(h('p', { class: 'mem-empty' }, err.message || "Can't load memories"))
    } finally {
      loading = false
    }
  }
  function reload() {
    items = []
    done = false
    months.replaceChildren(skeleton())
    recap.replaceChildren()
    load(true)
  }

  // ------------------------------------------------------------ painting
  function shown() {
    let list = items
    if (query) list = list.filter(m => (m.chat.name || '').toLowerCase().includes(query) || (m.from.display || '').toLowerCase().includes(query) || (m.from.username || '').toLowerCase().includes(query) || monthName(m.ts).toLowerCase().includes(query))
    return order === 'oldest' ? [...list].reverse() : list
  }
  function paint() {
    const list = shown()
    // The recap: the newest month's, its best picture large.
    const latest = items.filter(m => m.type !== 'video')
    if (!query && latest.length && order === 'newest') {
      const key = monthKey(latest[0].ts)
      const inMonth = items.filter(m => monthKey(m.ts) === key)
      const hero = inMonth.find(m => m.type === 'photo' && m.w >= m.h) || inMonth.find(m => m.type !== 'video') || inMonth[0]
      recap.replaceChildren(recapCard(hero, inMonth))
    } else recap.replaceChildren()
    if (!list.length) {
      months.replaceChildren(h('div', { class: 'mem-empty' }, icon('photo'), h('b', {}, query ? 'Nothing found' : 'No memories yet'),
        h('span', {}, query ? `Nothing from a chat or person called “${search.value.trim()}”.` : 'Photos, videos and drawings you and your friends share in chats are kept here.')))
      return
    }
    // Months, in order, each with its grid.
    const groups = []
    for (const m of list) {
      const key = monthKey(m.ts)
      if (groups.at(-1)?.key !== key) groups.push({ key, ts: m.ts, list: [] })
      groups.at(-1).list.push(m)
    }
    months.replaceChildren(...groups.map(g => h('section', { class: 'mem-month', 'aria-label': monthName(g.ts) },
      h('h2', { class: 'mem-month-name' }, monthName(g.ts), h('span', { class: 'mem-month-count tabular' }, String(g.list.length))),
      h('div', { class: 'mem-grid' }, g.list.map((m, i) => tile(m, g.list, i))))))
  }
  function recapCard(hero, inMonth) {
    const pics = inMonth.filter(m => m.type !== 'video')
    const n = inMonth.length
    const card = h('button', { class: 'mem-recap', type: 'button', 'aria-label': `My ${MONTHS[new Date(hero.ts).getMonth()]} recap, ${n} ${n === 1 ? 'memory' : 'memories'}. Play` },
      hero.type === 'video' ? h('video', { src: hero.url + '#t=0.1', muted: true, playsInline: true, preload: 'metadata' }) : h('img', { src: hero.url, alt: '', decoding: 'async', draggable: false }),
      h('span', { class: 'mem-recap-text' },
        h('b', {}, `My ${MONTHS[new Date(hero.ts).getMonth()]} recap`),
        h('span', {}, `${n} ${n === 1 ? 'photo or video' : 'photos and videos'} from your chats`)),
      h('span', { class: 'mem-recap-play', 'aria-hidden': 'true' }, icon('play')))
    card.addEventListener('click', () => {
      if (!pics.length) return
      openViewer({ thumb: card.querySelector('img'), images: pics.map((m, k) => ({ src: m.url, fullSrc: m.url, w: m.w, h: m.h, label: `${label(m)} · ${k + 1} of ${pics.length}` })), index: 0 })
    })
    return card
  }
  const label = m => `${m.mine ? 'You' : m.from.display || m.from.username}${m.chat.name ? ` in ${m.chat.name}` : ''}, ${new Date(m.ts).toLocaleDateString()}`
  function tile(m, group, i) {
    const b = h('button', { class: ['mem-tile', `is-${m.type}`], type: 'button', 'aria-label': `${m.type === 'video' ? 'Video' : m.type === 'drawing' ? 'Drawing' : 'Photo'} from ${label(m)}` },
      m.type === 'video' ? h('video', { src: m.url + '#t=0.1', muted: true, playsInline: true, preload: 'metadata' }) : h('img', { src: m.url, alt: '', loading: 'lazy', decoding: 'async', draggable: false }),
      m.type === 'video' ? h('span', { class: 'mem-dur tabular' }, m.dur ? duration(m.dur) : icon('play')) : null,
      m.type === 'drawing' ? h('span', { class: 'mem-badge' }, icon('brush')) : null)
    const pic = b.querySelector('img')
    if (pic) reveal(pic, b)
    // In the viewer: back to the chat it was shared in.
    const toChat = { actions: [{ id: 'chat', icon: 'bubble', label: 'Open chat', onSelect: v => { v.close(); sheet.close(); window.dispatchEvent(new CustomEvent('open-chat', { detail: m.room })) } }] }
    b.addEventListener('click', () => {
      if (m.type === 'video') return openViewer({ kind: 'video', fullSrc: m.url, src: m.url, w: m.w, h: m.h, label: label(m), ...toChat })
      const pics = group.filter(x => x.type !== 'video')
      openViewer({ thumb: b.querySelector('img'), images: pics.map(x => ({ src: x.url, fullSrc: x.url, w: x.w, h: x.h, label: label(x) })), index: pics.indexOf(m), ...toChat })
    })
    if (!reducedMotion()) b.style.setProperty('--d', `${Math.min(i, 16) * 18}ms`)
    return b
  }
  // The page's skeleton from its own parts (ui/skeleton.js): a recap card, a
  // month's name and count, a grid of tiles — whatever their CSS makes them.
  function skeleton() {
    return h('div', { class: 'mem-ghost' }, ...ghost(
      h('div', { class: 'mem-recap' }, h('span', { class: 'mem-recap-text' }, h('b', {}, filler(3, 2)), h('span', {}, filler(5, 4)))),
      h('section', { class: 'mem-month' }, h('h2', { class: 'mem-month-name' }, filler(1, 3), h('span', { class: 'mem-month-count' }, '00')),
        h('div', { class: 'mem-grid' }, Array.from({ length: 12 }, () => h('div', { class: 'mem-tile sk-b' }))))))
  }

  placeLine()
  reload()
  setTimeout(() => tip('memories', tabBar, { title: 'Kept for you', text: 'Photos, videos and drawings from your chats gather here by month, without saving anything.', side: 'below' }), 900)
  return sheet
}
