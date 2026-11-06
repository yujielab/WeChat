// Moments: what someone shares with their friends — up to nine photos, or one
// video, and a few words — and the likes and comments it gathers (src/hub.js
// keeps them; only friends see them).
//
// One page shows them, laid out as a profile: the cover across the top with
// round glass buttons over it, the photo overlapping its edge, the name in
// bold with the handle under it, when they joined, how much they've shared,
// two pill buttons, then tabs — for yourself, your friends' moments, your
// own, and everything you've shared as a wall of pictures; for someone else,
// theirs and their pictures. A round button at the foot starts a new one.

import { h, icon } from '../ui/dom.js'
import { api } from '../api.js'
import { state, upsertRoom } from '../store.js'
import { avatar } from './avatar.js'
import { openSheet, openMenu, confirmAction, toast } from './overlay.js'
import { backdropLayer, readBackdrop } from '../ui/backdrops.js'
import { openViewer } from './viewer.js'
import { prepareImage } from './composer.js'
import { listTime } from '../ui/format.js'

export const PHOTOS_MAX = 9
const VIDEO_MAX_BYTES = 30 * 1024 * 1024
const MONTHS = ['January', 'February', 'March', 'April', 'May', 'June', 'July', 'August', 'September', 'October', 'November', 'December']

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
/** After launch: is there anything from a friend newer than the last look? */
export async function checkNewMoments() {
  try {
    const { moments } = await api.get('/api/moments')
    const newest = moments.find(m => !m.mine)
    setFresh(Boolean(newest && newest.created > seen()))
  } catch {}
}

// Live: a friend shared something, a like or a comment landed, one was deleted
// (main.js passes the socket's messages on).
const pages = new Set()
export function onMomentEvent(msg) {
  if (msg.t === 'moment' && msg.user !== state.me?.id) setFresh(true)
  for (const page of pages) page.onEvent(msg)
}

// ---------------------------------------------------------------- the page
/**
 * userId: whose page (yours by default). tab: 'feed' | 'posts' | 'media'.
 * back: opened from another page (a back chevron instead of a close cross).
 */
