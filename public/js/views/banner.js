// A message for a conversation that isn't on screen drops in from the top
// (as the system's own banners do): who, and what they said. A tap opens
// the conversation; a pull down opens a field to answer from where you are;
// a flick up puts it away. Left alone it goes after 1.5 s. Another message
// while it's up takes its place, unless an answer is being written there.
// main.js decides when one is due (not for the conversation being read).

import { h, icon, reducedMotion } from '../ui/dom.js'
import { avatar } from './avatar.js'
import { placeOnSide } from '../ui/fold.js'
import { velocityTracker, rubberband } from '../ui/spring.js'
import { haptic } from '../ui/haptics.js'

const STAY = 1500 // ms, untouched
const SLOP = 6 // px before a press becomes a drag
const PULL = 44 // px down that opens the field
const AWAY = 28 // px up that puts it away
const FLICK = 450 // px/s, either way

let deps = null
let cur = null

/** openChat(id) and send(chat, text): what a tap and an answer do. */
export function initBanner(d) {
  deps = d
}

/** { chat, name, avatar, room, text }: who wrote, and what. */
export function showBanner(note) {
  if (!deps) return
  if (cur && !cur.leaving) {
    // An answer under way isn't swept aside: only its own conversation's
    // newest words come in, above the field.
    if (cur.open) {
      if (cur.chat === note.chat) cur.fill(note)
      return
    }
    cur.fill(note)
    cur.arm()
    return
  }
  cur = create(note)
}

/** Put it away, if one is up (the conversation it's about was opened). */
export function dismissBanner(chat) {
  if (cur && (!chat || cur.chat === chat)) cur.dismiss()
}

