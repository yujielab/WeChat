// Moments: what someone shares — up to nine photos, or one video, and a few
// words — for everyone or only for their friends, and the likes and comments
// it gathers (src/hub.js keeps them; friends are your contacts and the people
// you've talked with one to one).
//
// The home is a feed. Its name in large type across the top, with buttons to
// share, to your own page and to close; a row of the people in it (you first,
// to share; a ring round whoever has shared since you last looked; a badge on
// anyone you've yet to talk to); then each moment as a card: who, with a
// Message pill for someone you've not talked to; the pictures edge to edge
// (several swipe one at a time, a video plays without sound while it's in
// view, a double tap likes it); a heart, a bubble and a paper plane with
// their counts; the words; the comments; how long ago.
//
// Someone's page is a profile: the cover across the top with a round glass
// button over it, the photo overlapping its edge, the name, the handle, when
// they joined, how much they've shared, two pills (Share profile, and Edit
// profile or Message), then tabs: their moments as cards, or their pictures
// as a wall. From someone you've not talked to, only what they shared for
// everyone. On your own, a round button at the foot shares a new one.

import { ghost, filler } from '../ui/skeleton.js'
import { reveal } from '../ui/reveal.js'
import { h, icon, reducedMotion } from '../ui/dom.js'
import { api } from '../api.js'
import { state, upsertRoom } from '../store.js'
import { avatar } from './avatar.js'
import { openSheet, openMenu, confirmAction, toast } from './overlay.js'
import { backdropLayer, readBackdrop } from '../ui/backdrops.js'
import { openViewer } from './viewer.js'
import { openMomentEditor, whenText, PHOTOS_MAX } from './moments-editor.js'

export { PHOTOS_MAX }
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']
const nameOf = u => u?.display || u?.username || ''

// ---------------------------------------------------------------- new from friends
// A dot on the way in (the list's heading, the sidebar) while friends have
// shared something since you last looked.
const SEEN_KEY = 'moments:seen'
const seen = () => { try { return Number(localStorage.getItem(SEEN_KEY)) || 0 } catch { return 0 } }
let fresh = false
export const hasNewMoments = () => fresh
function setFresh(on) {
  if (fresh === on) return
  fresh = on
  window.dispatchEvent(new CustomEvent('moments-new', { detail: on }))
}
function markSeen() {
  try { localStorage.setItem(SEEN_KEY, String(Date.now())) } catch {}
  setFresh(false)
}
/** After launch: has a friend shared anything since the last look? */
export async function checkNewMoments() {
  try {
    const { moments } = await api.get('/api/moments')
    const newest = moments.find(m => !m.mine && m.user.friend)
    setFresh(Boolean(newest && newest.created > seen()))
  } catch {}
}

// ---------------------------------------------------------------- the open pages
// Every page open now (the home, and profiles over it). What happens on one —
// a like, a comment, a delete, a new moment — shows on the others at once, and
// what the socket says (main.js passes it on) reaches them all.
const pages = new Set()
const everywhere = (fn, ...args) => { for (const p of [...pages]) p[fn]?.(...args) }

export async function onMomentEvent(msg) {
  if (msg.t === 'moment' && msg.user !== state.me?.id) setFresh(true)
  if (msg.t === 'moment-deleted') return everywhere('drop', msg.id)
  if (msg.t === 'moment-changed') {
    if (![...pages].some(p => p.has(msg.id))) return
    try { everywhere('apply', (await api.get(`/api/moments/${msg.id}`)).moment) } catch {}
    return
  }
  if (msg.t === 'moment' && msg.user !== state.me?.id) everywhere('arrived', msg)
}

/** A chat with them, opened over everything: the Moments pages make way. */
async function startChat(user) {
  try {
    const r = await api.post('/api/dm', { user: user.id })
    upsertRoom(r.room)
    everywhere('close')
    window.dispatchEvent(new CustomEvent('open-chat', { detail: r.room.id }))
  } catch (err) { toast(err.message, { type: 'error' }) }
}

/**
 * userId: whose page (none: the home feed). tab: 'posts' | 'media'. back: opened from another page.
 * page, swap: shown as one of the app's pages from the rail (ui/pages.js), in place of another.
 */
export function openMoments({ userId, tab, origin, back = false, page = false, swap = false } = {}) {
  return userId ? openProfile({ userId, tab, origin, back, page, swap }) : openHome({ origin, page, swap })
}

