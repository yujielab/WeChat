// People in the Messages list (views/chatList.js), after the Instagram inbox:
// notes along the top — a line each, for a day, above your friends' photos,
// with yours first to share one; Requests beside the filters, for whoever
// wants to add you; and under the chats, who to start a chat with (your
// contacts with no chat yet: "Tap to chat") and people you may know (friends
// of your friends, people sharing moments, newcomers) to add or set aside,
// with a card to invite friends (src/hub.js: /api/notes, /api/people).

import { tip } from '../ui/guides.js'
import { h, icon, reducedMotion } from '../ui/dom.js'
import { api } from '../api.js'
import { state, on, upsertRoom, setContacts } from '../store.js'
import { avatar } from './avatar.js'
import { openSheet, toast } from './overlay.js'

export const NOTE_MAX = 60
const nameOf = u => u?.display || u?.username || ''
const debounce = (fn, ms = 300) => { let t = 0; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms) } }
const safe = (get, fallback) => { try { return get() } catch { return fallback } }

/** How long ago, in a word or two: now, 5m, 3h. */
function since(ts, now = Date.now()) {
  const s = Math.max(0, (now - ts) / 1000)
  if (s < 60) return 'now'
  if (s < 3600) return `${Math.floor(s / 60)}m`
  return `${Math.floor(s / 3600)}h`
}

/** A chat with them: the one there is, or a new one. */
async function chatWith(user) {
  const r = await api.post('/api/dm', { user: user.id })
  upsertRoom(r.room)
  return r.room.id
}

/** The contacts as the server has them now (requests included). */
async function reloadContacts() {
  try { setContacts((await api.get('/api/contacts')).contacts) } catch {}
}

// ---------------------------------------------------------------- notes
/**
 * The row of notes: yours first (a thought bubble over your photo, "Your
 * note"), then your friends' while they last, newest first. Tap yours to
 * write one; tap a friend's to read it and reply in your chat with them.
 */
export function createNotes({ onOpen }) {
  const el = h('ul', { class: 'notes', 'aria-label': 'Notes' })
  let mine = null
  let notes = []

  async function load() {
    try {
      const r = await api.get('/api/notes')
      mine = r.mine
      notes = r.notes || []
      paint()
    } catch {}
  }
  function paint() {
    const you = noteItem({ user: state.me, text: mine?.text || '', label: 'Your note', mine: true })
    if (!mine?.text) tip('notes', '.notes .note-mine', { title: 'Share a note', text: 'Friends see it for 24 hours.' })
    you.addEventListener('click', () => openNoteEditor({ origin: you, mine, onSaved: next => { mine = next; paint() } }))
    const others = notes.map(n => {
      const b = noteItem({ user: n.user, text: n.text, label: nameOf(n.user), at: n.created })
      b.addEventListener('click', () => openNote(n, { origin: b, onOpen }))
      return b
    })
    el.replaceChildren(...[you, ...others].map(b => h('li', {}, b)))
  }
  // Someone's note changed (or yours, on another device): read them again.
  const changed = debounce(load, 250)
  window.addEventListener('note-changed', changed)
  // A note lasts a day: once an hour, drop those that have gone.
  setInterval(() => {
    const now = Date.now()
    const live = notes.filter(n => n.expires > now)
    const gone = mine && mine.expires <= now
    if (live.length !== notes.length || gone) {
      notes = live
      if (gone) mine = null
      paint()
    }
  }, 60 * 60 * 1000)
  paint()
  load()
  return { el, refresh: load }
}

function noteItem({ user, text, label, mine = false, at }) {
  const empty = !text
  return h('button', {
    class: ['note', mine && 'note-mine'],
    type: 'button',
    dataset: { user: user?.id || '' },
    'aria-label': mine ? (empty ? 'Share a note' : `Your note: ${text}`) : `${label}'s note: ${text}${at ? `, ${since(at)} ago` : ''}`
  },
    h('span', { class: ['note-bubble', empty && 'empty'], 'aria-hidden': 'true' }, h('span', { class: 'note-text' }, empty ? 'Share a thought…' : text), h('i', { class: 'note-tail' })),
    h('span', { class: 'note-face', 'aria-hidden': 'true' }, avatar(user?.avatar, nameOf(user), { size: 60 }), mine && empty ? h('span', { class: 'note-plus' }, icon('plus')) : null),
    h('span', { class: 'note-name', 'aria-hidden': 'true' }, label))
}

