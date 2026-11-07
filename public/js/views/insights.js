// Smart panels: cards made from what your recent one-to-one conversations
// say about the other person (src/insights.js) — a ride they're in, getting
// home or heading out, a plan you made, things they said will happen, how
// they seem, something going on for them, where their photos look to be
// taken, what was said lately, what they like — and the weather where they
// are. Read only for you; it can be switched off in Settings.
//
// No button opens them and no sheet holds them: they come to the top of the
// chat list by themselves when something is timely (a ride under way, a
// plan in the next hours, someone just home) and are gone when nothing is.
// After the reference: a title, chips for the kinds there are, and cards
// side by side — what and when along the top, dashed rules around the rows
// that say it, and one full-width action at the foot.

import { h, icon, storage, reducedMotion } from '../ui/dom.js'
import { api } from '../api.js'
import { state } from '../store.js'
import { avatar } from './avatar.js'
import { openViewer } from './viewer.js'

const MIN = 60 * 1000
const HOUR = 60 * MIN
const DAY = 24 * HOUR
// What makes the panel come: a card at least this pressing (allPanels' priorities).
const TIMELY = 50

export const insightsOn = () => Boolean(state.assist) && storage('ui:insights') !== 'off'
export function setInsightsPref(on) {
  storage('ui:insights', on ? null : 'off')
  window.dispatchEvent(new Event('insights-pref'))
}

const tzOffset = () => new Date().getTimezoneOffset()
const unit = () => (/-(US|LR|MM)\b/i.test(navigator.language || '') ? 'f' : 'c')

// ------------------------------------------------------------ times, in words
const pad = n => String(n).padStart(2, '0')
const hm = ts => { const d = new Date(ts); return `${pad(d.getHours())}:${pad(d.getMinutes())}` }
const dayStart = ts => { const d = new Date(ts); d.setHours(0, 0, 0, 0); return d.getTime() }
function dayWord(ts, now) {
  const days = Math.round((dayStart(ts) - dayStart(now)) / DAY)
  if (days === 0) return 'Today'
  if (days === 1) return 'Tomorrow'
  if (days === 2) return 'In 2 days'
  if (days === -1) return 'Yesterday'
  const d = new Date(ts)
  return d.toLocaleDateString('en-US', { month: 'short', day: 'numeric', weekday: 'short' })
}
function relative(ts, now) {
  const d = ts - now
  const a = Math.abs(d)
  const span = a < HOUR ? `${Math.max(1, Math.round(a / MIN))} min` : a < DAY ? `${Math.round(a / HOUR)} hr` : `${Math.round(a / DAY)} days`
  return d >= 0 ? `in ${span}` : `${span} ago`
}

// ------------------------------------------------------------ which cards, in what order
/**
 * The cards one conversation's reading makes, each with how pressing it is
 * (a ride or a plan about to happen first, what they like last). Anything
 * already past its moment is left out.
 */
export function panelsOf(entry, now = Date.now()) {
  const i = entry?.insight
  if (!i) return []
  const out = []
  const add = (kind, priority, data) => out.push({ kind, priority, room: entry.room, peer: entry.peer, ...data })
  if (i.ride && (i.ride.stage !== 'arrived' || (i.ride.dropoff && now - i.ride.dropoff < 30 * MIN))) add('ride', 100, { ride: i.ride })
  if (i.meetup && i.meetup.at > now - 30 * MIN) add('meetup', i.meetup.at - now < 3 * HOUR ? 95 : i.meetup.at - now < DAY ? 70 : 40, { meetup: i.meetup })
  if (i.home && now - i.home.at < 12 * HOUR) add('home', now - i.home.at < 2 * HOUR ? 85 : 50, { home: i.home })
  for (const u of i.upcoming || []) {
    if (u.at < now - 30 * MIN) continue
    // The plan already says it.
    if (i.meetup && Math.abs(u.at - i.meetup.at) < 10 * MIN) continue
    add('upcoming', u.at - now < 2 * HOUR ? 90 : u.at - now < DAY ? 65 : 35, { upcoming: u })
  }
  // A low mood is a moment to check in; a good one can wait for the details.
  if (i.mood && i.mood.label !== 'calm') add('mood', ['happy', 'excited'].includes(i.mood.label) ? 40 : 60, { mood: i.mood })
  for (const e of i.ongoing || []) if (e.until === null || e.until >= now) add('ongoing', 55, { ongoing: e })
  for (const p of (i.photos || []).slice(0, 2)) add('photo', now - p.at < DAY ? 45 : 25, { photo: p })
  if (i.summary) add('summary', 30, { summary: i.summary })
  if (i.likes?.length || i.dislikes?.length || i.hobbies?.length) add('likes', 10, { likes: i.likes || [], dislikes: i.dislikes || [], hobbies: i.hobbies || [] })
  return out
}

