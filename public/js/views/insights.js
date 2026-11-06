// Smart notifications: cards made from what your recent one-to-one
// conversations say about the other person (src/insights.js) — a ride
// they're in, getting home or heading out, a plan you made, things they said
// will happen, how they seem, something going on for them, where their
// photos look to be taken, what was said lately, what they like — and the
// weather where they are. Each conversation makes only the cards it has
// something for. Read only for you, only when you look; it can be switched
// off in Settings.
//
// The newest few cards stand at the top and the rest stack under them; the
// stack opens into the whole list ("Now") and closes again.

import { h, icon, storage, reducedMotion } from '../ui/dom.js'
import { api } from '../api.js'
import { state } from '../store.js'
import { avatar } from './avatar.js'
import { openSheet } from './overlay.js'

const MIN = 60 * 1000
const HOUR = 60 * MIN
const DAY = 24 * HOUR
const SHOWN = 3 // cards above the stack

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
const when = (ts, now) => `${dayWord(ts, now)} ${hm(ts)}`
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
  if (i.mood && i.mood.label !== 'calm') add('mood', 60, { mood: i.mood })
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
const MOODS = { happy: 'in a good mood', excited: 'seems excited', tired: 'seems a bit tired', down: 'seems a bit down', anxious: 'seems a little anxious', angry: 'seems a little annoyed', sad: 'seems a bit sad' }
const HOME = { home: 'got home', out: 'headed out', 'on the way': 'on the way' }
const HOME_CHIP = { home: 'Home', out: 'Out', 'on the way': 'On the way' }
const RIDE = { waiting: 'Ride', riding: 'On the trip', arrived: 'Arrived' }

/** One card: an action word in a chip, then a sentence with the person in it. */
export function panelCard(p, { now = Date.now(), onOpen } = {}) {
  const name = p.peer?.display || 'them'
  const who = () => h('span', { class: 'ins-who' }, avatar(p.peer?.avatar, name, { size: 24 }), h('b', {}, name))
  const strong = t => h('b', {}, t)
  let chip = ''
  let line = []
  let sub = null
  let art = null
  switch (p.kind) {
    case 'ride': {
      const r = p.ride
      chip = RIDE[r.stage]
      if (r.stage === 'waiting') {
        line = [who(), "'s ride", r.plate ? [' ', strong(r.plate)] : '', r.car ? ` · ${r.car}` : '', r.pickup ? ` · pickup ~${hm(r.pickup)}` : '']
        sub = r.pickup ? relative(r.pickup, now) : null
      } else if (r.stage === 'riding') {
        line = [who(), ' on the trip', r.to ? [' · to ', strong(r.to)] : '', r.dropoff ? ` · ~${hm(r.dropoff)} arrival` : '']
        sub = r.plate ? `Plate ${r.plate}${r.car ? ` · ${r.car}` : ''}` : null
      } else {
        line = [who(), r.dropoff ? ` ${hm(r.dropoff)}` : '', ' arrived', r.to ? [' · ', strong(r.to)] : '']
      }
      art = icon('car', 'ins-glyph')
      break
    }
    case 'meetup':
      chip = 'Meetup'
      line = ['Meet ', who(), ' at ', strong(p.meetup.place), ` · ${when(p.meetup.at, now)}`]
      sub = relative(p.meetup.at, now)
      art = icon('mappin', 'ins-glyph')
      break
    case 'home':
      chip = HOME_CHIP[p.home.state] || p.home.state
      line = [who(), ` ${HOME[p.home.state]} ${hm(p.home.at)}`]
      sub = `${dayWord(p.home.at, now)} · ${relative(p.home.at, now)}`
      art = icon('house', 'ins-glyph')
      break
    case 'upcoming':
      chip = 'Reminder'
      line = [strong(p.upcoming.what), ` · ${when(p.upcoming.at, now)}`]
      sub = `From ${name} · ${relative(p.upcoming.at, now)}`
      art = icon('clock', 'ins-glyph')
      break
    case 'mood':
      chip = 'Checking in'
      line = [who(), ` ${MOODS[p.mood.label] || p.mood.label}`]
      sub = p.mood.note || null
      art = icon('heart', 'ins-glyph')
      break
    case 'ongoing': {
      const e = p.ongoing
      const day = e.since ? Math.floor((dayStart(now) - dayStart(e.since)) / DAY) + 1 : 0
      chip = 'Heads up'
      line = [who(), ' ', strong(e.what), day > 0 ? ` · day ${day}` : '', e.until ? ` · until ${dayWord(e.until, now)}` : '']
      sub = e.note || null
      art = icon('calendar', 'ins-glyph')
      break
    }
    case 'photo':
      chip = 'Take a look'
      line = [who(), "'s photo looks like it's in ", strong(p.photo.place || 'somewhere')]
      sub = p.photo.reading || null
      art = h('img', { class: 'ins-thumb', src: p.photo.url, alt: '', loading: 'lazy', decoding: 'async' })
      break
    case 'summary':
      chip = 'Recap'
      line = [who(), `: ${p.summary}`]
      art = icon('bubble', 'ins-glyph')
      break
    case 'likes':
      chip = 'Good to know'
      line = [who(), p.likes.length ? [' likes ', strong(p.likes.join(', '))] : '', p.dislikes.length ? [p.likes.length ? '; ' : ' ', 'dislikes ', strong(p.dislikes.join(', '))] : '']
      sub = p.hobbies.length ? `Hobbies: ${p.hobbies.join(', ')}` : null
      art = icon('sparkles', 'ins-glyph')
      break
  }
  const tag = onOpen ? 'button' : 'div'
  const el = h(tag, { class: ['ins-card', `ins-${p.kind}`], type: onOpen ? 'button' : undefined, dataset: { kind: p.kind, room: p.room } },
    h('span', { class: 'ins-text' },
      h('span', { class: 'ins-line' }, h('span', { class: 'ins-chip' }, chip), ' ', ...line.flat()),
      sub ? h('span', { class: 'ins-sub' }, ...[sub].flat()) : null),
    art ? h('span', { class: 'ins-art', 'aria-hidden': 'true' }, art) : null)
  if (onOpen) el.addEventListener('click', () => onOpen(p.room))
  return el
}