/** Writing your note: one line over your photo, as friends will see it, for a day. */
export function openNoteEditor({ origin, mine, onSaved } = {}) {
  const input = h('input', { class: 'note-input', type: 'text', maxlength: NOTE_MAX, value: mine?.text || '', placeholder: 'Share a thought…', enterkeyhint: 'done', autocomplete: 'off', 'aria-label': 'Your note' })
  const count = h('span', { class: 'note-count tabular', 'aria-hidden': 'true' })
  const share = h('button', { class: 'glass glass-btn note-share', type: 'button', 'aria-label': 'Share note' }, icon('arrow-up'))
  const cancel = h('button', { class: 'glass glass-btn', type: 'button', 'aria-label': 'Cancel' }, icon('xmark'))
  const remove = mine ? h('button', { class: 'note-remove', type: 'button' }, icon('trash'), 'Delete note') : null
  const content = h('div', { class: 'note-editor' },
    h('div', { class: 'note-preview' },
      h('label', { class: 'note-bubble big' }, input, h('i', { class: 'note-tail' })),
      avatar(state.me?.avatar, nameOf(state.me), { size: 96 })),
    count,
    h('p', { class: 'note-hint' }, mine ? `Shared ${since(mine.created)} ago. Friends see it above your photo in their Messages for 24 hours.` : 'Friends see it above your photo in their Messages for 24 hours.'),
    remove)
  const sheet = openSheet({ title: 'Note', content, start: cancel, end: share, origin })
  sheet.el.classList.add('note-sheet')
  cancel.addEventListener('click', () => sheet.close())
  const paint = () => {
    const n = Array.from(input.value).length
    count.textContent = `${n}/${NOTE_MAX}`
    share.disabled = !input.value.trim() || input.value.trim() === (mine?.text || '')
  }
  input.addEventListener('input', paint)
  input.addEventListener('keydown', e => { if (e.key === 'Enter' && !share.disabled) share.click() })
  async function save(text) {
    share.disabled = true
    try {
      const r = text ? await api.post('/api/note', { text }) : await api.del('/api/note')
      sheet.close()
      toast(text ? 'Note shared' : 'Note deleted', { type: 'ok' })
      onSaved?.(r.mine || null)
    } catch (err) { toast(err.message, { type: 'error' }); paint() }
  }
  share.addEventListener('click', () => save(input.value.trim()))
  remove?.addEventListener('click', () => save(''))
  paint()
  requestAnimationFrame(() => input.focus({ preventScroll: true }))
  return sheet
}

/** A friend's note, large, with a line to reply in your chat with them. */
function openNote(n, { origin, onOpen }) {
  const input = h('input', { class: 'input note-reply-input', type: 'text', maxlength: 500, placeholder: `Reply to ${nameOf(n.user)}…`, enterkeyhint: 'send', autocomplete: 'off', 'aria-label': `Reply to ${nameOf(n.user)}` })
  const send = h('button', { class: 'note-reply-send', type: 'submit', 'aria-label': 'Send', disabled: true }, icon('arrow-up'))
  const form = h('form', { class: 'note-reply' }, input, send)
  const content = h('div', { class: 'note-editor note-reading' },
    h('div', { class: 'note-preview' },
      h('span', { class: 'note-bubble big' }, h('span', { class: 'note-text' }, n.text), h('i', { class: 'note-tail' })),
      avatar(n.user.avatar, nameOf(n.user), { size: 96 })),
    h('p', { class: 'note-who' }, h('b', {}, nameOf(n.user)), ` · ${since(n.created)}`),
    form)
  const sheet = openSheet({ label: `${nameOf(n.user)}'s note`, content, origin })
  sheet.el.classList.add('note-sheet')
  input.addEventListener('input', () => { send.disabled = !input.value.trim() })
  form.addEventListener('submit', async e => {
    e.preventDefault()
    const text = input.value.trim()
    if (!text) return
    send.disabled = true
    try {
      const room = await chatWith(n.user)
      await api.post('/api/messages', { room, type: 'text', text: `Replied to your note “${n.text}”\n${text}` })
      sheet.close()
      onOpen(room)
    } catch (err) { toast(err.message, { type: 'error' }); send.disabled = false }
  })
  requestAnimationFrame(() => input.focus({ preventScroll: true }))
  return sheet
}

// ---------------------------------------------------------------- requests
/** "Requests" beside the filters, with how many are waiting. */
export function createRequestsLink() {
  const count = h('span', { class: 'requests-count tabular', hidden: true })
  const el = h('button', { class: 'list-requests', type: 'button' }, 'Requests', count)
  const paint = () => {
    const n = state.contacts.filter(c => c.state === 'pending_in').length
    count.hidden = !n
    count.textContent = n > 99 ? '99+' : String(n)
    el.classList.toggle('waiting', n > 0)
    el.setAttribute('aria-label', n ? `Requests, ${n} waiting` : 'Requests')
  }
  on('contacts', paint)
  el.addEventListener('click', () => openRequests({ origin: el }))
  paint()
  return el
}