function create(note) {
  const who = h('span', { class: 'banner-name' })
  const when = h('span', { class: 'banner-time' }, 'now')
  const body = h('span', { class: 'banner-body' })
  const face = h('span', { class: 'banner-avatar' })
  const main = h('button', { class: 'banner-main', type: 'button' },
    face, h('span', { class: 'banner-text' }, h('span', { class: 'banner-head' }, who, when), body))
  const field = h('input', { class: 'banner-input', type: 'text', enterkeyhint: 'send', autocomplete: 'off', placeholder: 'Reply', 'aria-label': 'Reply' })
  const send = h('button', { class: 'banner-send', type: 'submit', 'aria-label': 'Send', disabled: true }, icon('arrow-up'))
  const form = h('form', { class: 'banner-reply', hidden: true }, field, send)
  const grab = h('span', { class: 'banner-grab', 'aria-hidden': 'true' })
  const card = h('div', { class: 'banner-card' }, main, form, grab)
  const el = h('div', { class: ['banner', 'off'], role: 'status' }, card)

  let timer = 0
  const b = {
    chat: note.chat,
    open: false,
    leaving: false,
    fill(n) {
      b.chat = n.chat
      who.textContent = n.name || ''
      body.textContent = n.text || ''
      face.replaceChildren(avatar(n.avatar, n.name, { room: n.room, size: 40 }))
      main.setAttribute('aria-label', `${n.name}: ${n.text}. Open chat`)
      // A new message in place: a small nudge says it changed.
      if (el.isConnected && !reducedMotion()) card.animate([{ transform: 'scale(.97)' }, { transform: 'none' }], { duration: 260, easing: 'cubic-bezier(.22,1,.36,1)' })
    },
    arm() {
      clearTimeout(timer)
      if (!b.open && !b.leaving) timer = setTimeout(() => b.dismiss(), STAY)
    },
    hold() {
      clearTimeout(timer)
    },
    expand() {
      if (b.open || b.leaving) return
      b.open = true
      b.hold()
      el.classList.add('open')
      form.hidden = false
      field.placeholder = `Reply to ${who.textContent}`
      haptic()
    },
    async dismiss(velocity = 0) {
      if (b.leaving) return
      b.leaving = true
      b.hold()
      document.removeEventListener('pointerdown', outside, true)
      if (document.activeElement && el.contains(document.activeElement)) document.activeElement.blur()
      el.classList.remove('dragging')
      // A flick carries on at its own speed; otherwise the usual exit.
      if (velocity < -200) el.style.transitionDuration = `${Math.max(140, Math.min(320, 260000 / -velocity))}ms`
      el.classList.add('off', 'leaving')
      await new Promise(resolve => {
        el.addEventListener('transitionend', e => { if (e.target === el) resolve() })
        setTimeout(resolve, 400)
      })
      el.remove()
      if (cur === b) cur = null
    }
  }
  b.fill(note)

  // ---- the hand on it: a tap opens, down opens the field, up puts it away.
  let g = null
  const vt = velocityTracker()
  const setY = y => el.style.setProperty('--y', `${y}px`)
  card.addEventListener('pointerdown', e => {
    if (b.leaving || e.button > 0 || form.contains(e.target)) return
    g = { id: e.pointerId, y0: e.clientY, x0: e.clientX, drag: false, pulled: false }
    vt.reset()
    vt.add(e.clientX, e.clientY)
    b.hold()
  })
  card.addEventListener('pointermove', e => {
    if (!g || e.pointerId !== g.id) return
    vt.add(e.clientX, e.clientY)
    const dy = e.clientY - g.y0
    if (!g.drag) {
      if (Math.hypot(dy, e.clientX - g.x0) < SLOP) return
      g.drag = true
      card.setPointerCapture?.(e.pointerId)
      el.classList.add('dragging')
    }
    // Up follows the finger; down gives, and past PULL the field opens.
    if (dy < 0) setY(dy)
    else {
      setY(rubberband(dy, 160))
      if (dy > PULL && !b.open) { g.pulled = true; b.expand() }
    }
  })
  const release = e => {
    if (!g || e.pointerId !== g.id) return
    const { drag, y0 } = g
    let { pulled } = g
    g = null
    el.classList.remove('dragging')
    if (e.type === 'pointercancel') { setY(0); b.arm(); return }
    if (!drag) {
      // A tap: the conversation, with what was being looked at closed.
      if (!b.open || main.contains(e.target)) {
        const chat = b.chat
        b.dismiss()
        deps.openChat(chat)
      }
      return
    }
    const dy = e.clientY - y0
    const vy = vt.velocity().y
    if (dy < -AWAY || vy < -FLICK) return b.dismiss(vy)
    if (!b.open && (dy > PULL || vy > FLICK)) { pulled = true; b.expand() }
    setY(0)
    // Opened with this pull: the field takes the keys (here, in the
    // gesture's own event, so a phone brings its keyboard up).
    if (pulled) field.focus({ preventScroll: true })
    b.arm()
  }
  card.addEventListener('pointerup', release)
  card.addEventListener('pointercancel', release)
  // From the keyboard (Enter, Space): the conversation, as a tap.
  main.addEventListener('click', e => {
    if (e.detail !== 0 || b.leaving) return
    const chat = b.chat
    b.dismiss()
    deps.openChat(chat)
  })

  // A pointer resting on it (a mouse) is a look: it stays until it moves off.
  el.addEventListener('pointerenter', e => { if (e.pointerType === 'mouse') b.hold() })
  el.addEventListener('pointerleave', e => { if (e.pointerType === 'mouse' && !g) b.arm() })
  // Keys stay with it: Escape puts it away (not a sheet under it), Tab
  // stays in it, the down arrow opens the field.
  el.addEventListener('keydown', e => {
    e.stopPropagation()
    if (e.key === 'Escape') { e.preventDefault(); b.dismiss() }
    else if (e.key === 'ArrowDown' && e.target === main && !b.open) { e.preventDefault(); b.expand(); field.focus() }
  })
  el.addEventListener('focusin', () => b.hold())

  // Writing an answer: tapping elsewhere puts it away, unless words are waiting.
  function outside(e) {
    if (!el.contains(e.target) && !field.value.trim()) b.dismiss()
  }
  field.addEventListener('focus', () => document.addEventListener('pointerdown', outside, true), { once: true })
  field.addEventListener('input', () => { send.disabled = !field.value.trim() })
  form.addEventListener('submit', e => {
    e.preventDefault()
    const text = field.value.trim()
    if (!text || b.leaving) return
    deps.send(b.chat, text)
    // Gone: a check where the arrow was, then away.
    el.classList.add('sent')
    send.replaceChildren(icon('check'))
    field.disabled = true
    send.disabled = true
    setTimeout(() => b.dismiss(), reducedMotion() ? 300 : 650)
  })

  document.getElementById('overlays').append(el)
  placeOnSide(el)
  requestAnimationFrame(() => requestAnimationFrame(() => el.classList.remove('off')))
  b.arm()
  return b
}
