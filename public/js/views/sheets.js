// Settings and new chat / new group on the shared floating sheet from
// overlay.js, and a conversation's details, rendered into the details column.

import { h, icon, storage } from '../ui/dom.js'
import { symbolEffect } from '../ui/symbols.js'
import { getPrefs, setTheme, setGlass, setGlassTint, setGlassEngine, setMotion, setHaptics, setGlow } from '../ui/appearance.js'
import { liquidGlassSupported } from '../ui/liquid-glass/index.js'
import { isStandalone } from '../ui/viewport.js'
import { pushSupported, currentSubscription, enablePush, disablePush } from '../ui/push.js'
import { hapticsAvailable } from '../ui/haptics.js'
import { assistPrefs, setAssistPref } from './predict.js'
import { insightsOn, setInsightsPref, insightsSection } from './insights.js'
import { openMemorySheet } from './memory.js'
import { openAvatarEditor } from './avatar-editor.js'
import { state, setMe, setPrefs, upsertRoom, patchRoom, setContacts } from '../store.js'
import { api } from '../api.js'
import { avatar } from './avatar.js'
import { openSheet, openMenu, confirmAction, toast } from './overlay.js'
import { backdropLayer, backdropLabel, paintBackdrop, readBackdrop } from '../ui/backdrops.js'
import { openBackdropPicker, saveBackdrops } from './backdrops.js'
import { ghost, filler } from '../ui/skeleton.js'

// ---------------------------------------------------------------- shared bits
export function cell(label, right, { icon: ic, sub, onClick, tint, destructive } = {}) {
  const tag = onClick ? 'button' : 'div'
  const el = h(tag, {
    class: ['cell', ic && 'icon-left', tint && 'tint', destructive && 'destructive'],
    type: onClick ? 'button' : undefined
  },
  ic ? h('span', { class: 'cell-icon' }, icon(ic)) : null,
  h('span', { class: 'grow' }, label, sub ? h('span', { class: 'sub' }, sub) : null),
  right ?? null)
  if (onClick) el.addEventListener('click', onClick)
  return el
}

// Settings › Messages: open conversations redraw their times at once (views/thread.js).
function setChatTime(key, value) {
  storage(key, value)
  dispatchEvent(new Event('chat-times'))
}
async function setReceipts(on) {
  const before = state.prefs
  setPrefs({ ...before, receipts: on })
  try {
    setPrefs((await api.post('/api/prefs', { receipts: on })).prefs)
    return true
  } catch (err) {
    setPrefs(before)
    toast(err.message || "Couldn't change read receipts", { type: 'error' })
    return false
  }
}

function toggle(checked, onChange, label) {
  const sw = h('button', { class: 'switch', type: 'button', role: 'switch', 'aria-checked': String(Boolean(checked)), 'aria-label': label })
  sw.addEventListener('click', async () => {
    const next = sw.getAttribute('aria-checked') !== 'true'
    sw.setAttribute('aria-checked', String(next))
    const ok = await onChange(next)
    if (ok === false) sw.setAttribute('aria-checked', String(!next))
  })
  return sw
}
function segmented(options, value, onChange, label) {
  const i0 = Math.max(0, options.findIndex(o => o.value === value))
  const seg = h('div', { class: 'seg', role: 'radiogroup', 'aria-label': label, style: { '--n': String(options.length), '--i': String(i0) } })
  seg.append(h('span', { class: 'thumb', 'aria-hidden': 'true' }))
  options.forEach((o, i) => {
    const b = h('button', { type: 'button', role: 'radio', 'aria-checked': String(i === i0) }, o.label)
    b.addEventListener('click', () => {
      seg.style.setProperty('--i', String(i))
      for (const x of seg.querySelectorAll('button')) x.setAttribute('aria-checked', String(x === b))
      onChange(o.value)
    })
    seg.append(b)
  })
  return seg
}
export const group = (...cells) => h('div', { class: 'group' }, ...cells.filter(Boolean))
// The one that can't be undone, set a little apart from the rest.
const danger = (...cells) => h('div', { class: 'group group-danger' }, ...cells.filter(Boolean))
export const groupTitle = t => h('div', { class: 'group-title' }, t)
export const foot = t => h('p', { class: 'group-foot' }, t)
const input = (props) => h('input', { class: 'input', autocomplete: 'off', autocapitalize: 'off', autocorrect: 'off', spellcheck: false, ...props })