/** Who wants to add you (Accept, or ×), and whom you've asked (Cancel). */
export function openRequests({ origin, page = false, swap = false } = {}) {
  const body = h('div', { class: 'people-sheet' })
  const sheet = openSheet({ title: 'Requests', content: body, tall: true, origin, side: 'list', page, swap })
  sheet.el.classList.add('requests-sheet')
  function paint() {
    const incoming = state.contacts.filter(c => c.state === 'pending_in')
    const sent = state.contacts.filter(c => c.state === 'pending_out')
    const parts = []
    if (incoming.length) {
      parts.push(h('h3', { class: 'people-title' }, 'Wants to add you'))
      parts.push(h('ul', { class: 'people-list' }, incoming.map(u => h('li', {}, personRow(u, {
        sub: '@' + u.username,
        action: { label: 'Accept', solid: true, run: () => act('/api/contacts/accept', u, 'Added to your contacts') },
        dismiss: { label: `Decline ${nameOf(u)}`, run: () => act('/api/contacts/remove', u) }
      })))))
    }
    if (sent.length) {
      parts.push(h('h3', { class: 'people-title' }, 'Sent'))
      parts.push(h('ul', { class: 'people-list' }, sent.map(u => h('li', {}, personRow(u, {
        sub: 'Request sent',
        action: { label: 'Cancel', run: () => act('/api/contacts/remove', u) }
      })))))
    }
    if (!parts.length) parts.push(h('div', { class: 'people-empty' }, icon('person-plus'), h('b', {}, 'No requests'), h('span', {}, 'Friend requests appear here.')))
    body.replaceChildren(...parts)
  }
  async function act(path, u, done) {
    try {
      await api.post(path, { user: u.id })
      await reloadContacts()
      if (done) toast(done, { type: 'ok' })
    } catch (err) { toast(err.message, { type: 'error' }) }
  }
  const off = on('contacts', () => { if (sheet.el.isConnected) paint(); else off() })
  paint()
  return sheet
}

// ---------------------------------------------------------------- suggested, and people you may know
/**
 * Under the chats: Suggested (your contacts you've no chat with: "Tap to
 * chat"), then People you may know (Add, or × to set them aside; See all),
 * led by a card to invite friends.
 */