// ---------------------------------------------------------------- the home
function openHome({ origin, page: asPage = false, swap = false } = {}) {
  const lastLook = seen()
  const looked = new Set() // people whose page you've opened since
  let items = []
  let loading = false
  let done = false

  const add = h('button', { class: 'glass glass-btn mo-head-btn', type: 'button', 'aria-label': 'New moment' }, icon('plus'))
  const mine = h('button', { class: 'mo-me', type: 'button', 'aria-label': 'Your moments' }, avatar(state.me?.avatar, nameOf(state.me), { size: 32 }))
  const close = h('button', { class: 'glass glass-btn mo-head-btn', type: 'button', 'aria-label': 'Close' }, icon('xmark'))
  const head = h('header', { class: 'mo-home-head' },
    h('h1', { class: 'mo-wordmark' }, 'Moments'),
    h('div', { class: 'mo-head-actions' }, add, mine, close))
  const people = h('ul', { class: 'mo-people', 'aria-label': 'People' })
  const fresher = h('button', { class: 'mo-fresh', type: 'button', hidden: true }, icon('arrow-up'), 'New moments')
  const panel = h('div', { class: 'mo-feed' })
  const more = h('div', { class: 'mo-more', 'aria-hidden': 'true' })
  const content = h('div', { class: 'mo-home' }, head, people, fresher, panel, more)

  const sheet = openSheet({ label: 'Moments', content, tall: true, origin, page: asPage, swap, onClose: () => { pages.delete(page); quiet(sheet.el) } })
  sheet.el.classList.add('moments-page', 'moments-home')
  const list = cards(panel, { owner: null, empty: emptyEl })
  close.addEventListener('click', () => sheet.close())
  add.addEventListener('click', () => openMomentComposer({ origin: add }))
  mine.addEventListener('click', () => openMoments({ userId: state.me?.id, back: true, origin: mine }))
  sheet.body.addEventListener('scroll', () => {
    sheet.el.classList.toggle('mo-scrolled', sheet.body.scrollTop > 4)
    if (!loading && !done && sheet.body.scrollTop + sheet.body.clientHeight > sheet.body.scrollHeight - 600) load()
  }, { passive: true })
  markSeen()

  // ------------------------------------------------------------ the people in it
  function paintPeople() {
    const you = h('li', {}, personEl({
      user: state.me, label: 'Your moment', badge: 'plus', ring: false,
      aria: 'Share a moment', onClick: b => openMomentComposer({ origin: b })
    }))
    const by = new Map()
    for (const m of items) if (!m.mine && !by.has(m.user.id)) by.set(m.user.id, { user: m.user, latest: m.created })
    const isNew = p => p.latest > lastLook && !looked.has(p.user.id)
    const others = [...by.values()].sort((a, b) => (isNew(b) - isNew(a)) || b.latest - a.latest).slice(0, 24)
    people.replaceChildren(you, ...others.map(p => h('li', {}, personEl({
      user: p.user, label: nameOf(p.user), ring: isNew(p), badge: p.user.friend ? null : 'person-plus',
      aria: `${nameOf(p.user)}${isNew(p) ? ', new moments' : ''}${p.user.friend ? '' : ", you've not talked yet"}`,
      onClick: b => { looked.add(p.user.id); b.querySelector('.mo-ring')?.classList.remove('fresh'); openMoments({ userId: p.user.id, back: true, origin: b }) }
    }))))
  }

  async function load(first = false) {
    if (loading || (done && !first)) return
    loading = true
    const before = !first && items.length ? `?before=${items[items.length - 1].created}` : ''
    try {
      const r = await api.get(`/api/moments${before}`)
      const got = r.moments || []
      done = got.length < 20
      if (first) { items = []; list.clear(); panel.replaceChildren() }
      items.push(...got.filter(m => !list.has(m.id)))
      list.add(got)
      if (first && !got.length) panel.replaceChildren(emptyEl())
      paintPeople()
    } catch (err) {
      if (first) panel.replaceChildren(h('p', { class: 'mo-empty' }, err.message || "Can't load moments"))
    } finally {
      loading = false
      more.hidden = done
    }
  }
  function emptyEl() {
    const go = h('button', { class: 'mo-pill solid', type: 'button' }, 'Share a moment')
    go.addEventListener('click', () => openMomentComposer({ origin: go }))
    return h('div', { class: 'mo-empty' }, h('b', {}, 'Nothing here yet'), h('span', {}, 'What you, your friends and everyone else share shows up here.'), go)
  }

  const page = {
    has: id => list.has(id),
    apply: m => list.apply(m),
    drop: id => { list.drop(id); items = items.filter(x => x.id !== id); paintPeople() },
    posted: m => { items.unshift(m); list.prepend(m); sheet.body.scrollTo({ top: 0, behavior: reducedMotion() ? 'auto' : 'smooth' }) },
    arrived: () => { fresher.hidden = false },
    close: () => sheet.close()
  }
  pages.add(page)
  fresher.addEventListener('click', () => {
    fresher.hidden = true
    sheet.body.scrollTo({ top: 0, behavior: reducedMotion() ? 'auto' : 'smooth' })
    markSeen()
    load(true)
  })

  paintPeople()
  panel.replaceChildren(skeleton())
  load(true)
  return sheet
}

function personEl({ user, label, badge, ring, aria, onClick }) {
  const b = h('button', { class: 'mo-person', type: 'button', dataset: { user: user?.id || '' }, 'aria-label': aria },
    h('span', { class: ['mo-ring', ring && 'fresh'] }, avatar(user?.avatar, nameOf(user), { size: 64 })),
    badge ? h('span', { class: ['mo-badge', `mo-badge-${badge}`], 'aria-hidden': 'true' }, icon(badge)) : null,
    h('span', { class: 'mo-person-name', 'aria-hidden': 'true' }, label))
  b.addEventListener('click', () => onClick(b))
  return b
}