export function allPanels(rooms, now = Date.now()) {
  const order = new Map(rooms.map((r, i) => [r.room, i]))
  return rooms.flatMap(r => panelsOf(r, now)).sort((a, b) => b.priority - a.priority || order.get(a.room) - order.get(b.room))
}

// ------------------------------------------------------------ cards
const MOODS = { happy: 'In a good mood', excited: 'Excited', tired: 'A bit tired', down: 'A bit down', anxious: 'A little anxious', angry: 'A little annoyed', sad: 'A bit sad' }
const HOME = { home: 'Got home', out: 'Headed out', 'on the way': 'On the way' }
const RIDE = { waiting: 'Ride', riding: 'On the trip', arrived: 'Arrived' }
// The chips: which kinds of card go under each.
const GROUPS = [
  { id: 'plans', label: 'Plans', icon: 'calendar', kinds: ['ride', 'meetup', 'home', 'upcoming'] },
  { id: 'people', label: 'People', icon: 'people', kinds: ['mood', 'ongoing', 'summary', 'likes'] },
  { id: 'photos', label: 'Photos', icon: 'photo', kinds: ['photo'] },
  { id: 'weather', label: 'Weather', icon: 'sun', kinds: ['weather'] }
]
const groupOf = kind => GROUPS.find(g => g.kinds.includes(kind))?.id

/**
 * One card, after the reference: what it is and when along the top, dashed
 * rules around the rows that say it (each: a picture or symbol, a word or
 * two, a value at the end), one action across the foot.
 */
export function panelCard(p, { now = Date.now(), onOpen } = {}) {
  const name = p.peer?.display || 'them'
  const face = () => avatar(p.peer?.avatar, name, { size: 30 })
  const sym = n => h('span', { class: 'ip-sym' }, icon(n))
  const row = (lead, label, value = '') => h('div', { class: 'ip-row' }, lead, h('span', { class: 'ip-label' }, label), h('span', { class: 'ip-value tabular' }, value))
  const chat = { label: 'Open chat', icon: 'bubble', run: () => onOpen?.(p.room) }
  let what = '', when = '', rows = [], act = chat
  switch (p.kind) {
    case 'ride': {
      const r = p.ride
      what = RIDE[r.stage]
      when = r.stage === 'waiting' && r.pickup ? relative(r.pickup, now) : r.dropoff ? relative(r.dropoff, now) : ''
      rows = [row(face(), name, r.plate || ''), row(sym('car'), r.to ? `To ${r.to}` : r.car || 'Ride', r.stage === 'waiting' && r.pickup ? hm(r.pickup) : r.dropoff ? hm(r.dropoff) : '')]
      break
    }
    case 'meetup':
      what = 'Meetup'
      when = dayWord(p.meetup.at, now)
      rows = [row(face(), name, hm(p.meetup.at)), row(sym('mappin'), p.meetup.place, relative(p.meetup.at, now))]
      act = { label: 'Directions', icon: 'mappin', run: () => window.open(`https://maps.apple.com/?q=${encodeURIComponent(p.meetup.place)}`, '_blank', 'noopener') }
      break
    case 'home':
      what = HOME[p.home.state] || p.home.state
      when = dayWord(p.home.at, now)
      rows = [row(face(), name, hm(p.home.at)), row(sym('house'), HOME[p.home.state] || p.home.state, relative(p.home.at, now))]
      act = { label: 'Say hi', icon: 'bubble', run: chat.run }
      break
    case 'upcoming':
      what = 'Reminder'
      when = dayWord(p.upcoming.at, now)
      rows = [row(sym('clock'), p.upcoming.what, hm(p.upcoming.at)), row(face(), `From ${name}`, relative(p.upcoming.at, now))]
      break
    case 'mood':
      what = 'Checking in'
      when = 'Now'
      rows = [row(face(), name, ''), row(sym('heart'), MOODS[p.mood.label] || p.mood.label, '')]
      act = { label: 'Say hi', icon: 'bubble', run: chat.run }
      break
    case 'ongoing': {
      const e = p.ongoing
      const day = e.since ? Math.floor((dayStart(now) - dayStart(e.since)) / DAY) + 1 : 0
      what = 'Heads up'
      when = day > 0 ? `Day ${day}` : ''
      rows = [row(face(), name, ''), row(sym('calendar'), e.what, e.until ? `Until ${dayWord(e.until, now)}` : '')]
      break
    }
    case 'photo':
      what = 'Take a look'
      when = relative(p.photo.at, now)
      rows = [row(h('img', { class: 'ip-thumb', src: p.photo.url, alt: '', loading: 'lazy', decoding: 'async' }), p.photo.place || 'Somewhere', ''), row(face(), name, '')]
      act = { label: 'View photo', icon: 'photo', run: () => openViewer({ src: p.photo.url, fullSrc: p.photo.url, label: p.photo.place || 'Photo' }) }
      break
    case 'summary':
      what = 'Recap'
      rows = [row(face(), name, ''), row(sym('bubble'), p.summary, '')]
      break
    case 'likes':
      what = 'Good to know'
      rows = [row(face(), name, ''),
        p.likes.length ? row(sym('heart'), `Likes ${p.likes.join(', ')}`, '') : null,
        p.dislikes.length ? row(sym('xmark'), `Not ${p.dislikes.join(', ')}`, '') : null,
        !p.likes.length && p.hobbies.length ? row(sym('sparkles'), p.hobbies.join(', '), '') : null].filter(Boolean)
      break
  }
  const button = h('button', { class: 'ip-act', type: 'button' }, icon(act.icon), act.label)
  button.addEventListener('click', () => act.run())
  return h('article', { class: ['ip-card', `ip-${p.kind}`], dataset: { kind: p.kind, room: p.room }, 'aria-label': `${what}, ${name}` },
    h('header', { class: 'ip-head' }, h('span', { class: 'ip-state' }, what), h('span', { class: 'ip-when' }, when)),
    h('div', { class: 'ip-rows' }, ...rows),
    button)
}