/** The weather where they are (or here): what it's like, and the next sunrise or sunset. */
export function weatherCard(w) {
  const where = w.who ? `${w.place} · ${w.who}'s area` : (w.place || 'Here')
  return h('section', { class: 'ins-weather', 'aria-label': `Weather in ${where}` },
    h('div', { class: 'ins-weather-head' }, icon(w.symbol || 'sun'), h('span', {}, where)),
    h('div', { class: 'ins-tiles' },
      h('div', { class: 'ins-tile' }, h('span', { class: 'ins-tile-label' }, w.text || 'Weather'), h('span', { class: 'ins-tile-value' }, `${w.temp}°${w.unit === 'f' ? 'F' : 'C'}`)),
      w.next ? h('div', { class: 'ins-tile' }, h('span', { class: 'ins-tile-label' }, w.next.kind === 'sunset' ? 'Sunset' : 'Sunrise'), h('span', { class: 'ins-tile-value' }, w.next.time)) : null))
}

function skeleton(n = 3) {
  return Array.from({ length: n }, (_, i) => h('div', { class: 'ins-card ins-skeleton', 'aria-hidden': 'true' },
    h('span', { class: 'ins-text' }, h('span', { class: 'sk sk-line', style: { width: `${[78, 64, 70][i % 3]}%` } }), h('span', { class: 'sk sk-line', style: { width: `${[46, 58, 40][i % 3]}%` } }))))
}

// Run fn over items, a few at a time.
async function inTurn(items, n, fn) {
  const queue = [...items]
  await Promise.all(Array.from({ length: Math.min(n, queue.length) }, async () => {
    while (queue.length) await fn(queue.shift())
  }))
}