// ---------------------------------------------------------------- someone's page
function openProfile({ userId, tab, origin, back, page: asPage = false, swap = false }) {
  const self = userId === state.me?.id
  let current = tab === 'media' ? 'media' : 'posts'
  let profile = null
  let items = []
  let loading = false
  let done = false

  const cover = h('div', { class: 'mo-cover' }, backdropLayer(''))
  const face = h('div', { class: 'mo-face' })
  const name = h('h2', { class: 'mo-name' })
  const handle = h('p', { class: 'mo-handle' })
  const bio = h('p', { class: 'mo-bio', hidden: true })
  const joined = h('p', { class: 'mo-joined' })
  const counts = h('p', { class: 'mo-counts' })
  const share = h('button', { class: 'mo-pill', type: 'button' }, 'Share profile')
  const second = h('button', { class: ['mo-pill', !self && 'solid'], type: 'button' }, self ? 'Edit profile' : 'Message')
  const tabs = [['posts', 'doc', 'Posts'], ['media', 'photo', 'Media']]
  const tabBar = h('div', { class: 'mo-tabs', role: 'tablist', 'aria-label': 'Moments' },
    h('span', { class: 'mo-tab-line', 'aria-hidden': 'true' }),
    tabs.map(([id, ic, label]) => h('button', { class: 'mo-tab', type: 'button', role: 'tab', dataset: { tab: id }, 'aria-label': label }, icon(ic), h('span', { class: 'mo-tab-label' }, label))))
  const fresher = h('button', { class: 'mo-fresh', type: 'button', hidden: true }, icon('arrow-up'), 'New moments')
  const panel = h('div', { class: 'mo-panel', role: 'tabpanel' })
  const more = h('div', { class: 'mo-more', 'aria-hidden': 'true' })
  const content = h('div', { class: 'mo-page' },
    cover,
    h('div', { class: 'mo-id' }, face, name, handle, bio, joined, counts, h('div', { class: 'mo-actions' }, share, second)),
    tabBar, fresher, panel, more)

  const sheet = openSheet({ label: self ? 'Your moments' : 'Profile', content, tall: true, origin, page: asPage, swap, onClose: () => { pages.delete(page); quiet(sheet.el) } })
  sheet.el.classList.add('moments-page', 'moments-profile')
  const list = cards(panel, { owner: userId, empty: () => emptyEl(profile) })
  // A round glass button over the cover, staying put as the page scrolls.
  const close = h('button', { class: 'glass glass-btn mo-close', type: 'button', 'aria-label': back ? 'Back' : 'Close' }, icon(back ? 'chevron-left' : 'xmark'))
  close.addEventListener('click', () => sheet.close())
  const compose = h('button', { class: 'mo-compose', type: 'button', 'aria-label': 'New moment', hidden: !self }, icon('plus'))
  compose.addEventListener('click', () => openMomentComposer({ origin: compose }))
  // Once the cover has scrolled away, a bar fills in behind the button with
  // the name in it, and the tabs keep to its foot.
  const barName = h('span', { class: 'mo-topbar-name', 'aria-hidden': 'true' })
  sheet.el.append(h('div', { class: 'mo-topbar' }, close, barName), compose)
  sheet.body.addEventListener('scroll', () => {
    sheet.el.classList.toggle('mo-scrolled', sheet.body.scrollTop > cover.offsetHeight - 68)
    if (!loading && !done && sheet.body.scrollTop + sheet.body.clientHeight > sheet.body.scrollHeight - 500) load()
  }, { passive: true })

  // ------------------------------------------------------------ header
  function paintHeader(u) {
    const look = readBackdrop(u.cover)
    cover.replaceChildren(backdropLayer(look ? u.cover : ''))
    cover.classList.toggle('plain', !look)
    face.replaceChildren(avatar(u.avatar, u.display, { size: 96 }))
    name.textContent = nameOf(u)
    barName.textContent = name.textContent
    handle.textContent = '@' + u.username
    bio.textContent = u.bio || ''
    bio.hidden = !u.bio
    const d = u.joined ? new Date(u.joined) : null
    joined.replaceChildren(icon('calendar'), d ? `Joined ${MONTHS[d.getMonth()]} ${d.getFullYear()}` : '')
    joined.hidden = !d
  }
  function paintCounts(add = 0) {
    if (!profile) return
    profile.count = Math.max(0, (profile.count || 0) + add)
    const parts = [h('span', {}, h('b', {}, String(profile.count)), profile.count === 1 ? ' Post' : ' Posts')]
    if (profile.friends !== undefined) parts.push(h('span', {}, h('b', {}, String(profile.friends)), profile.friends === 1 ? ' Friend' : ' Friends'))
    else if (!self) parts.push(h('span', { class: 'mo-rel' }, profile.friend ? 'Friends' : "You've not talked yet"))
    counts.replaceChildren(...parts)
  }
  share.addEventListener('click', async () => {
    const u = profile?.user || state.me
    const text = `Find ${nameOf(u)} on Cuven: @${u.username}`
    try {
      if (navigator.share) await navigator.share({ title: nameOf(u), text })
      else { await navigator.clipboard.writeText(text); toast('Copied', { type: 'ok' }) }
    } catch {}
  })
  second.addEventListener('click', async () => {
    if (!self) return startChat({ id: userId })
    const { openEditProfile } = await import('./sheets.js')
    openEditProfile(next => { paintHeader({ ...profile?.user, ...next }) })
  })

  // ------------------------------------------------------------ tabs and loading
  function select(id) {
    current = id
    const i = tabs.findIndex(t => t[0] === id)
    tabBar.style.setProperty('--i', String(i))
    tabBar.style.setProperty('--n', String(tabs.length))
    for (const b of tabBar.querySelectorAll('.mo-tab')) b.setAttribute('aria-selected', String(b.dataset.tab === id))
    fresher.hidden = true
    items = []
    done = false
    wall = null
    list.clear()
    quiet(panel)
    panel.className = `mo-panel mo-panel-${id}`
    panel.replaceChildren(skeleton())
    load(true)
  }
  tabBar.addEventListener('click', e => { const b = e.target.closest('.mo-tab'); if (b && b.dataset.tab !== current) select(b.dataset.tab) })

  async function load(first = false) {
    if (loading || (done && !first)) return
    loading = true
    const before = !first && items.length ? `?before=${items[items.length - 1].created}` : ''
    const tabNow = current
    try {
      const r = await api.get(`/api/moments/user/${userId}${before}`)
      if (tabNow !== current) return
      if (first) {
        profile = { user: r.user, count: r.count, friends: r.friends, friend: r.friend, visible: r.visible }
        paintHeader(r.user)
        paintCounts()
      }
      const got = r.moments || []
      done = got.length < 20
      if (first) panel.replaceChildren()
      items.push(...got)
      if (current === 'media') paintWall(got, first)
      else list.add(got)
      if (first && !items.length) panel.replaceChildren(emptyEl(r))
    } catch (err) {
      if (first) panel.replaceChildren(h('p', { class: 'mo-empty' }, err.message || "Can't load moments"))
    } finally {
      loading = false
      more.hidden = done
    }
  }

  function emptyEl(r) {
    if (self) {
      const go = h('button', { class: 'mo-pill solid', type: 'button' }, 'Share a moment')
      go.addEventListener('click', () => compose.click())
      return h('div', { class: 'mo-empty' }, h('b', {}, 'Share your first moment'), h('span', {}, 'Photos or a video, and a few words.'), go)
    }
    if (r && r.visible === false) return h('div', { class: 'mo-empty' }, h('b', {}, 'Nothing for everyone yet'), h('span', {}, `What ${nameOf(r.user) || 'they'} shares for everyone shows up here.`))
    return h('div', { class: 'mo-empty' }, h('b', {}, 'Nothing shared yet'))
  }

  // The pictures as a wall: two columns of cards of their own heights, each a
  // moment's first picture with its words under it.
  let wall = null
  function paintWall(got, first) {
    if (first || !wall) {
      wall = [h('div', { class: 'mo-col' }), h('div', { class: 'mo-col' })]
      panel.replaceChildren(h('div', { class: 'mo-wall' }, ...wall))
    }
    for (const m of got) {
      if (!m.media.length) continue
      const x = m.media[0]
      const ratio = x.w && x.h ? Math.min(1.5, Math.max(0.66, x.w / x.h)) : 1
      const card = h('button', { class: 'mo-card', type: 'button', dataset: { id: m.id }, 'aria-label': m.text || 'Moment' },
        h('span', { class: ['mo-card-pic', x.type === 'video' && 'video'], style: { aspectRatio: String(ratio) } },
          x.type === 'video' ? h('video', { src: x.url + '#t=0.1', muted: true, playsInline: true, preload: 'metadata' }) : revealed(h('img', { src: x.url, alt: '', loading: 'lazy', decoding: 'async', draggable: false })),
          x.type === 'video' ? h('span', { class: 'mo-play' }, icon('play')) : m.media.length > 1 ? h('span', { class: 'mo-count' }, `${m.media.length}`) : null),
        m.text ? h('span', { class: 'mo-card-text' }, m.text) : null,
        h('span', { class: 'mo-card-foot' }, avatar(m.user.avatar, m.user.display, { size: 20 }), h('span', { class: 'mo-card-name' }, nameOf(m.user)), h('span', { class: 'mo-card-likes' }, icon('heart'), m.likes.length ? String(m.likes.length) : '')))
      card.addEventListener('click', () => show(m, 0, card))
      // The shorter column takes the next card.
      const [a, b] = wall
      ;(a.offsetHeight <= b.offsetHeight ? a : b).append(card)
    }
    if (first && !panel.querySelector('.mo-card')) panel.replaceChildren(emptyEl(profile))
  }

  const page = {
    has: id => list.has(id),
    apply: m => list.apply(m),
    drop: id => {
      const had = list.has(id) || items.some(x => x.id === id)
      list.drop(id)
      panel.querySelector(`.mo-card[data-id="${id}"]`)?.remove()
      items = items.filter(x => x.id !== id)
      if (had && self) paintCounts(-1)
    },
    posted: m => {
      if (!self) return
      paintCounts(1)
      if (current === 'posts') { items.unshift(m); list.prepend(m) }
    },
    arrived: msg => { if (msg.user === userId) fresher.hidden = false },
    close: () => sheet.close()
  }
  pages.add(page)
  fresher.addEventListener('click', () => { sheet.body.scrollTo({ top: 0, behavior: reducedMotion() ? 'auto' : 'smooth' }); select(current) })

  select(current)
  return sheet
}