export function openMoments({ userId = state.me?.id, tab, origin, back = false } = {}) {
  const self = userId === state.me?.id
  let current = tab || (self ? 'feed' : 'posts')
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
  const second = h('button', { class: 'mo-pill', type: 'button' }, self ? 'Edit profile' : 'Message')
  const tabs = self
    ? [['feed', 'people', 'Moments'], ['posts', 'doc', 'Posts'], ['media', 'photo', 'Media']]
    : [['posts', 'doc', 'Posts'], ['media', 'photo', 'Media']]
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

  const sheet = openSheet({ label: self ? 'Moments' : 'Profile', content, tall: true, origin })
  sheet.el.classList.add('moments-page')
  // Round glass buttons over the cover, staying put as the page scrolls.
  const close = h('button', { class: 'glass glass-btn mo-close', type: 'button', 'aria-label': back ? 'Back' : 'Close' }, icon(back ? 'chevron-left' : 'xmark'))
  close.addEventListener('click', () => sheet.close())
  const compose = h('button', { class: 'mo-compose', type: 'button', 'aria-label': 'New moment', hidden: !self }, icon('plus'))
  compose.addEventListener('click', () => openMomentComposer({ origin: compose, onPosted: m => { if (current !== 'media') prepend(m); paintCounts(1) } }))
  // Once the cover has scrolled away, a bar fills in behind the button with
  // the name in it, and the tabs keep to its foot.
  const barName = h('span', { class: 'mo-topbar-name', 'aria-hidden': 'true' })
  sheet.el.append(h('div', { class: 'mo-topbar' }, close, barName), compose)
  sheet.body.addEventListener('scroll', () => {
    sheet.el.classList.toggle('mo-scrolled', sheet.body.scrollTop > cover.offsetHeight - 68)
    if (!loading && !done && sheet.body.scrollTop + sheet.body.clientHeight > sheet.body.scrollHeight - 400) load()
  }, { passive: true })

  // ------------------------------------------------------------ header
  function paintHeader(u) {
    const look = readBackdrop(u.cover)
    cover.replaceChildren(backdropLayer(look ? u.cover : ''))
    cover.classList.toggle('plain', !look)
    face.replaceChildren(avatar(u.avatar, u.display, { size: 96 }))
    name.textContent = u.display || u.username
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
    counts.replaceChildren(...parts)
  }
  share.addEventListener('click', async () => {
    const u = profile?.user || state.me
    const text = `Find ${u.display || u.username} on Cuven: @${u.username}`
    try {
      if (navigator.share) await navigator.share({ title: u.display || u.username, text })
      else { await navigator.clipboard.writeText(text); toast('Copied', { type: 'ok' }) }
    } catch {}
  })
  second.addEventListener('click', async () => {
    if (self) {
      const { openEditProfile } = await import('./sheets.js')
      openEditProfile(next => { paintHeader({ ...profile?.user, ...next }) })
      return
    }
    try {
      const r = await api.post('/api/dm', { user: userId })
      upsertRoom(r.room)
      sheet.close()
      window.dispatchEvent(new CustomEvent('open-chat', { detail: r.room.id }))
    } catch (err) { toast(err.message, { type: 'error' }) }
  })

  // ------------------------------------------------------------ tabs and loading
  function select(id) {
    current = id
    const i = tabs.findIndex(t => t[0] === id)
    tabBar.style.setProperty('--i', String(i))
    tabBar.style.setProperty('--n', String(tabs.length))
    for (const b of tabBar.querySelectorAll('.mo-tab')) b.setAttribute('aria-selected', String(b.dataset.tab === id))
    if (id === 'feed') markSeen()
    fresher.hidden = true
    items = []
    done = false
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
      const r = current === 'feed' ? await api.get(`/api/moments${before}`) : await api.get(`/api/moments/user/${userId}${before}`)
      if (tabNow !== current) return
      if (r.user && first) {
        profile = { user: r.user, count: r.count, friends: r.friends, visible: r.visible }
        paintHeader(r.user)
        paintCounts()
      }
      const list = r.moments || []
      done = list.length < 20
      if (first) panel.replaceChildren()
      items.push(...list)
      if (current === 'media') paintWall(list, first)
      else for (const m of list) panel.append(momentEl(m))
      if (first && !items.length) panel.replaceChildren(emptyEl(r))
    } catch (err) {
      if (first) panel.replaceChildren(h('p', { class: 'mo-empty' }, err.message || "Can't load moments"))
    } finally {
      loading = false
      more.hidden = done
    }
  }
  // Someone else's profile loads its header even when the feed is the tab.
  if (current === 'feed') api.get(`/api/moments/user/${userId}?limit=0`).then(r => {
    profile = { user: r.user, count: r.count, friends: r.friends, visible: r.visible }
    paintHeader(r.user)
    paintCounts()
  }).catch(() => {})

  function emptyEl(r) {
    if (r && r.visible === false) return h('div', { class: 'mo-empty' }, h('b', {}, 'Moments are for friends'), h('span', {}, `Chat with ${r.user?.display || 'them'} to see what they share.`))
    if (current === 'feed') return h('div', { class: 'mo-empty' }, h('b', {}, 'Nothing here yet'), h('span', {}, 'What you and your friends share shows up here.'))
    if (self) {
      const go = h('button', { class: 'mo-pill solid', type: 'button' }, 'Share a moment')
      go.addEventListener('click', () => compose.click())
      return h('div', { class: 'mo-empty' }, h('b', {}, 'Share your first moment'), h('span', {}, 'Photos or a video, and a few words, for your friends.'), go)
    }
    return h('div', { class: 'mo-empty' }, h('b', {}, 'Nothing shared yet'))
  }
  function skeleton() {
    return h('div', { class: 'mo-skeleton', 'aria-hidden': 'true' }, [0, 1].map(() => h('div', { class: 'mo-skel-item' }, h('i', { class: 'a' }), h('div', {}, h('i', { class: 'l1' }), h('i', { class: 'l2' }), h('i', { class: 'm' })))))
  }
  function prepend(m) {
    if (current === 'media') return
    if (!items.length) panel.replaceChildren()
    items.unshift(m)
    const el = momentEl(m)
    panel.prepend(el)
    el.animate?.([{ opacity: 0, transform: 'translateY(-8px)' }, { opacity: 1, transform: 'none' }], { duration: 260, easing: 'cubic-bezier(.2,.9,.3,1)' })
  }

  // ------------------------------------------------------------ one moment
  function momentEl(m) {
    const el = h('article', { class: 'mo-item', dataset: { id: m.id } })
    paintMoment(el, m)
    return el
  }
  function paintMoment(el, m) {
    const who = h('button', { class: 'mo-who', type: 'button', 'aria-label': `${m.user.display}'s profile` }, avatar(m.user.avatar, m.user.display, { size: 44 }))
    who.addEventListener('click', () => { if (m.user.id !== userId) openMoments({ userId: m.user.id, back: true }) })
    const menu = m.mine ? h('button', { class: 'mo-dots', type: 'button', 'aria-label': 'More' }, icon('ellipsis')) : null
    menu?.addEventListener('click', () => openMenu(menu, [[{ label: 'Delete', icon: 'trash', destructive: true, onSelect: () => removeMoment(m, el) }]]))
    const like = h('button', { class: ['mo-act', 'mo-like', m.liked && 'on'], type: 'button', 'aria-pressed': String(m.liked), 'aria-label': m.liked ? 'Unlike' : 'Like' },
      icon('heart'), h('span', { class: 'tabular' }, m.likes.length ? String(m.likes.length) : ''))
    like.addEventListener('click', () => toggleLike(m, el))
    const talk = h('button', { class: 'mo-act mo-talk', type: 'button', 'aria-label': 'Comment' }, icon('bubble'), h('span', { class: 'tabular' }, m.comments.length ? String(m.comments.length) : ''))
    const reply = replyForm(m, el)
    talk.addEventListener('click', () => { reply.hidden = !reply.hidden; if (!reply.hidden) reply.querySelector('input').focus() })
    const social = socialEl(m, el)
    el.replaceChildren(
      who,
      h('div', { class: 'mo-main' },
        h('div', { class: 'mo-byline' }, h('b', { class: 'mo-by' }, m.user.display || m.user.username), h('span', { class: 'mo-at' }, `@${m.user.username} · ${ago(m.created)}`), menu),
        m.text ? h('p', { class: 'mo-text' }, m.text) : null,
        m.media.length ? mediaEl(m) : null,
        h('div', { class: 'mo-bar' }, talk, like),
        social,
        reply))
  }
  function socialEl(m, el) {
    if (!m.likes.length && !m.comments.length) return null
    const likes = m.likes.length ? h('p', { class: 'mo-likes' }, icon('heart'), m.likes.map(u => u.display || u.username).join(', ')) : null
    const comments = m.comments.length ? h('ul', { class: 'mo-comments' }, m.comments.map(c => {
      const li = h('li', {}, h('b', {}, c.user.display || c.user.username), ' ', c.text)
      if (c.mine || m.mine) {
        li.tabIndex = 0
        li.setAttribute('role', 'button')
        li.setAttribute('aria-label', `${c.user.display}: ${c.text}. Delete`)
        li.addEventListener('click', async () => {
          if (!(await confirmAction(li, { title: 'Delete this comment?', confirm: 'Delete', destructive: true }))) return
          try { replace(el, (await api.del(`/api/moments/${m.id}/comments/${c.id}`)).moment) } catch (err) { toast(err.message, { type: 'error' }) }
        })
      }
      return li
    })) : null
    return h('div', { class: 'mo-social' }, likes, comments)
  }
  function replyForm(m, el) {
    const input = h('input', { class: 'input', type: 'text', placeholder: 'Add a comment', maxlength: 300, enterkeyhint: 'send', 'aria-label': 'Comment' })
    const send = h('button', { class: 'mo-send', type: 'submit', 'aria-label': 'Send' }, icon('arrow-up'))
    const form = h('form', { class: 'mo-reply', hidden: true }, input, send)
    form.addEventListener('submit', async e => {
      e.preventDefault()
      const text = input.value.trim()
      if (!text) return
      send.disabled = true
      try {
        replace(el, (await api.post(`/api/moments/${m.id}/comments`, { text })).moment)
      } catch (err) { toast(err.message, { type: 'error' }); send.disabled = false }
    })
    return form
  }
  function replace(el, m) {
    const i = items.findIndex(x => x.id === m.id)
    if (i >= 0) items[i] = m
    if (el?.isConnected) paintMoment(el, m)
  }
  async function toggleLike(m, el) {
    const on = !m.liked
    // At once, then as the server has it.
    const me = state.me
    replace(el, { ...m, liked: on, likes: on ? [...m.likes, { id: me.id, display: me.display, username: me.username }] : m.likes.filter(u => u.id !== me.id) })
    if (on) el.querySelector('.mo-like .icon')?.animate?.([{ transform: 'scale(1)' }, { transform: 'scale(1.35)' }, { transform: 'scale(1)' }], { duration: 320, easing: 'cubic-bezier(.3,1.6,.5,1)' })
    try { replace(el, (await api.post(`/api/moments/${m.id}/like`, { on })).moment) } catch (err) { replace(el, m); toast(err.message, { type: 'error' }) }
  }
  async function removeMoment(m, el) {
    if (!(await confirmAction(el, { title: 'Delete this moment and its comments?', confirm: 'Delete', destructive: true }))) return
    try {
      await api.del(`/api/moments/${m.id}`)
      items = items.filter(x => x.id !== m.id)
      el.remove()
      paintCounts(-1)
      if (!items.length) panel.replaceChildren(emptyEl())
    } catch (err) { toast(err.message, { type: 'error' }) }
  }

  // ------------------------------------------------------------ pictures
  function mediaEl(m) {
    const n = m.media.length
    const grid = h('div', { class: 'mo-media', dataset: { n: String(n) } })
    if (n === 1) {
      const x = m.media[0]
      const ratio = x.w && x.h ? Math.min(1.8, Math.max(0.6, x.w / x.h)) : 4 / 3
      grid.style.setProperty('--ratio', String(ratio))
    }
    m.media.forEach((x, i) => grid.append(tile(m, x, i)))
    return grid
  }
  function tile(m, x, i) {
    const b = h('button', { class: ['mo-tile', x.type === 'video' && 'video'], type: 'button', 'aria-label': x.type === 'video' ? 'Play video' : `Photo ${i + 1} of ${m.media.length}` })
    if (x.type === 'video') b.append(h('video', { src: x.url + '#t=0.1', muted: true, playsInline: true, preload: 'metadata' }), h('span', { class: 'mo-play' }, icon('play')))
    else b.append(h('img', { src: x.url, alt: '', loading: 'lazy', decoding: 'async', draggable: false }))
    b.addEventListener('click', () => show(m, i, b))
    return b
  }
  function show(m, i, from) {
    const x = m.media[i]
    if (x.type === 'video') return openViewer({ kind: 'video', fullSrc: x.url, src: x.url, w: x.w, h: x.h, label: 'Video' })
    const photos = m.media.filter(y => y.type === 'image')
    openViewer({
      thumb: from.querySelector('img'),
      images: photos.map((y, k) => ({ src: y.url, fullSrc: y.url, w: y.w, h: y.h, label: `Photo ${k + 1} of ${photos.length}` })),
      index: photos.indexOf(x)
    })
  }
  // The pictures as a wall: two columns of cards of their own heights, each a
  // moment's first picture with its words under it.
  let wall = null
  function paintWall(list, first) {
    if (first || !wall) {
      wall = [h('div', { class: 'mo-col' }), h('div', { class: 'mo-col' })]
      panel.replaceChildren(h('div', { class: 'mo-wall' }, ...wall))
    }
    for (const m of list) {
      if (!m.media.length) continue
      const x = m.media[0]
      const ratio = x.w && x.h ? Math.min(1.5, Math.max(0.66, x.w / x.h)) : 1
      const card = h('button', { class: 'mo-card', type: 'button', 'aria-label': m.text || 'Moment' },
        h('span', { class: ['mo-card-pic', x.type === 'video' && 'video'], style: { aspectRatio: String(ratio) } },
          x.type === 'video' ? h('video', { src: x.url + '#t=0.1', muted: true, playsInline: true, preload: 'metadata' }) : h('img', { src: x.url, alt: '', loading: 'lazy', decoding: 'async', draggable: false }),
          x.type === 'video' ? h('span', { class: 'mo-play' }, icon('play')) : m.media.length > 1 ? h('span', { class: 'mo-count' }, `${m.media.length}`) : null),
        m.text ? h('span', { class: 'mo-card-text' }, m.text) : null,
        h('span', { class: 'mo-card-foot' }, avatar(m.user.avatar, m.user.display, { size: 20 }), h('span', { class: 'mo-card-name' }, m.user.display), h('span', { class: 'mo-card-likes' }, icon('heart'), m.likes.length ? String(m.likes.length) : '')))
      card.addEventListener('click', () => show(m, 0, card))
      // The shorter column takes the next card.
      const [a, b] = wall
      ;(a.offsetHeight <= b.offsetHeight ? a : b).append(card)
    }
    if (first && !panel.querySelector('.mo-card')) panel.replaceChildren(emptyEl(profile))
  }

  // ------------------------------------------------------------ live
  const page = {
    async onEvent(msg) {
      if (!sheet.el.isConnected) return pages.delete(page)
      const el = panel.querySelector(`.mo-item[data-id="${msg.id}"]`)
      if (msg.t === 'moment-deleted' && el) {
        items = items.filter(x => x.id !== msg.id)
        el.remove()
      } else if (msg.t === 'moment-changed' && el) {
        try { replace(el, (await api.get(`/api/moments/${msg.id}`)).moment) } catch {}
      } else if (msg.t === 'moment' && msg.user !== state.me?.id && (current === 'feed' || msg.user === userId)) {
        fresher.hidden = false
      }
    }
  }
  pages.add(page)
  fresher.addEventListener('click', () => { sheet.body.scrollTo({ top: 0, behavior: 'smooth' }); select(current) })

  select(current)
  return sheet
}