// ------------------------------------------------------------ the center
export function openInsights({ origin, onOpen } = {}) {
  const status = h('p', { class: 'ins-status', role: 'status' })
  const list = h('div', { class: 'ins-list' })
  const weatherSlot = h('div', { class: 'ins-weather-slot' })
  const body = h('div', { class: 'ins' }, status, list, weatherSlot)
  let data = null
  let expanded = false
  const reading = new Set()
  const sheet = openSheet({ title: 'Insights', content: body, tall: true, origin, side: 'list' })
  const open = id => {
    sheet.close()
    onOpen?.(id)
  }

  function render({ fresh = false } = {}) {
    if (sheet.closed) return
    status.replaceChildren(...(reading.size ? [h('span', { class: 'spinner' }), `Reading your ${reading.size} most recent chats…`] : []))
    status.hidden = !reading.size
    if (!data) {
      list.replaceChildren(...skeleton())
      return
    }
    const now = Date.now()
    const cards = allPanels(data.rooms, now).map(p => panelCard(p, { now, onOpen: open }))
    if (!cards.length) {
      list.replaceChildren(...(reading.size ? skeleton(2) : [h('div', { class: 'ins-empty' }, icon('sparkles'), h('p', {}, data.failed ? "Can't connect right now, check back later" : 'Nothing to flag in recent chats yet'))]))
    } else {
      list.replaceChildren(...stack(cards, { fresh }))
    }
    weatherSlot.replaceChildren(...(data.weather ? [weatherCard(data.weather)] : []))
  }

  // The first few stand at the top and the rest stack under them; tapped,
  // the stack opens into the whole list, with Now and a way to close it.
  function stack(cards, { fresh }) {
    const out = []
    if (expanded) {
      const fold = h('button', { class: 'ins-fold glass-btn', type: 'button', 'aria-label': 'Collapse' }, icon('collapse'))
      fold.addEventListener('click', () => { expanded = false; render() })
      out.push(h('div', { class: 'ins-head' }, h('span', {}, 'Now'), fold))
      cards.forEach((c, i) => { if (fresh && !reducedMotion()) { c.style.setProperty('--i', String(Math.max(0, i - SHOWN))); if (i >= SHOWN) c.classList.add('ins-in') } })
      out.push(...cards)
      return out
    }
    out.push(...cards.slice(0, SHOWN))
    const rest = cards.length - SHOWN
    if (rest > 0) {
      const more = h('button', { class: 'ins-more', type: 'button', 'aria-label': `${rest} more, expand` },
        h('span', { class: 'ins-plate' }), rest > 1 ? h('span', { class: 'ins-plate second' }) : null)
      more.addEventListener('click', () => { expanded = true; render({ fresh: true }) })
      out.push(more)
    }
    return out
  }

  async function load() {
    render()
    try {
      data = await api.get(`/api/insights?unit=${unit()}`)
    } catch {
      data = { rooms: [], weather: null, failed: true }
    }
    render()
    // Conversations with something new since they were last read are read now.
    const stale = data.rooms.filter(r => r.stale)
    if (!stale.length) return
    for (const r of stale) reading.add(r.room)
    render()
    await inTurn(stale, 3, async r => {
      try {
        Object.assign(r, await api.post('/api/insights/refresh', { room: r.room, tz: tzOffset() }))
      } catch {}
      reading.delete(r.room)
      render()
    })
    // Now it may be known where they are.
    try {
      data.weather = (await api.get(`/api/insights?unit=${unit()}`)).weather || data.weather
    } catch {}
    render()
  }
  load()
  return sheet
}

/** One conversation's cards, for its details: read again if it has moved on. */
export function insightsSection(roomId) {
  const list = h('div', { class: 'ins-list ins-plain' }, ...skeleton(2))
  const section = h('section', { class: 'ins-section', 'aria-label': 'Insights' }, h('div', { class: 'group-title' }, 'Insights'), list)
  ;(async () => {
    let entry = null
    try {
      entry = (await api.get(`/api/insights?room=${encodeURIComponent(roomId)}`)).rooms?.[0] || null
      if (entry?.stale) Object.assign(entry, await api.post('/api/insights/refresh', { room: roomId, tz: tzOffset() }))
    } catch {}
    const now = Date.now()
    const cards = entry ? panelsOf(entry, now).sort((a, b) => b.priority - a.priority).map(p => panelCard(p, { now })) : []
    if (cards.length) list.replaceChildren(...cards)
    else section.remove()
  })()
  return section
}