// The feed's skeleton: two of its own cards with placeholder words (ui/skeleton.js), so it is
// whatever a card is.
function skeleton() {
  const fake = i => ({
    id: `sk-${i}`, user: { id: `sk-u${i}`, display: filler(2, i), username: filler(1, i + 2), avatar: null, friend: true },
    mine: false, media: [], text: filler(14, i), created: Date.now(), audience: 'everyone',
    likes: [], comments: [], liked: false, canComment: true, commenting: 'everyone', tags: []
  })
  return h('div', { class: 'mo-ghost' }, ...ghost([0, 1].map(i => card(fake(i), { owner: null }).el)))
}

// ---------------------------------------------------------------- the cards
/**
 * A list of moments as cards in `panel`. owner: whose page it is (their name
 * leads nowhere there); empty(): what to show once the last one is gone.
 */
function cards(panel, { owner, empty }) {
  const shown = new Map() // id → card
  const entrance = [{ opacity: 0, transform: 'translateY(-10px)' }, { opacity: 1, transform: 'none' }]
  const put = (m, first) => {
    const c = card(m, { owner })
    shown.set(m.id, c)
    if (first) panel.prepend(c.el)
    else panel.append(c.el)
    c.settle()
    return c
  }
  return {
    has: id => shown.has(id),
    clear() { for (const c of shown.values()) c.destroy(); shown.clear() },
    add(list) { for (const m of list) if (!shown.has(m.id)) put(m, false) },
    prepend(m) {
      if (shown.has(m.id)) return
      if (!shown.size) panel.replaceChildren()
      const c = put(m, true)
      if (!reducedMotion()) c.el.animate?.(entrance, { duration: 300, easing: 'cubic-bezier(.2,.9,.3,1)' })
    },
    apply(m) { shown.get(m.id)?.update(m) },
    drop(id) {
      const c = shown.get(id)
      if (!c) return
      shown.delete(id)
      c.destroy()
      c.el.remove()
      if (!shown.size) panel.replaceChildren(empty())
    }
  }
}