/** A profile card's cover, if they chose one, across its top. */
function withCover(card, cover) {
  if (readBackdrop(cover)) {
    card.classList.add('has-cover')
    card.prepend(backdropLayer(cover, 'profile-cover'))
  }
  return card
}

/**
 * A row for a backdrop: what it is now (a swatch and its name) and, tapped,
 * the picker. get() reads it; opts go to the picker, whose save() is
 * followed by the row.
 */
function backdropCell(label, ic, get, { none = 'Default', ...opts }) {
  const swatch = h('span', { class: 'bd-swatch', 'aria-hidden': 'true' }, backdropLayer(get() || opts.fallback || ''))
  const name = h('span', {}, backdropLabel(get(), none))
  const update = () => {
    paintBackdrop(swatch.firstChild, get() || opts.fallback || '')
    name.textContent = backdropLabel(get(), none)
  }
  const el = cell(label, h('span', { class: 'bd-value' }, swatch, name, chev()), {
    icon: ic,
    onClick: () => openBackdropPicker({
      title: label, none, ...opts, value: get(),
      save: async v => { await opts.save(v); update() }
    })
  })
  return el
}

export function rememberOpen(id) {
  try { id ? localStorage.setItem('ui:open', id) : localStorage.removeItem('ui:open') } catch {}
}