export function createPeople({ onOpen }) {
  const suggestedList = h('ul', { class: 'people-list' })
  const suggested = h('section', { class: 'people-section people-suggested', hidden: true, 'aria-label': 'Suggested' },
    h('h2', { class: 'people-title' }, 'Suggested'), suggestedList)
  const all = h('button', { class: 'people-all', type: 'button' }, 'See all')
  const discoverList = h('ul', { class: 'people-list' })
  const discover = h('section', { class: 'people-section people-discover', hidden: true, 'aria-label': 'People you may know' },
    h('div', { class: 'people-head' }, h('h2', { class: 'people-title' }, 'People you may know'), all), discoverList)
  const el = h('div', { class: 'people' }, suggested, discover)
  const SHOWN = 5
  let data = { suggested: [], discover: [] }
  let last = 0
  // Whom you've added here: they stay where they were, saying Requested,
  // though the server no longer suggests them.
  const requested = new Map()

  let later = 0
  async function load(force = false) {
    // Chats change often (every message); people, rarely. Asked again at most
    // every few seconds, and once more at the end of a busy spell.
    clearTimeout(later)
    const wait = 3000 - (Date.now() - last)
    if (!force && wait > 0) { later = setTimeout(() => load(), wait); return }
    last = Date.now()
    try {
      const next = await api.get('/api/people')
      for (const [id, u] of requested) if (!next.discover.some(x => x.id === id)) next.discover.splice(Math.min(u.at, next.discover.length), 0, u)
      data = next
      paint()
    } catch {}
  }
  function paint() {
    suggested.hidden = !data.suggested.length
    suggestedList.replaceChildren(...data.suggested.map(u => h('li', {}, personRow(u, {
      sub: 'Tap to chat',
      onTap: () => open(u)
    }))))
    const invite = inviteCard()
    const people = data.discover.slice(0, SHOWN)
    discover.hidden = !people.length && !invite
    all.hidden = data.discover.length <= SHOWN
    discoverList.replaceChildren(...[invite, ...people.map(u => discoverRow(u))].filter(Boolean).map(x => h('li', {}, x)))
  }
  async function open(u) {
    try { onOpen(await chatWith(u)) } catch (err) { toast(err.message, { type: 'error' }) }
  }
  function discoverRow(u) {
    const added = { label: 'Requested', disabled: true }
    const row = personRow(u, {
      sub: u.reason,
      onTap: async () => (await import('./moments.js')).openMoments({ userId: u.id, origin: row }),
      action: u.requested ? added : { label: 'Add', solid: true, run: async btn => {
        try {
          await api.post('/api/contacts/add', { user: u.id })
          requested.set(u.id, { ...u, requested: true, at: Math.max(0, data.discover.findIndex(x => x.id === u.id)) })
          data.discover = data.discover.map(x => x.id === u.id ? requested.get(u.id) : x)
          btn.replaceWith(actionButton(added))
          await reloadContacts()
        } catch (err) { toast(err.message, { type: 'error' }) }
      } },
      dismiss: { label: `Remove ${nameOf(u)} from suggestions`, run: () => setAside(u, row) }
    })
    return row
  }
  async function setAside(u, row) {
    data.discover = data.discover.filter(x => x.id !== u.id)
    const li = row.closest('li')
    if (li && !reducedMotion()) {
      li.style.height = `${li.offsetHeight}px`
      void li.offsetHeight
      li.classList.add('leaving')
      li.style.height = '0px'
      await new Promise(r => setTimeout(r, 220))
    }
    paint()
    try { await api.post('/api/people/dismiss', { user: u.id }) } catch {}
  }
  all.addEventListener('click', () => openAllPeople({ origin: all, people: data.discover, row: discoverRow }))

  // The invite card, until it's set aside.
  const INVITE_KEY = 'people:invite-dismissed'
  function inviteCard() {
    if (safe(() => localStorage.getItem(INVITE_KEY), null)) return null
    const card = h('div', { class: 'person-row invite-card' },
      h('span', { class: 'invite-icon', 'aria-hidden': 'true' }, icon('person-plus')),
      h('span', { class: 'person-text' }, h('b', { class: 'person-name' }, 'Invite friends'), h('span', { class: 'person-sub' }, 'Send friends a link to Cuven.')),
      actionButton({ label: 'Share', solid: true, run: () => inviteFriends() }),
      dismissButton({ label: 'Hide invite', run: () => { safe(() => localStorage.setItem(INVITE_KEY, '1')); paint() } }))
    return card
  }

  // Kept current: when chats or contacts change, and when the list comes back into view.
  const refresh = debounce(() => load(), 800)
  on('chats', refresh)
  on('contacts', () => load(true))
  document.addEventListener('visibilitychange', () => { if (document.visibilityState === 'visible') load() })
  load(true)
  return { el, refresh: () => load(true) }
}

/** Invite friends: the system's share sheet (or a copied line) with a link to Cuven. */
export async function inviteFriends() {
  const me = state.me
  const text = `Chat with me on Cuven — I'm @${me?.username}`
  const url = location.origin
  try {
    if (navigator.share) await navigator.share({ title: 'Cuven', text, url })
    else { await navigator.clipboard.writeText(`${text} ${url}`); toast('Invite copied', { type: 'ok' }) }
  } catch {}
}

function openAllPeople({ origin, people, row }) {
  const body = h('div', { class: 'people-sheet' }, h('ul', { class: 'people-list' }, people.map(u => h('li', {}, row(u)))))
  const sheet = openSheet({ title: 'People you may know', content: body, tall: true, origin, side: 'list' })
  sheet.el.classList.add('people-all-sheet')
  return sheet
}

/** A person: their photo, name and a line under it; then a button, and × to set them aside. */
function personRow(u, { sub, onTap, action, dismiss }) {
  const face = avatar(u.avatar, nameOf(u), { size: 52 })
  const text = h('span', { class: 'person-text' }, h('b', { class: 'person-name' }, nameOf(u)), sub ? h('span', { class: 'person-sub' }, sub) : null)
  const main = onTap
    ? h('button', { class: 'person-main', type: 'button', 'aria-label': `${nameOf(u)}${sub ? `, ${sub}` : ''}` }, face, text)
    : h('span', { class: 'person-main' }, face, text)
  onTap && main.addEventListener('click', onTap)
  return h('div', { class: 'person-row', dataset: { user: u.id } }, main,
    action ? actionButton(action) : null,
    dismiss ? dismissButton(dismiss) : null)
}
function actionButton({ label, solid = false, disabled = false, run }) {
  const b = h('button', { class: ['person-action', solid && 'solid'], type: 'button', disabled }, label)
  if (run) b.addEventListener('click', async () => { b.disabled = true; try { await run(b) } finally { if (b.isConnected) b.disabled = false } })
  return b
}
function dismissButton({ label, run }) {
  const b = h('button', { class: 'person-dismiss', type: 'button', 'aria-label': label }, icon('xmark'))
  b.addEventListener('click', run)
  return b
}