/** One moment as a card; update() takes it as the server now has it. */
function card(moment, { owner }) {
  let m = moment
  const u = m.user
  const stranger = !m.mine && !u.friend
  const when = m.scheduled ? `Scheduled for ${whenText(m.created)}` : agoLong(m.created)
  const el = h('article', { class: ['mo-item', m.scheduled && 'scheduled'], dataset: { id: m.id, user: u.id }, 'aria-label': `${nameOf(u)}, ${when}` })

  // ------------------------------------------------------------ who
  const whoInner = [avatar(u.avatar, u.display, { size: 36 }), h('span', { class: 'mo-who-text' },
    h('b', { class: 'mo-by' }, nameOf(u)),
    h('span', { class: 'mo-sub' }, stranger ? 'Suggested for you' : '@' + u.username))]
  const linked = u.id !== owner
  const who = linked
    ? h('button', { class: 'mo-who', type: 'button', 'aria-label': `${nameOf(u)}'s moments` }, whoInner)
    : h('div', { class: 'mo-who' }, whoInner)
  if (linked) who.addEventListener('click', () => openMoments({ userId: u.id, back: true, origin: who }))
  const message = stranger ? h('button', { class: 'mo-message', type: 'button', 'aria-label': `Message ${nameOf(u)}` }, 'Message') : null
  message?.addEventListener('click', () => startChat(u))
  const dots = h('button', { class: 'mo-dots', type: 'button', 'aria-label': 'More' }, icon('ellipsis'))
  dots.addEventListener('click', () => openMenu(dots, m.mine
    ? [[{ label: 'Delete', icon: 'trash', destructive: true, onSelect: () => remove() }]]
    : [[
        ...(linked ? [{ label: 'View profile', icon: 'person', onSelect: () => openMoments({ userId: u.id, back: true }) }] : []),
        { label: 'Message', icon: 'bubble', onSelect: () => startChat(u) }
      ]]))
  const head = h('header', { class: 'mo-item-head' }, who, message, dots)

  // ------------------------------------------------------------ what was shared
  const burst = h('span', { class: 'mo-burst', 'aria-hidden': 'true' }, icon('heart'))
  const pictures = m.media.length ? mediaEl(m, { burst, onDouble: () => { pop(burst); setLike(true) } }) : null
  const words = !pictures && m.text ? clamped(h('p', { class: 'mo-words' }, m.text)) : null

  // ------------------------------------------------------------ what it gathered
  const likeCount = h('span', { class: 'mo-count-n tabular' })
  const like = h('button', { class: 'mo-act mo-like', type: 'button' }, icon('heart'), likeCount)
  like.addEventListener('click', () => setLike(!m.liked))
  const talkCount = h('span', { class: 'mo-count-n tabular' })
  const talk = h('button', { class: 'mo-act mo-talk', type: 'button', 'aria-label': 'Comment' }, icon('bubble'), talkCount)
  const send = h('button', { class: 'mo-act mo-share', type: 'button', 'aria-label': 'Share' }, icon('paperplane'))
  send.addEventListener('click', () => shareMoment(m))
  const bar = h('div', { class: 'mo-bar' }, like, talk, send, pictures?.pips || null)

  const caption = pictures && m.text ? clamped(h('p', { class: 'mo-caption' }, h('b', {}, nameOf(u)), ' ', m.text)) : null
  const talkBox = h('div', { class: 'mo-talkbox' })
  let expanded = false

  const input = h('input', { class: 'mo-reply-input', type: 'text', placeholder: 'Add a comment…', maxlength: 300, enterkeyhint: 'send', autocomplete: 'off', 'aria-label': `Comment on ${nameOf(u)}'s moment` })
  const post = h('button', { class: 'mo-send', type: 'submit', 'aria-label': 'Post comment', hidden: true }, icon('arrow-up'))
  const reply = h('form', { class: 'mo-reply' }, avatar(state.me?.avatar, nameOf(state.me), { size: 26 }), input, post)
  // Who may comment is the author's to say: otherwise, a line saying so.
  const closed = m.canComment === false
    ? h('p', { class: 'mo-closed' }, icon('bubble'), m.commenting === 'off' ? 'Comments are off' : `Only ${nameOf(u)}'s friends can comment`)
    : null
  input.addEventListener('input', () => { post.hidden = !input.value.trim() })
  talk.addEventListener('click', () => { if (closed) { expanded = true; paint() } else input.focus() })
  reply.addEventListener('submit', async e => {
    e.preventDefault()
    const text = input.value.trim()
    if (!text || post.disabled) return
    post.disabled = true
    try {
      const next = (await api.post(`/api/moments/${m.id}/comments`, { text })).moment
      input.value = ''
      post.hidden = true
      everywhere('apply', next)
    } catch (err) { toast(err.message, { type: 'error' }) } finally { post.disabled = false }
  })

  const time = h('p', { class: 'mo-time' },
    m.scheduled ? h('span', { class: 'mo-scheduled' }, icon('calendar'), h('time', { datetime: new Date(m.created).toISOString() }, `Scheduled for ${whenText(m.created)}`)) : h('time', { datetime: new Date(m.created).toISOString() }, agoLong(m.created)),
    m.audience === 'friends' ? h('span', { class: 'mo-for' }, icon('people'), 'Friends') : null)

  // With friends: their names lead to their pages.
  const withEl = m.tags?.length ? h('p', { class: 'mo-with' }, icon('person'), 'With ', ...m.tags.flatMap((t, i) => {
    const b = h('button', { class: 'mo-with-name', type: 'button' }, nameOf(t))
    b.addEventListener('click', () => openMoments({ userId: t.id, back: true, origin: b }))
    const sep = i === m.tags.length - 1 ? [] : [i === m.tags.length - 2 ? ' and ' : ', ']
    return [b, ...sep]
  })) : null

  el.append(...[head, pictures?.box || words?.wrap, bar, withEl, caption?.wrap, talkBox, closed || reply, time].filter(Boolean))

  function paint() {
    like.classList.toggle('on', m.liked)
    like.setAttribute('aria-pressed', String(m.liked))
    like.setAttribute('aria-label', `${m.liked ? 'Unlike' : 'Like'}${m.likes.length ? `, ${m.likes.length} ${m.likes.length === 1 ? 'like' : 'likes'}` : ''}`)
    likeCount.textContent = m.likes.length ? String(m.likes.length) : ''
    talkCount.textContent = m.comments.length ? String(m.comments.length) : ''
    talk.setAttribute('aria-label', m.comments.length ? `Comment, ${m.comments.length} ${m.comments.length === 1 ? 'comment' : 'comments'}` : 'Comment')
    const all = m.comments
    const some = expanded ? all : all.slice(-2)
    const showAll = !expanded && all.length > 2 ? h('button', { class: 'mo-all', type: 'button' }, `View all ${all.length} comments`) : null
    showAll?.addEventListener('click', () => { expanded = true; paint() })
    talkBox.replaceChildren(...[showAll, some.length ? h('ul', { class: 'mo-comments' }, some.map(commentEl)) : null].filter(Boolean))
  }
  function commentEl(c) {
    const li = h('li', {}, h('b', {}, nameOf(c.user)), ' ', c.text)
    if (c.mine || m.mine) {
      li.tabIndex = 0
      li.setAttribute('role', 'button')
      li.setAttribute('aria-label', `${nameOf(c.user)}: ${c.text}. Delete`)
      const del = async () => {
        if (!(await confirmAction(li, { title: 'Delete this comment?', message: 'It goes for everyone who can see it.', confirm: 'Delete', destructive: true }))) return
        try { everywhere('apply', (await api.del(`/api/moments/${m.id}/comments/${c.id}`)).moment) } catch (err) { toast(err.message, { type: 'error' }) }
      }
      li.addEventListener('click', del)
      li.addEventListener('keydown', e => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); del() } })
    }
    return li
  }
  async function setLike(on) {
    if (on === m.liked) return
    const before = m
    const me = state.me
    // At once, then as the server has it.
    everywhere('apply', { ...m, liked: on, likes: on ? [...m.likes, { id: me.id, display: me.display, username: me.username, avatar: me.avatar }] : m.likes.filter(x => x.id !== me.id) })
    if (on && !reducedMotion()) like.querySelector('.icon')?.animate?.([{ transform: 'scale(1)' }, { transform: 'scale(1.35)' }, { transform: 'scale(1)' }], { duration: 320, easing: 'cubic-bezier(.3,1.6,.5,1)' })
    try { everywhere('apply', (await api.post(`/api/moments/${m.id}/like`, { on })).moment) } catch (err) { everywhere('apply', before); toast(err.message, { type: 'error' }) }
  }
  async function remove() {
    if (!(await confirmAction(dots, { title: 'Delete this moment?', message: 'Its photos, likes and comments go with it.', confirm: 'Delete', destructive: true }))) return
    try {
      await api.del(`/api/moments/${m.id}`)
      everywhere('drop', m.id)
    } catch (err) { toast(err.message, { type: 'error' }) }
  }

  paint()
  return {
    el,
    update(next) { m = { ...next, user: m.user }; paint() },
    // Once it's on the page: whether its words need a "more".
    settle() { caption?.settle(); words?.settle() },
    destroy() { quiet(el) }
  }
}