// ---------------------------------------------------------------- settings
export function openSettings({ onLogout, origin }) {
  const prefs = getPrefs()
  const me = state.me
  // The card is the one way into editing who you are; no second row for it.
  const card = me => withCover(h('button', { class: 'profile profile-btn', type: 'button', 'aria-label': `${me?.display || 'Me'}, edit profile` },
    avatar(me?.avatar, me?.display || 'Me', { size: 84 }),
    h('h3', {}, me?.display || 'Me'),
    h('p', {}, '@' + (me?.username || ''))), me?.cover)
  let profile = card(me)
  // What's edited there shows here as soon as it's saved.
  const onEdited = next => {
    const fresh = card(next)
    fresh.addEventListener('click', () => editProfile(onEdited))
    profile.replaceWith(fresh)
    profile = fresh
  }
  profile.addEventListener('click', () => editProfile(onEdited))

  const pushSlot = h('div')
  renderPush(pushSlot)

  const content = h('div', {},
    profile,
    groupTitle('Account'),
    group(
      cell('Change password', chev(), { icon: 'lock', onClick: () => changePassword() })
    ),
    groupTitle('Display & interaction'),
    group(
      cell('Appearance', segmented([
        { label: 'Light', value: 'light' },
        { label: 'Dark', value: 'dark' },
        { label: 'Auto', value: 'system' }
      ], prefs.theme, setTheme, 'Appearance')),
      // Liquid Glass: "Clear" is more see-through; "Tinted" raises opacity to
      // lift the contrast of content and controls.
      cell('Liquid Glass', segmented([
        { label: 'Clear', value: 'clear' },
        { label: 'Tinted', value: 'tinted' }
      ], prefs.glassTint, setGlassTint, 'Liquid Glass')),
      // A diffuse light behind the message field, in one of a few colours.
      cell('Composer glow', segmented([
        { label: 'Off', value: 'off' },
        { label: 'Ocean', value: 'ocean' },
        { label: 'Dawn', value: 'dawn' },
        { label: 'Aurora', value: 'aurora' }
      ], prefs.glow, setGlow, 'Composer glow')),
      // Real-time refraction (the liquid-glass shader) on the conversation's
      // buttons, where the GPU can run it. Off falls back to the CSS glass.
      liquidGlassSupported()
        ? cell('Real-time glass', toggle(prefs.glassEngine !== 'css', on => setGlassEngine(on ? 'webgl' : 'css'), 'Real-time glass'))
        : null,
      cell('Reduce transparency', toggle(prefs.glass === 'solid', on => setGlass(on ? 'solid' : 'auto'), 'Reduce transparency')),
      cell('Reduce motion', toggle(document.documentElement.dataset.motion === 'reduce', on => setMotion(on ? 'reduce' : 'system'), 'Reduce motion')),
      // Only offered where the device can play it (iPhone), so it never
      // claims to be on when nothing would happen.
      hapticsAvailable ? cell('Haptic feedback', toggle(prefs.haptics, on => setHaptics(on), 'Haptic feedback')) : null
    ),
    // Time in conversations (ui/chat-time.js): the clock, and whether every
    // message shows its own time; and whether friends see when you've read
    // theirs (kept on the server, so a receipt turned off is never sent).
    groupTitle('Messages'),
    group(
      cell('Time format', segmented([
        { label: 'System', value: 'system' },
        { label: '12-hour', value: '12' },
        { label: '24-hour', value: '24' }
      ], storage('ui:time-format') || 'system', v => setChatTime('ui:time-format', v === 'system' ? null : v), 'Time format')),
      cell('Message times', segmented([
        { label: 'Smart', value: 'smart' },
        { label: 'Always', value: 'always' }
      ], storage('ui:msg-times') === 'always' ? 'always' : 'smart', v => setChatTime('ui:msg-times', v === 'smart' ? null : v), 'Message times')),
      cell('Read receipts', toggle(state.prefs.receipts !== false, on => setReceipts(on), 'Read receipts'))
    ),
    foot('Swipe left in a chat to see each message’s time. With read receipts off, friends won’t see when you’ve read.'),
    // The welcome and the tips (ui/guides.js), shown again from the start.
    groupTitle('Help'),
    group(cell('Show tips again', null, { icon: 'sparkles', onClick: async () => {
      (await import('../ui/guides.js')).resetGuides()
      toast('Tips will show again')
    } })),
    // The call screen's backdrop, the same on each of your devices.
    // Conversations keep the app's own paper: no chat background to choose.
    groupTitle('Backgrounds'),
    group(
      backdropCell('Call background', 'phone', () => state.prefs.call, { look: 'call', save: v => saveBackdrops({ call: v }) })
    ),
    // Writing help, only where the server has Workers AI.
    state.assist ? groupTitle('Smart') : null,
    state.assist ? group(
      cell('Typing suggestions', toggle(assistPrefs().predict, on => setAssistPref('predict', on), 'Typing suggestions')),
      cell('Highlight keywords', toggle(assistPrefs().keys, on => setAssistPref('keys', on), 'Highlight keywords')),
      cell('Insights', toggle(insightsOn(), on => setInsightsPref(on), 'Insights')),
      // Dictation in the composer (Whisper). Shown with the other AI features
      // and only usable where the mic and a secure connection are available.
      cell('Voice to text', toggle(storage('ui:voice') !== 'off', on => { storage('ui:voice', on ? null : 'off'); return true }, 'Voice to text'))
    ) : null,
    state.assist ? foot('Timely things from your chats — a plan, a ride — show at the top, just for you.') : null,
    state.assist ? group(
      cell('Memory', chev(), { icon: 'sparkles', onClick: () => openMemorySheet(origin) })
    ) : null,
    state.assist ? foot('Suggestions learn only from your own use. View or clear them anytime.') : null,
    groupTitle('Notifications'),
    pushSlot,
    h('div', { style: { height: '20px' } }),
    group(cell('Log out', null, { destructive: true, onClick: () => onLogout() }))
  )
  openSheet({ title: 'Settings', content, tall: true, origin })
}

/** Edit profile, from elsewhere (the Moments page's Edit profile). */
export function openEditProfile(onEdited) {
  return editProfile(onEdited)
}