/** The weather where they are (or here), as a card: what it's like, and the next sunrise or sunset. */
export function weatherCard(w) {
  const where = w.who ? `${w.who}'s area` : 'Here'
  const sym = n => h('span', { class: 'ip-sym' }, icon(n))
  const row = (lead, label, value) => h('div', { class: 'ip-row' }, lead, h('span', { class: 'ip-label' }, label), h('span', { class: 'ip-value tabular' }, value))
  return h('article', { class: 'ip-card ip-weather', dataset: { kind: 'weather' }, 'aria-label': `Weather in ${w.place || where}` },
    h('header', { class: 'ip-head' }, h('span', { class: 'ip-state' }, w.place || 'Weather'), h('span', { class: 'ip-when' }, where)),
    h('div', { class: 'ip-rows' },
      row(sym(w.symbol || 'sun'), w.text || 'Weather', `${w.temp}°${w.unit === 'f' ? 'F' : 'C'}`),
      w.next ? row(sym(w.next.kind === 'sunset' ? 'moon' : 'sun'), w.next.kind === 'sunset' ? 'Sunset' : 'Sunrise', w.next.time) : null))
}

// Run fn over items, a few at a time.
async function inTurn(items, n, fn) {
  const queue = [...items]
  await Promise.all(Array.from({ length: Math.min(n, queue.length) }, async () => {
    while (queue.length) await fn(queue.shift())
  }))
}

// ------------------------------------------------------------ on the chat list
const LOOK_AGAIN = 10 * MIN // what's there is asked again at most this often
const READ_AGAIN = 30 * MIN // conversations that moved on are read again at most this often

/**
 * The panel at the top of the chat list: there only while something is
 * timely. onOpen(roomId) opens a conversation. Returns { el, refresh }.
 */