/** Words cut to a few lines, with "more" to read the rest (only when there is more). */
function clamped(p) {
  const more = h('button', { class: 'mo-more-btn', type: 'button', hidden: true }, 'more')
  const wrap = h('div', { class: 'mo-clamp' }, p, more)
  more.addEventListener('click', () => { wrap.classList.add('open'); more.hidden = true })
  return {
    wrap,
    settle: () => requestAnimationFrame(() => { if (!wrap.classList.contains('open')) more.hidden = p.scrollHeight <= p.clientHeight + 1 })
  }
}

function pop(burst) {
  burst.getAnimations?.().forEach(a => a.cancel())
  burst.animate?.(reducedMotion()
    ? [{ opacity: 0 }, { opacity: 1, offset: 0.3 }, { opacity: 0 }]
    : [
        { opacity: 0, transform: 'scale(.3)' },
        { opacity: 1, transform: 'scale(1.12)', offset: 0.32 },
        { opacity: 1, transform: 'scale(.96)', offset: 0.5 },
        { opacity: 1, transform: 'scale(1)', offset: 0.72 },
        { opacity: 0, transform: 'scale(1.08)' }
      ], { duration: 820, easing: 'cubic-bezier(.2,.8,.3,1)' })
}

async function shareMoment(m) {
  const by = nameOf(m.user)
  const text = m.text ? `${by} on Cuven: “${m.text.length > 160 ? m.text.slice(0, 157) + '…' : m.text}” (@${m.user.username})` : `${by}'s moment on Cuven (@${m.user.username})`
  try {
    if (navigator.share) await navigator.share({ title: `${by} on Cuven`, text })
    else { await navigator.clipboard.writeText(text); toast('Copied', { type: 'ok' }) }
  } catch {}
}