/** How long ago, briefly: Just now, 5m, 3h, then the day. */
export function ago(ts, now = Date.now()) {
  const s = Math.max(0, (now - ts) / 1000)
  if (s < 60) return 'Just now'
  if (s < 3600) return `${Math.floor(s / 60)}m`
  if (s < 86400) return `${Math.floor(s / 3600)}h`
  return listTime(ts)
}

// ---------------------------------------------------------------- a new one
/**
 * The composer: a few words, and up to nine photos or one video, picked from
 * the library, shown as they'll be shared, uploaded on Post.
 */
export function openMomentComposer({ origin, onPosted } = {}) {
  const picks = [] // { file, url, type, w, h }
  const text = h('textarea', { class: 'mo-compose-text', placeholder: 'Share something with your friends…', maxlength: 2000, rows: 4, 'aria-label': 'What you want to say' })
  const file = h('input', { type: 'file', accept: 'image/*,video/*', multiple: true, hidden: true })
  const add = h('button', { class: 'mo-pick-add', type: 'button', 'aria-label': 'Add photos or a video' }, icon('plus'))
  const grid = h('div', { class: 'mo-picks' })
  const note = h('p', { class: 'mo-compose-note' }, `Up to ${PHOTOS_MAX} photos, or 1 video`)
  const post = h('button', { class: 'glass glass-btn mo-post', type: 'button', 'aria-label': 'Post', disabled: true }, icon('arrow-up'))
  const cancel = h('button', { class: 'glass glass-btn', type: 'button', 'aria-label': 'Cancel' }, icon('xmark'))
  const content = h('div', { class: 'mo-composer-body' }, text, grid, note, file)
  const sheet = openSheet({ title: 'New moment', content, start: cancel, end: post, origin })
  sheet.el.classList.add('mo-composer')
  cancel.addEventListener('click', () => sheet.close())

  const ready = () => { post.disabled = !(text.value.trim() || picks.length) }
  text.addEventListener('input', () => {
    text.style.height = 'auto'
    text.style.height = `${Math.min(260, text.scrollHeight)}px`
    ready()
  })
  function paint() {
    const video = picks.some(p => p.type === 'video')
    grid.replaceChildren(...picks.map((p, i) => {
      const x = h('button', { class: 'mo-pick-x', type: 'button', 'aria-label': 'Remove' }, icon('xmark'))
      x.addEventListener('click', () => { URL.revokeObjectURL(p.url); picks.splice(i, 1); paint() })
      return h('div', { class: ['mo-pick', p.type === 'video' && 'video'] },
        p.type === 'video' ? h('video', { src: p.url, muted: true, playsInline: true, preload: 'metadata' }) : h('img', { src: p.url, alt: '' }),
        p.type === 'video' ? h('span', { class: 'mo-play' }, icon('play')) : null, x)
    }), ...(video || picks.length >= PHOTOS_MAX ? [] : [add]))
    ready()
  }
  add.addEventListener('click', () => file.click())
  file.addEventListener('change', async () => {
    const chosen = [...file.files]
    file.value = ''
    for (const f of chosen) {
      const video = f.type.startsWith('video/')
      if (video && (picks.length || chosen.length > 1)) { toast('A video goes on its own', { type: 'error' }); continue }
      if (!video && !f.type.startsWith('image/')) continue
      if (picks.some(p => p.type === 'video') || picks.length >= PHOTOS_MAX) { toast(`Up to ${PHOTOS_MAX} photos, or 1 video`); break }
      if (video) {
        if (f.size > VIDEO_MAX_BYTES) { toast('That video is too large (30 MB at most)', { type: 'error' }); continue }
        const url = URL.createObjectURL(f)
        const [w, hh] = await videoSize(url)
        picks.push({ file: f, url, type: 'video', w, h: hh })
      } else {
        const { file: prepared, w, h: hh } = await prepareImage(f)
        picks.push({ file: prepared, url: URL.createObjectURL(prepared), type: 'image', w, h: hh })
      }
      paint()
    }
  })

  post.addEventListener('click', async () => {
    post.disabled = true
    sheet.el.classList.add('posting')
    try {
      const media = []
      for (const [i, p] of picks.entries()) {
        note.textContent = picks.length > 1 ? `Uploading ${i + 1} of ${picks.length}…` : 'Uploading…'
        const res = await fetch(`/api/media/upload?kind=moment&name=moment&w=${p.w || ''}&h=${p.h || ''}`, {
          method: 'POST', credentials: 'same-origin', headers: { 'content-type': p.file.type || (p.type === 'video' ? 'video/mp4' : 'image/jpeg') }, body: p.file
        })
        const data = await res.json().catch(() => ({}))
        if (!res.ok || !data.ok) throw new Error(data.error || 'Upload failed')
        media.push({ url: data.url, type: p.type, w: p.w, h: p.h })
      }
      note.textContent = 'Sharing…'
      const r = await api.post('/api/moments', { text: text.value, media })
      for (const p of picks) URL.revokeObjectURL(p.url)
      sheet.close()
      toast('Shared with your friends', { type: 'ok' })
      onPosted?.(r.moment)
    } catch (err) {
      toast(err.message || "Couldn't share it", { type: 'error' })
      note.textContent = `Up to ${PHOTOS_MAX} photos, or 1 video`
      sheet.el.classList.remove('posting')
      post.disabled = false
    }
  })
  paint()
  requestAnimationFrame(() => text.focus({ preventScroll: true }))
  return sheet
}

function videoSize(url) {
  return new Promise(resolve => {
    const v = document.createElement('video')
    v.preload = 'metadata'
    v.muted = true
    v.onloadedmetadata = () => resolve([v.videoWidth || 0, v.videoHeight || 0])
    v.onerror = () => resolve([0, 0])
    setTimeout(() => resolve([0, 0]), 4000)
    v.src = url
  })
}
