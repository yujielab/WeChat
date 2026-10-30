// Settings and new chat / new group on the shared floating sheet from
// overlay.js, and a conversation's details, rendered into the details column.

import { h, icon } from '../ui/dom.js'
import { symbolEffect } from '../ui/symbols.js'
import { getPrefs, setTheme, setGlass, setMotion, setHaptics } from '../ui/appearance.js'
import { isStandalone } from '../ui/viewport.js'
import { pushSupported, currentSubscription, enablePush, disablePush } from '../ui/push.js'
import { hapticsAvailable } from '../ui/haptics.js'
import { assistPrefs, setAssistPref } from './predict.js'
import { insightsOn, setInsightsPref, insightsSection } from './insights.js'
import { state, setMe, upsertRoom, patchRoom, setContacts } from '../store.js'
import { api } from '../api.js'
import { avatar } from './avatar.js'
import { openSheet, openMenu, confirmAction, toast } from './overlay.js'
import { backdropLayer, backdropLabel, paintBackdrop, readBackdrop } from '../ui/backdrops.js'
import { openBackdropPicker, saveBackdrops } from './backdrops.js'

// ---------------------------------------------------------------- shared bits
function cell(label, right, { icon: ic, sub, onClick, tint, destructive } = {}) {
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
  const buttons = options.map((o, i) => {
    const b = h('button', { type: 'button', role: 'radio', 'aria-checked': String(i === i0), tabindex: i === i0 ? '0' : '-1' }, o.label)
    b.addEventListener('click', () => select(i))
    seg.append(b)
    return b
  })
  function select(i, focus = false) {
    seg.style.setProperty('--i', String(i))
    buttons.forEach((b, n) => {
      b.setAttribute('aria-checked', String(n === i))
      b.tabIndex = n === i ? 0 : -1
    })
    if (focus) buttons[i].focus({ preventScroll: true })
    onChange(options[i].value)
  }
  seg.addEventListener('keydown', e => {
    const current = buttons.indexOf(document.activeElement)
    if (current < 0 || !['ArrowLeft', 'ArrowRight', 'ArrowUp', 'ArrowDown', 'Home', 'End'].includes(e.key)) return
    e.preventDefault()
    const next = e.key === 'Home' ? 0 : e.key === 'End' ? buttons.length - 1
      : (current + (e.key === 'ArrowLeft' || e.key === 'ArrowUp' ? -1 : 1) + buttons.length) % buttons.length
    select(next, true)
  })
  return seg
}
const group = (...cells) => h('div', { class: 'group' }, ...cells.filter(Boolean))
const groupTitle = t => h('div', { class: 'group-title' }, t)
const foot = t => h('p', { class: 'group-foot' }, t)
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
function backdropCell(label, ic, get, { none = '默认', ...opts }) {
  const swatch = h('span', { class: 'bd-swatch', 'aria-hidden': 'true' }, backdropLayer(get() || opts.fallback || ''))
  const name = h('span', { class: 'bd-name' }, backdropLabel(get(), none))
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

async function uploadAvatar(file) {
  const res = await fetch(`/api/media/upload?kind=avatar&name=avatar`, {
    method: 'POST', credentials: 'same-origin', headers: { 'content-type': file.type || 'image/jpeg' }, body: file
  })
  const data = await res.json().catch(() => ({}))
  if (!res.ok || !data.ok) throw new Error(data.error || '上传失败')
  return data.url
}

// ---------------------------------------------------------------- settings
export function openSettings({ onLogout, origin }) {
  const prefs = getPrefs()
  const me = state.me
  // The card is the one way into editing who you are; no second row for it.
  const card = me => withCover(h('button', { class: 'profile profile-btn', type: 'button', 'aria-label': `${me?.display || '我'}，编辑资料` },
    avatar(me?.avatar, me?.display || '我', { size: 84 }),
    h('h3', {}, me?.display || '我'),
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
    groupTitle('账号'),
    group(
      cell('修改密码', chev(), { icon: 'lock', onClick: () => changePassword() })
    ),
    groupTitle('显示与交互'),
    group(
      cell('外观', segmented([
        { label: '浅色', value: 'light' },
        { label: '深色', value: 'dark' },
        { label: '自动', value: 'system' }
      ], prefs.theme, setTheme, '外观')),
      cell('降低透明度', toggle(prefs.glass === 'solid', on => setGlass(on ? 'solid' : 'auto'), '降低透明度')),
      cell('减少动态效果', toggle(document.documentElement.dataset.motion === 'reduce', on => setMotion(on ? 'reduce' : 'system'), '减少动态效果')),
      // Only offered where the device can play it (iPhone), so it never
      // claims to be on when nothing would happen.
      hapticsAvailable ? cell('触感反馈', toggle(prefs.haptics, on => setHaptics(on), '触感反馈')) : null
    ),
    // Backdrops, the same on each of your devices (each conversation can
    // also have its own, in its details).
    groupTitle('背景'),
    group(
      backdropCell('聊天背景', 'bubble', () => state.prefs.chat, { look: 'chat', save: v => saveBackdrops({ chat: v }) }),
      backdropCell('通话背景', 'phone', () => state.prefs.call, { look: 'call', save: v => saveBackdrops({ call: v }) })
    ),
    // Writing help, only where the server has Workers AI.
    state.assist ? groupTitle('智能') : null,
    state.assist ? group(
      cell('输入预测', toggle(assistPrefs().predict, on => setAssistPref('predict', on), '输入预测')),
      cell('加亮关键词', toggle(assistPrefs().keys, on => setAssistPref('keys', on), '加亮关键词')),
      cell('智能通知', toggle(insightsOn(), on => setInsightsPref(on), '智能通知'))
    ) : null,
    state.assist ? foot('智能通知从最近的私聊里整理提醒，只给你自己看。') : null,
    groupTitle('通知'),
    pushSlot,
    h('div', { style: { height: '20px' } }),
    group(cell('退出登录', null, { destructive: true, onClick: () => onLogout() }))
  )
  openSheet({ title: '设置', content, tall: true, origin })
}

function editProfile(onEdited) {
  const me = state.me
  // The cover across the top (anyone who opens your profile sees it), your
  // photo over its lower edge.
  const cover = h('button', { class: 'cover-edit', type: 'button', 'aria-label': '更换封面' },
    backdropLayer(me?.cover), h('span', { class: 'cover-edit-label', 'aria-hidden': 'true' }, icon('photo'), '更换封面'))
  cover.addEventListener('click', () => openBackdropPicker({
    title: '封面', value: state.me?.cover || '', none: '无', kind: 'cover', look: 'cover',
    save: async v => {
      const r = await api.post('/api/profile', { cover: v })
      setMe(r.me)
      paintBackdrop(cover.firstChild, r.me.cover)
      onEdited?.(r.me)
    }
  }))
  const av = h('button', { class: 'avatar-edit', type: 'button', 'aria-label': '更换头像' },
    avatar(me?.avatar, me?.display || '我', { size: 96 }), h('span', { class: 'avatar-edit-badge' }, icon('camera')))
  const file = h('input', { type: 'file', accept: 'image/*', hidden: true })
  const display = input({ id: 'profile-display', value: me?.display || '', placeholder: '昵称', maxlength: 40 })
  const bio = input({ id: 'profile-bio', value: me?.bio || '', placeholder: '简介（可选）', maxlength: 120 })
  const save = h('button', { class: 'btn primary solid-press', type: 'button' }, '保存')

  av.addEventListener('click', () => file.click())
  file.addEventListener('change', async () => {
    const f = file.files[0]
    if (!f) return
    try {
      const url = await uploadAvatar(f)
      const r = await api.post('/api/profile', { avatar: url })
      setMe(r.me)
      av.firstChild.replaceWith(avatar(r.me.avatar, r.me.display, { size: 96 }))
      onEdited?.(r.me)
      toast('头像已更新', { type: 'ok' })
    } catch (err) { toast(err.message, { type: 'error' }) }
  })
  save.addEventListener('click', async () => {
    save.disabled = true
    try {
      const r = await api.post('/api/profile', { display: display.value.trim() || me.username, bio: bio.value.trim() })
      setMe(r.me)
      onEdited?.(r.me)
      toast('已保存', { type: 'ok' })
      sheet.close()
    } catch (err) { toast(err.message, { type: 'error' }); save.disabled = false }
  })

  const content = h('div', { class: 'form-sheet' },
    cover,
    h('div', { class: 'avatar-edit-wrap over-cover' }, av, file),
    h('label', { class: 'f-label', for: display.id }, '昵称'), display,
    h('label', { class: 'f-label', for: bio.id }, '简介'), bio,
    h('div', { class: 'f-go' }, save))
  const sheet = openSheet({ title: '编辑资料', content })
}

function changePassword() {
  const cur = input({ id: 'password-current', type: 'password', placeholder: '当前密码', autocomplete: 'current-password' })
  const next = input({ id: 'password-new', type: 'password', placeholder: '新密码（至少 6 位）', autocomplete: 'new-password' })
  const err = h('div', { class: 'field-error', role: 'alert', id: 'password-error' })
  cur.setAttribute('aria-describedby', err.id)
  next.setAttribute('aria-describedby', err.id)
  const save = h('button', { class: 'btn primary solid-press', type: 'button' }, '更新密码')
  save.addEventListener('click', async () => {
    err.textContent = ''
    save.disabled = true
    try {
      await api.post('/api/password', { current: cur.value, next: next.value })
      toast('密码已更新', { type: 'ok' })
      sheet.close()
    } catch (e) { err.textContent = e.message; save.disabled = false }
  })
  const content = h('div', { class: 'form-sheet' },
    h('label', { class: 'f-label', for: cur.id }, '当前密码'), cur,
    h('label', { class: 'f-label', for: next.id }, '新密码'), next, err,
    h('div', { class: 'f-go' }, save))
  const sheet = openSheet({ title: '修改密码', content })
}

// ---------------------------------------------------------------- notifications
async function renderPush(slot) {
  // Without push on the server there's nothing to switch on: no row at all.
  if (!state.vapid) return slot.replaceChildren()
  const supported = pushSupported()
  const sub = supported ? await currentSubscription() : null
  // A note only when the switch can't be used, saying how to make it usable.
  let note = null
  if (!supported) note = isStandalone() ? '此设备不支持通知。' : '将 Cuven 添加到主屏幕后即可开启通知。'
  else if (Notification.permission === 'denied') note = '请在“设置 › 通知”中允许 Cuven 发送通知。'
  const sw = toggle(Boolean(sub), on => (on ? turnOn() : turnOff()), '通知')
  sw.disabled = Boolean(note)
  slot.replaceChildren(group(cell('通知', sw, { icon: 'bell' })), ...(note ? [foot(note)] : []))
}
async function turnOn() {
  try {
    await enablePush(state.vapid)
    toast('通知已开启', { type: 'ok' })
    return true
  } catch (err) { toast(`无法开启通知：${err.message}`, { type: 'error' }); return false }
}
async function turnOff() {
  try {
    await disablePush()
    return true
  } catch (err) { toast(err.message, { type: 'error' }); return false }
}

// ---------------------------------------------------------------- new chat
export function openNewChat({ loadContacts, onOpen }) {
  const search = input({ type: 'search', 'aria-label': '按用户名查找', placeholder: '按用户名查找', enterkeyhint: 'search' })
  const results = h('div', {})
  const list = h('div', {})

  const content = h('div', {},
    h('div', { class: 'sheet-search' }, h('label', { class: 'glass search-pill' }, icon('search'), search)),
    group(cell('新建群聊', chev(), { icon: 'people', onClick: () => { sheet.close(); openNewGroup({ loadContacts, onOpen }) } })),
    groupTitle('联系人'),
    list,
    results
  )
  const sheet = openSheet({ title: '新聊天', content, tall: true, side: 'list' })

  loadContacts().then(cs => {
    list.replaceChildren(cs.length ? group(...cs.map(c => contactCell(c, () => openDM(c.id)))) : foot('没有联系人'))
  })

  let seq = 0
  search.addEventListener('input', async () => {
    const q = search.value.trim()
    list.hidden = Boolean(q)
    if (!q) { results.replaceChildren(); return }
    const s = ++seq
    try {
      const r = await api.get(`/api/users/search?q=${encodeURIComponent(q)}`)
      if (s !== seq) return
      results.replaceChildren(r.users.length
        ? group(...r.users.map(u => contactCell(u, () => openDM(u.id), u.state)))
        : foot(`没有找到“${q}”`))
    } catch {}
  })

  async function openDM(userId) {
    try {
      const r = await api.post('/api/dm', { user: userId })
      upsertRoom(r.room)
      sheet.close()
      onOpen(r.room.id)
    } catch (err) { toast(err.message, { type: 'error' }) }
  }
}

function contactCell(u, onClick, relState) {
  const sub = relState === 'pending_out' ? '已发送请求' : relState === 'pending_in' ? '请求加你为好友' : '@' + u.username
  const el = cell(u.display, chev(), { onClick, sub })
  el.prepend(avatar(u.avatar, u.display, { size: 40 }))
  return el
}

// ---------------------------------------------------------------- new group
export function openNewGroup({ loadContacts, onOpen }) {
  const name = input({ id: 'group-name', placeholder: '群聊名称（可选）', maxlength: 40 })
  const picked = new Set()
  const list = h('div', {})
  const create = h('button', { class: 'btn primary solid-press', type: 'button', disabled: true }, '创建群聊')

  const content = h('div', { class: 'form-sheet' },
    h('label', { class: 'f-label', for: name.id }, '名称'), name,
    h('div', { class: 'f-label' }, '选择成员'), list,
    h('div', { class: 'f-go' }, create))
  const sheet = openSheet({ title: '新建群聊', content, tall: true })

  loadContacts().then(cs => {
    list.replaceChildren(cs.length ? group(...cs.map(c => pickRow(c))) : foot('没有联系人'))
  })
  function pickRow(c) {
    const check = h('span', { class: 'pick-check' }, icon('check'))
    const el = cell(c.display, check, { sub: '@' + c.username, onClick: () => {
      if (picked.has(c.id)) picked.delete(c.id); else picked.add(c.id)
      el.classList.toggle('picked', picked.has(c.id))
      el.setAttribute('aria-pressed', String(picked.has(c.id)))
      if (picked.has(c.id)) symbolEffect(check.querySelector('.icon'), 'draw-on')
      create.disabled = picked.size === 0
    } })
    el.setAttribute('aria-pressed', 'false')
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
export const roomInfoTitle = roomId => (state.chats.get(roomId)?.kind === 'group' ? '群聊信息' : '联系人')

/**
 * A conversation's details, rendered into `body`. host: { el, close } — the
 * surface showing them (the details column), closed when the conversation is
 * left or removed.
 */
export async function renderRoomInfo(roomId, { body, host, loadContacts }) {
  const c = state.chats.get(roomId)
  if (!c) return
  const isGroup = c.kind === 'group'

  let room = c, members = []
  try {
    const r = await api.get(`/api/room/${roomId}`)
    room = r.room || c
    members = r.members || []
  } catch {}

  const header = isGroup
    ? h('div', { class: 'profile' }, avatar(room.avatar, room.name, { size: 84, room: true }), h('h3', {}, room.name), h('p', {}, `${members.length} 位成员`))
    : withCover(h('div', { class: 'profile' }, avatar(c.peer?.avatar, c.peer?.display, { size: 84 }), h('h3', {}, c.peer?.display || c.name), h('p', {}, '@' + (c.peer?.username || ''))), (room.peer || c.peer)?.cover)

  const flags = group(
    cell('消息免打扰', toggle(c.muted, on => setFlag(roomId, { muted: on ? 1 : 0 }), '免打扰'), { icon: 'bell-slash' }),
    cell('置顶聊天', toggle(c.pinned, on => setFlag(roomId, { pinned: on ? 1 : 0 }), '置顶'), { icon: 'pin' }),
    // This conversation's own backdrop, or the one for all of them.
    backdropCell('聊天背景', 'photo', () => state.prefs.rooms[roomId] || '', {
      none: '跟随通用', fallback: state.prefs.chat, look: 'chat',
      save: v => saveBackdrops({ rooms: { [roomId]: v } })
    })
  )

  const blocks = [header, flags]
  // What this conversation says about them (views/insights.js).
  if (!isGroup && insightsOn()) blocks.splice(1, 0, insightsSection(roomId))

  if (isGroup) {
    const grid = h('div', { class: 'members' })
    for (const m of members) {
      grid.append(h('div', { class: 'member' }, avatar(m.avatar, m.display, { size: 48 }), h('span', {}, m.display)))
    }
    const addBtn = h('button', { class: 'member add', type: 'button', 'aria-label': '添加成员' }, h('span', { class: 'member-add' }, icon('plus')), h('span', {}, '添加'))
    addBtn.addEventListener('click', () => addMembers(roomId, members.map(m => m.id), loadContacts))
    grid.append(addBtn)
    blocks.push(groupTitle('成员'), grid)
    blocks.push(h('div', { style: { height: '14px' } }), group(cell('退出群聊', null, { destructive: true, onClick: () => leaveRoom(roomId, host) })))
  } else {
    blocks.push(h('div', { style: { height: '14px' } }), group(cell('删除会话', null, { destructive: true, onClick: () => { setFlag(roomId, { hidden: 1 }); host.close() } })))
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
  const add = h('button', { class: 'btn primary solid-press', type: 'button', disabled: true }, '添加')
  const content = h('div', { class: 'form-sheet' }, h('div', { class: 'f-label' }, '选择联系人'), list, h('div', { class: 'f-go' }, add))
  const sheet = openSheet({ title: '添加成员', content, tall: true })
  const cs = (await loadContacts()).filter(c => !existing.includes(c.id))
  list.replaceChildren(cs.length ? group(...cs.map(c => {
    const check = h('span', { class: 'pick-check' }, icon('check'))
    const el = cell(c.display, check, { sub: '@' + c.username, onClick: () => {
      picked.has(c.id) ? picked.delete(c.id) : picked.add(c.id)
      el.classList.toggle('picked', picked.has(c.id))
      el.setAttribute('aria-pressed', String(picked.has(c.id)))
      add.disabled = !picked.size
      if (picked.has(c.id)) symbolEffect(check.querySelector('.icon'), 'draw-on')
    } })
    el.setAttribute('aria-pressed', 'false')
    el.prepend(avatar(c.avatar, c.display, { size: 40 }))
    return el
  })) : foot('没有可添加的联系人'))
  add.addEventListener('click', async () => {
    add.disabled = true
    try { await api.post(`/api/room/${roomId}/invite`, { members: [...picked] }); sheet.close() }
    catch (err) { toast(err.message, { type: 'error' }); add.disabled = false }
  })
}

async function leaveRoom(roomId, host) {
  if (!await confirmAction(host.el, { title: '退出这个群聊？', confirm: '退出群聊' })) return
  try { await api.post(`/api/room/${roomId}/leave`); patchRoom(roomId, { hidden: true }); host.close() }
  catch (err) { toast(err.message, { type: 'error' }) }
}

function chev() { return h('span', { class: 'chev' }, icon('chevron-right')) }