// ---------------------------------------------------------------- pictures
// Edge to edge, at the first picture's shape between 4:5 and 1.91:1; several
// sit side by side, one in view at a time, with where you are above (1/3)
// and below (dots). A tap opens a photo; a double tap likes it.
const ratioOf = x => (x?.w && x?.h ? Math.min(1.91, Math.max(0.8, x.w / x.h)) : 1)

function mediaEl(m, { burst, onDouble }) {
  const n = m.media.length
  const box = h('div', { class: ['mo-media', n > 1 && 'many'], style: { '--ratio': String(ratioOf(m.media[0])) } })
  let pips = null
  let at = 0
  if (n === 1) {
    box.append(slide(m, m.media[0], 0))
  } else {
    const track = h('div', { class: 'mo-track', role: 'group', 'aria-roledescription': 'carousel', 'aria-label': `${n} photos` }, m.media.map((x, i) => slide(m, x, i)))
    const index = h('span', { class: 'mo-index tabular', 'aria-hidden': 'true' }, `1/${n}`)
    pips = h('div', { class: 'mo-pips', 'aria-hidden': 'true' }, m.media.map((_, i) => h('i', { class: i ? '' : 'on' })))
    box.append(track, index)
    let hush = 0
    track.addEventListener('scroll', () => {
      const i = Math.max(0, Math.min(n - 1, Math.round(track.scrollLeft / Math.max(1, track.clientWidth))))
      box.classList.add('moving')
      clearTimeout(hush)
      hush = setTimeout(() => box.classList.remove('moving'), 1400)
      if (i === at) return
      at = i
      index.textContent = `${i + 1}/${n}`
      pips.querySelectorAll('i').forEach((p, k) => p.classList.toggle('on', k === i))
    }, { passive: true })
  }
  box.append(burst)

  // One tap waits a moment to be sure it isn't the first of two.
  let last = 0
  let timer = 0
  box.addEventListener('click', e => {
    const target = e.target.closest('.mo-slide')
    if (!target || e.target.closest('.mo-sound')) return
    if (e.target.closest('.mo-alt')) return showAlt(m.media[Number(target.dataset.i) || 0], e.target.closest('.mo-alt'))
    const i = Number(target.dataset.i) || 0
    if (e.detail === 0) return single(target, i) // the keyboard
    const now = performance.now()
    if (now - last < 300) {
      clearTimeout(timer)
      last = 0
      return onDouble()
    }
    last = now
    timer = setTimeout(() => { last = 0; single(target, i) }, 300)
  })
  function single(target, i) {
    const x = m.media[i]
    if (x.type !== 'video') return show(m, i, target)
    // A video: a tap plays it if it's still, else turns the sound on or off.
    const v = target.querySelector('video')
    if (v.paused) v.play().catch(() => {})
    else setSound(!soundOn)
  }
  return { box, pips }
}