function editProfile(onEdited) {
  const me = state.me
  // The cover across the top (anyone who opens your profile sees it), your
  // photo over its lower edge.
  const cover = h('button', { class: 'cover-edit', type: 'button', 'aria-label': 'Change cover' },
    backdropLayer(me?.cover), h('span', { class: 'cover-edit-label', 'aria-hidden': 'true' }, icon('photo'), 'Change cover'))
  const av = h('button', { class: 'avatar-edit', type: 'button', 'aria-label': 'Change avatar' },
    avatar(me?.avatar, me?.display || 'Me', { size: 96 }), h('span', { class: 'avatar-edit-badge' }, icon('camera')))
  // Both open the editor (views/avatar-editor.js), on their own tab; what it
  // saves shows here at once.
  const saved = next => {
    av.firstChild.replaceWith(avatar(next.avatar, next.display, { size: 96 }))
    paintBackdrop(cover.firstChild, next.cover)
    onEdited?.(next)
  }
  av.addEventListener('click', () => openAvatarEditor({ tab: 'avatar', origin: av, onSaved: saved }))
  cover.addEventListener('click', () => openAvatarEditor({ tab: 'cover', origin: cover, onSaved: saved }))
  const display = input({ value: me?.display || '', placeholder: 'Display name', maxlength: 40 })
  const bio = input({ value: me?.bio || '', placeholder: 'Bio (optional)', maxlength: 120 })
  const save = h('button', { class: 'btn primary solid-press', type: 'button' }, 'Save')

  save.addEventListener('click', async () => {
    save.disabled = true
    try {
      const r = await api.post('/api/profile', { display: display.value.trim() || me.username, bio: bio.value.trim() })
      setMe(r.me)
      onEdited?.(r.me)
      toast('Saved', { type: 'ok' })
      sheet.close()
    } catch (err) { toast(err.message, { type: 'error' }); save.disabled = false }
  })

  const content = h('div', { class: 'form-sheet' },
    cover,
    h('div', { class: 'avatar-edit-wrap over-cover' }, av),
    h('label', { class: 'f-label' }, 'Display name'), display,
    h('label', { class: 'f-label' }, 'Bio'), bio,
    h('div', { class: 'f-go' }, save))
  const sheet = openSheet({ title: 'Edit profile', content })
}

function changePassword() {
  const cur = input({ type: 'password', placeholder: 'Current password', autocomplete: 'current-password' })
  const next = input({ type: 'password', placeholder: 'New password (6+ characters)', autocomplete: 'new-password' })
  const err = h('div', { class: 'field-error' })
  const save = h('button', { class: 'btn primary solid-press', type: 'button' }, 'Update password')
  save.addEventListener('click', async () => {
    err.textContent = ''
    save.disabled = true
    try {
      await api.post('/api/password', { current: cur.value, next: next.value })
      toast('Password updated', { type: 'ok' })
      sheet.close()
    } catch (e) { err.textContent = e.message; save.disabled = false }
  })
  const content = h('div', { class: 'form-sheet' },
    h('label', { class: 'f-label' }, 'Current password'), cur,
    h('label', { class: 'f-label' }, 'New password'), next, err,
    h('div', { class: 'f-go' }, save))
  const sheet = openSheet({ title: 'Change password', content })
}

// ---------------------------------------------------------------- notifications
async function renderPush(slot) {
  // Without push on the server there's nothing to switch on: no row at all.
  if (!state.vapid) return slot.replaceChildren()
  const supported = pushSupported()
  const sub = supported ? await currentSubscription() : null
  // A note only when the switch can't be used, saying how to make it usable.
  let note = null
  if (!supported) note = isStandalone() ? 'This device does not support notifications.' : 'Add Cuven to your Home Screen to enable notifications.'
  else if (Notification.permission === 'denied') note = 'Allow Cuven to send notifications in Settings › Notifications.'
  const sw = toggle(Boolean(sub), on => (on ? turnOn() : turnOff()), 'Notifications')
  sw.disabled = Boolean(note)
  slot.replaceChildren(group(cell('Notifications', sw, { icon: 'bell' })), ...(note ? [foot(note)] : []))
}
async function turnOn() {
  try {
    await enablePush(state.vapid)
    toast('Notifications on', { type: 'ok' })
    return true
  } catch (err) { toast(`Couldn't enable notifications: ${err.message}`, { type: 'error' }); return false }
}
async function turnOff() {
  try {
    await disablePush()
    return true
  } catch (err) { toast(err.message, { type: 'error' }); return false }
}

