// Choosing a backdrop (ui/backdrops.js): for every conversation, one
// conversation, calls, or your profile's cover. A sheet of the app's own and
// a photo of yours; a choice shows at once and is kept on the server (the
// sheet stays open to try another).

import { h, icon } from '../ui/dom.js'
import { PRESETS, readBackdrop, backdropLayer, paintBackdrop } from '../ui/backdrops.js'
import { state, setPrefs } from '../store.js'
import { api } from '../api.js'
import { openSheet, toast } from './overlay.js'
import { prepareImage } from './composer.js'

/**
 * value: the current choice; none: what '' is called here; kind: what a
 * photo is uploaded as ('bg' or 'cover'); look: what the tiles show over
 * each backdrop ('chat' bubbles, a 'call' picture, or a bare 'cover');
 * save(value) keeps it (and throws if it can't).
 */
export function openBackdropPicker({ title, value = '', none = '默认', fallback = '', kind = 'bg', look = 'chat', save, origin, side }) {
  let current = value || ''
  let busy = false
  const tiles = []

  // The first tile is the default: none, or (for one conversation) the one for all.
  function tile(v, label, ...extra) {
    const b = h('button', { class: ['bd-tile', `bd-${look}`], type: 'button', role: 'radio', 'aria-label': label },
      backdropLayer(v || fallback), sample(), ...extra, h('span', { class: 'bd-name' }, label))
    b._value = v
    tiles.push(b)
    return b
  }
  const grid = h('div', { class: 'bd-grid', role: 'radiogroup', 'aria-label': title })
  grid.append(tile('', none))
  for (const p of PRESETS) grid.append(tile(`preset:${p.id}`, p.label))
  // Your own photo: the last tile, showing it once there is one.
  const file = h('input', { type: 'file', accept: 'image/*', hidden: true })
  const photo = tile(readBackdrop(current)?.photo ? current : '', '照片', h('span', { class: 'bd-add', 'aria-hidden': 'true' }, icon('photo')))
  if (!readBackdrop(current)?.photo) paintBackdrop(photo.querySelector('.backdrop'), '')
  photo.classList.add('bd-photo')
  grid.append(photo, file)

  for (const b of tiles) {
    b.addEventListener('click', () => {
      if (b === photo) file.click()
      else choose(b._value)
    })
  }
  file.addEventListener('change', async () => {
    const f = file.files[0]
    file.value = ''
    if (!f || busy) return
    busy = true
    photo.classList.add('loading')
    try {
      const { file: small } = await prepareImage(f)
      const res = await fetch(`/api/media/upload?kind=${kind}&name=${kind}`, {
        method: 'POST', credentials: 'same-origin', headers: { 'content-type': small.type || 'image/jpeg' }, body: small
      })
      const data = await res.json().catch(() => ({}))
      if (!res.ok || !data.ok) throw new Error(data.error || '上传失败')
      photo._value = data.url
      paintBackdrop(photo.querySelector('.backdrop'), data.url)
      busy = false
      await choose(data.url)
    } catch (err) {
      toast(err.message || '上传失败', { type: 'error' })
    } finally {
      busy = false
      photo.classList.remove('loading')
    }
  })

  function mark() {
    const isPhoto = Boolean(readBackdrop(current)?.photo)
    for (const b of tiles) b.setAttribute('aria-checked', String(b === photo ? isPhoto : b._value === current))
  }
  async function choose(v) {
    if (busy || v === current) return
    const before = current
    current = v
    mark()
    try {
      await save(v)
    } catch (err) {
      current = before
      mark()
      toast(err.message || '设置失败', { type: 'error' })
    }
  }
  mark()

  // A hint of what will sit on it: two bubbles, a caller, or nothing.
  function sample() {
    if (look === 'chat') return h('span', { class: 'bd-sample', 'aria-hidden': 'true' }, h('i', { class: 'in' }), h('i', { class: 'out' }))
    if (look === 'call') return h('span', { class: 'bd-sample', 'aria-hidden': 'true' }, h('i', { class: 'face' }))
    return null
  }

  return openSheet({ title, content: h('div', { class: 'bd-picker' }, grid), origin, side })
}

/** Change backdrops ({ chat }, { call } or { rooms: { id: value } }): at once here, then on the server. */
export async function saveBackdrops(patch) {
  const before = state.prefs
  const next = { ...before, rooms: { ...before.rooms } }
  if (patch.chat !== undefined) next.chat = patch.chat
  if (patch.call !== undefined) next.call = patch.call
  for (const [id, v] of Object.entries(patch.rooms || {})) {
    if (v) next.rooms[id] = v
    else delete next.rooms[id]
  }
  setPrefs(next)
  try {
    const r = await api.post('/api/prefs', patch)
    setPrefs(r.prefs)
  } catch (err) {
    setPrefs(before)
    throw err
  }
}

/** The backdrop a conversation shows: its own, or the one for all. */
export const chatBackdrop = id => state.prefs.rooms[id] || state.prefs.chat