function slide(m, x, i) {
  const n = m.media.length
  if (x.type === 'video') {
    const v = h('video', { src: x.url, muted: true, loop: true, playsInline: true, preload: 'metadata' })
    v.setAttribute('muted', '')
    v.setAttribute('playsinline', '')
    v.muted = !soundOn
    const s = h('div', { class: 'mo-slide video', role: 'group', 'aria-label': 'Video', dataset: { i: String(i) } },
      v, h('span', { class: 'mo-play', 'aria-hidden': 'true' }, icon('play')), soundButton())
    v.addEventListener('play', () => s.classList.add('playing'))
    v.addEventListener('pause', () => s.classList.remove('playing'))
    watch(v)
    return s
  }
  const label = `${n > 1 ? `Photo ${i + 1} of ${n}` : 'Photo'}${x.alt ? `: ${x.alt}` : ''}`
  return h('div', { class: 'mo-slide', dataset: { i: String(i) } },
    revealedIn(h('button', { class: 'mo-photo', type: 'button', 'aria-label': label },
      h('img', { src: x.url, alt: x.alt || '', loading: 'lazy', decoding: 'async', draggable: false }))),
    // Its description, for anyone who wants to read it.
    x.alt ? h('button', { class: 'mo-alt', type: 'button', 'aria-label': 'Read the description' }, 'ALT') : null)
}

function showAlt(x, origin) {
  const sheet = openSheet({ title: 'Description', content: h('p', { class: 'mo-alt-text' }, x.alt), origin })
  sheet.el.classList.add('mo-alt-sheet')
}

function show(m, i, from) {
  const x = m.media[i]
  if (x.type === 'video') return openViewer({ kind: 'video', fullSrc: x.url, src: x.url, w: x.w, h: x.h, label: 'Video' })
  const photos = m.media.filter(y => y.type === 'image')
  openViewer({
    thumb: from.querySelector('img'),
    images: photos.map((y, k) => ({ src: y.url, fullSrc: y.url, w: y.w, h: y.h, label: y.alt || `Photo ${k + 1} of ${photos.length}` })),
    index: photos.indexOf(x)
  })
}

// ---------------------------------------------------------------- videos
// They play, looping and without sound, while most of one is in view (not
// with Reduce Motion: then a tap plays it). Sound is one choice for them all.
let soundOn = false
const watcher = typeof IntersectionObserver === 'function' ? new IntersectionObserver(entries => {
  for (const e of entries) {
    const v = e.target
    if (e.isIntersecting && e.intersectionRatio >= 0.6) { if (!reducedMotion()) v.play().catch(() => {}) } else v.pause()
  }
}, { threshold: [0, 0.6] }) : null
const watch = v => watcher?.observe(v)
/** Everything under `root` stops: its videos pause and are no longer watched. */
function quiet(root) {
  for (const v of root.querySelectorAll('video')) { watcher?.unobserve(v); v.pause() }
}
function soundButton() {
  const b = h('button', { class: 'mo-sound', type: 'button' })
  paintSound(b)
  b.addEventListener('click', e => { e.stopPropagation(); setSound(!soundOn) })
  return b
}
function paintSound(b) {
  b.setAttribute('aria-label', soundOn ? 'Mute' : 'Unmute')
  b.setAttribute('aria-pressed', String(soundOn))
  b.replaceChildren(icon(soundOn ? 'speaker' : 'speaker-off'))
}
function setSound(on) {
  soundOn = on
  for (const v of document.querySelectorAll('.mo-slide video')) v.muted = !on
  for (const b of document.querySelectorAll('.mo-sound')) paintSound(b)
}

// ---------------------------------------------------------------- when
/** How long ago, in words: Just now, 5 minutes ago, 3 hours ago, 2 days ago, then the date. */
export function agoLong(ts, now = Date.now()) {
  const s = Math.max(0, (now - ts) / 1000)
  const n = (k, unit) => `${k} ${unit}${k === 1 ? '' : 's'} ago`
  if (s < 60) return 'Just now'
  if (s < 3600) return n(Math.floor(s / 60), 'minute')
  if (s < 86400) return n(Math.floor(s / 3600), 'hour')
  if (s < 7 * 86400) return n(Math.floor(s / 86400), 'day')
  const d = new Date(ts)
  const year = d.getFullYear() === new Date(now).getFullYear() ? '' : `, ${d.getFullYear()}`
  return `${MONTHS[d.getMonth()]} ${d.getDate()}${year}`
}

// ---------------------------------------------------------------- a new one
/** The editor (views/moments-editor.js); what it shares goes to the top of every page open. */
export function openMomentComposer({ origin, onPosted } = {}) {
  return openMomentEditor({ origin, onPosted: m => { everywhere('posted', m); onPosted?.(m) } })
}

// A picture arriving opens out of its frame (ui/reveal.js): the frame is the
// element around it once it is in the page.
function revealed(img) {
  queueMicrotask(() => img.parentElement && reveal(img, img.parentElement))
  return img
}
function revealedIn(frame) {
  const img = frame.querySelector('img')
  if (img) reveal(img, frame)
  return frame
}