// ---------------------------------------------------------------- people, as a row (Friends: views/people.js)
export function contactCell(u, onClick, relState) {
  const sub = relState === 'pending_out' ? 'Request sent' : relState === 'pending_in' ? 'Wants to add you' : '@' + u.username
  const el = cell(u.display, chev(), { onClick, sub })
  el.prepend(avatar(u.avatar, u.display, { size: 40 }))
  return el
}

// ---------------------------------------------------------------- new group
export function openNewGroup({ loadContacts, onOpen }) {
  const name = input({ placeholder: 'Group name (optional)', maxlength: 40 })
  const picked = new Set()
  const list = h('div', {})
  const create = h('button', { class: 'btn primary solid-press', type: 'button', disabled: true }, 'Create group')

  const content = h('div', { class: 'form-sheet' },
    h('label', { class: 'f-label' }, 'Name'), name,
    h('label', { class: 'f-label' }, 'Choose members'), list,
    h('div', { class: 'f-go' }, create))
  const sheet = openSheet({ title: 'New group', content, tall: true })

  loadContacts().then(cs => {
    list.replaceChildren(cs.length ? group(...cs.map(c => pickRow(c))) : foot('No contacts'))
  })
  function pickRow(c) {
    const check = h('span', { class: 'pick-check' }, icon('check'))
    const el = cell(c.display, check, { sub: '@' + c.username, onClick: () => {
      if (picked.has(c.id)) picked.delete(c.id); else picked.add(c.id)
      el.classList.toggle('picked', picked.has(c.id))
      if (picked.has(c.id)) symbolEffect(check.querySelector('.icon'), 'draw-on')
      create.disabled = picked.size === 0
    } })
    el.prepend(avatar(c.avatar, c.display, { size: 40 }))
    return el
  }
  create.addEventListener('click', async () => {
    create.disabled = true
    try {
      const r = await api.post('/api/group', { name: name.value.trim(), members: [...picked] })
      upsertRoom(r.room)
      sheet.close()
      onOpen(r.room.id)
    } catch (err) { toast(err.message, { type: 'error' }); create.disabled = false }
  })
}

// ---------------------------------------------------------------- room info
export const roomInfoTitle = roomId => (state.chats.get(roomId)?.kind === 'group' ? 'Group info' : 'Contact')

/**
 * A conversation's details, rendered into `body`. host: { el, close } — the
 * surface showing them (the details column), closed when the conversation is
 * left or removed.
 */