export function createInsightsPanel({ onOpen }) {
  const title = h('h2', { class: 'ip-title' }, 'For you')
  const chips = h('div', { class: 'ip-chips', role: 'tablist', 'aria-label': 'Kinds' })
  const cards = h('div', { class: 'ip-cards', role: 'tabpanel' })
  const el = h('section', { class: 'ip', 'aria-label': 'For you', hidden: true }, title, chips, cards)
  let data = null
  let chosen = null
  let asked = 0
  let read = 0
  let busy = false

  let shown = null // the kind on screen: cards slide in only when it changes
  function paint() {
    const now = Date.now()
    const panels = data ? allPanels(data.rooms, now) : []
    const timely = panels.some(p => p.priority >= TIMELY)
    el.hidden = !insightsOn() || !timely
    if (el.hidden) { shown = null; return }
    const byGroup = new Map()
    for (const p of panels) {
      const g = groupOf(p.kind)
      if (!byGroup.has(g)) byGroup.set(g, [])
      byGroup.get(g).push(panelCard(p, { now, onOpen }))
    }
    if (data.weather) byGroup.set('weather', [weatherCard(data.weather)])
    const present = GROUPS.filter(g => byGroup.has(g.id))
    // The most pressing kind leads, unless one was chosen.
    if (!chosen || !byGroup.has(chosen)) chosen = groupOf(panels.find(p => p.priority >= TIMELY)?.kind) || present[0]?.id
    chips.replaceChildren(...present.map(g => {
      const b = h('button', { class: 'ip-chip', type: 'button', role: 'tab', 'aria-selected': String(g.id === chosen), dataset: { group: g.id } },
        icon(g.id === 'weather' ? data.weather?.symbol || 'sun' : g.icon), g.label)
      b.addEventListener('click', () => { chosen = g.id; paint(); cards.scrollTo({ left: 0, behavior: reducedMotion() ? 'auto' : 'smooth' }) })
      return b
    }))
    const left = cards.scrollLeft
    cards.replaceChildren(...(byGroup.get(chosen) || []))
    if (shown === chosen) cards.scrollLeft = left
    // Repainted each minute for the times: the cards stay still unless the kind changed.
    if (shown !== chosen) {
      cards.dataset.enter = ''
      clearTimeout(paint.t)
      paint.t = setTimeout(() => delete cards.dataset.enter, 500)
    }
    shown = chosen
  }

  /** Ask for what is known (cheap), and now and then read conversations that moved on (Workers AI). */
  async function refresh({ force = false } = {}) {
    if (!insightsOn()) return paint()
    const now = Date.now()
    // Called on every change to the chats: most calls have nothing to do.
    if (busy || (!force && now - asked < LOOK_AGAIN)) return
    busy = true
    asked = now
    try {
      data = await api.get(`/api/insights?unit=${unit()}`)
      paint()
      const stale = data.rooms.filter(r => r.stale).slice(0, 3)
      if (stale.length && now - read > READ_AGAIN) {
        read = now
        await inTurn(stale, 2, async r => {
          try { Object.assign(r, await api.post('/api/insights/refresh', { room: r.room, tz: tzOffset() })) } catch {}
        })
        try { data.weather = (await api.get(`/api/insights?unit=${unit()}`)).weather || data.weather } catch {}
        paint()
      }
    } catch {
      // Nothing to show: the panel simply stays away.
    } finally { busy = false }
  }

  window.addEventListener('insights-pref', () => refresh({ force: true }))
  document.addEventListener('visibilitychange', () => { if (!document.hidden) refresh() })
  setInterval(() => { if (!document.hidden) refresh() }, LOOK_AGAIN)
  // A minute's change in time can make a card timely or let one go.
  setInterval(() => { if (data && !document.hidden) paint() }, MIN)
  return { el, refresh }
}

/** One conversation's cards, for its details, side by side: read again if it has moved on. */
export function insightsSection(roomId) {
  const row = h('div', { class: 'ip-cards ip-inline' })
  const section = h('section', { class: 'ins-section', 'aria-label': 'Insights' }, h('div', { class: 'group-title' }, 'Insights'), row)
  ;(async () => {
    let entry = null
    try {
      entry = (await api.get(`/api/insights?room=${encodeURIComponent(roomId)}`)).rooms?.[0] || null
      if (entry?.stale) Object.assign(entry, await api.post('/api/insights/refresh', { room: roomId, tz: tzOffset() }))
    } catch {}
    const now = Date.now()
    const cards = entry ? panelsOf(entry, now).sort((a, b) => b.priority - a.priority).map(p => panelCard(p, { now, onOpen: () => {} })) : []
    // In the details the conversation is already open: no "Open chat" there.
    for (const c of cards) { const a = c.querySelector('.ip-act'); if (a?.textContent === 'Open chat') a.remove() }
    if (cards.length) row.replaceChildren(...cards)
    else section.remove()
  })()
  return section
}