export async function renderRoomInfo(roomId, { body, host, loadContacts }) {
  const c = state.chats.get(roomId)
  if (!c) return
  const isGroup = c.kind === 'group'

  // While the room loads, its details' skeleton, made from the same profile
  // card and cells (ui/skeleton.js).
  // (only when it is slow to come: a quick one simply appears).
  const slow = body.childElementCount ? 0 : setTimeout(() => body.isConnected && !body.childElementCount && body.replaceChildren(...ghost([
      h('div', { class: 'profile' }, avatar(null, '', { size: 84 }), h('h3', {}, filler(2, 1)), h('p', {}, filler(1, 4))),
      group(cell(filler(1, 2), chev(), { icon: 'photo' })),
      group(cell(filler(1, 5), null, { icon: 'bell-slash' }), cell(filler(2, 7), null, { icon: 'pin' })),
      danger(cell(filler(2, 3), null, { destructive: true }))
    ])), 250)
  let room = c, members = []
  try {
    const r = await api.get(`/api/room/${roomId}`)
    room = r.room || c
    members = r.members || []
  } catch {}
  clearTimeout(slow)

  const header = isGroup
    ? h('div', { class: 'profile' }, avatar(room.avatar, room.name, { size: 84, room: true }), h('h3', {}, room.name), h('p', {}, `${members.length} members`))
    : withCover(h('div', { class: 'profile' }, avatar(c.peer?.avatar, c.peer?.display, { size: 84 }), h('h3', {}, c.peer?.display || c.name), h('p', {}, '@' + (c.peer?.username || ''))), (room.peer || c.peer)?.cover)

  const flags = group(
    cell('Mute', toggle(c.muted, on => setFlag(roomId, { muted: on ? 1 : 0 }), 'Mute'), { icon: 'bell-slash' }),
    cell('Pin chat', toggle(c.pinned, on => setFlag(roomId, { pinned: on ? 1 : 0 }), 'Pin'), { icon: 'pin' })
  )

  // Their moments: what they share with friends (views/moments.js).
  const momentsCell = !isGroup && c.peer?.id ? group(cell('Moments', chev(), {
    icon: 'photo',
    onClick: async () => (await import('./moments.js')).openMoments({ userId: c.peer.id })
  })) : null
  const blocks = [header, momentsCell, flags].filter(Boolean)
  // What this conversation says about them (views/insights.js).
  if (!isGroup && insightsOn()) blocks.splice(1, 0, insightsSection(roomId))

  if (isGroup) {
    const grid = h('div', { class: 'members' })
    for (const m of members) {
      grid.append(h('div', { class: 'member' }, avatar(m.avatar, m.display, { size: 48 }), h('span', {}, m.display)))
    }
    const addBtn = h('button', { class: 'member add', type: 'button', 'aria-label': 'Add member' }, h('span', { class: 'member-add' }, icon('plus')), h('span', {}, 'Add'))
    addBtn.addEventListener('click', () => addMembers(roomId, members.map(m => m.id), loadContacts))
    grid.append(addBtn)
    blocks.push(groupTitle('Members'), grid)
    blocks.push(danger(cell('Leave group', null, { destructive: true, onClick: () => leaveRoom(roomId, host) })))
  } else {
    blocks.push(danger(cell('Delete chat', null, { destructive: true, onClick: () => { setFlag(roomId, { hidden: 1 }); host.close() } })))
  }
  body.replaceChildren(...blocks)

  async function setFlag(id, f) {
    patchRoom(id, Object.fromEntries(Object.entries(f).map(([k, v]) => [k, Boolean(v)])))
    try { await api.post(`/api/room/${id}/flags`, f) } catch (err) { toast(err.message, { type: 'error' }) }
    return true
  }
}

async function addMembers(roomId, existing, loadContacts) {
  const picked = new Set()
  const list = h('div', {})
  const add = h('button', { class: 'btn primary solid-press', type: 'button', disabled: true }, 'Add')
  const content = h('div', { class: 'form-sheet' }, h('label', { class: 'f-label' }, 'Choose a contact'), list, h('div', { class: 'f-go' }, add))
  const sheet = openSheet({ title: 'Add member', content, tall: true })
  const cs = (await loadContacts()).filter(c => !existing.includes(c.id))
  list.replaceChildren(cs.length ? group(...cs.map(c => {
    const check = h('span', { class: 'pick-check' }, icon('check'))
    const el = cell(c.display, check, { sub: '@' + c.username, onClick: () => {
      picked.has(c.id) ? picked.delete(c.id) : picked.add(c.id)
      el.classList.toggle('picked', picked.has(c.id)); add.disabled = !picked.size
      if (picked.has(c.id)) symbolEffect(check.querySelector('.icon'), 'draw-on')
    } })
    el.prepend(avatar(c.avatar, c.display, { size: 40 }))
    return el
  })) : foot('No contacts to add'))
  add.addEventListener('click', async () => {
    add.disabled = true
    try { await api.post(`/api/room/${roomId}/invite`, { members: [...picked] }); sheet.close() }
    catch (err) { toast(err.message, { type: 'error' }); add.disabled = false }
  })
}

async function leaveRoom(roomId, host) {
  if (!await confirmAction(host.el, { title: 'Leave this group?', message: 'You won’t get its messages any more unless someone adds you again.', confirm: 'Leave group' })) return
  try { await api.post(`/api/room/${roomId}/leave`); patchRoom(roomId, { hidden: true }); host.close() }
  catch (err) { toast(err.message, { type: 'error' }) }
}

export function chev() { return h('span', { class: 'chev' }, icon('chevron-right')) }
