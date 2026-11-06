// The Moments editor: a page of its own for a new moment, after the
// reference. Cancel and a Post pill across the top; your photo and the words
// ("What's new?"); the photos and the video as large cards side by side, each
// with × to take it out, a pencil to edit it (turn, crop, a look) and +ALT
// to describe it for people who can't see it; Tag people. At the foot, who
// can see it and who can comment (one line, a menu), Undo and Redo, then the
// tools — photos, the camera, a time to share it — and a ring for how much
// is left to write. Leaving with something written asks first.

import { h, icon } from '../ui/dom.js'
import { api } from '../api.js'
import { state } from '../store.js'
import { avatar } from './avatar.js'
import { openSheet, openMenu, confirmAction, toast } from './overlay.js'
import { prepareImage } from './composer.js'

export const PHOTOS_MAX = 9
export const TEXT_MAX = 2000
const ALT_MAX = 1000
const TAGS_MAX = 10
const VIDEO_MAX_BYTES = 30 * 1024 * 1024
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec']
const DAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat']
const nameOf = u => u?.display || u?.username || ''
const clamp = (v, a, b) => Math.min(b, Math.max(a, v))
let pickSeq = 0
/** A promise's resolve that only counts the first time (Done answers at once; closing afterwards changes nothing). */
const once = resolve => { let done = false; return v => { if (!done) { done = true; resolve(v) } } }

/** A time to come, briefly: Today 21:00, Tomorrow 9:00, Sat, Nov 7, 9:00. */
export function whenText(ts, now = Date.now()) {
  const d = new Date(ts)
  const day = new Date(now)
  day.setHours(0, 0, 0, 0)
  const diff = Math.floor((new Date(d).setHours(0, 0, 0, 0) - day) / 86400000)
  const time = `${d.getHours()}:${String(d.getMinutes()).padStart(2, '0')}`
  if (diff === 0) return `Today ${time}`
  if (diff === 1) return `Tomorrow ${time}`
  return `${DAYS[d.getDay()]}, ${MONTHS[d.getMonth()]} ${d.getDate()}, ${time}`
}

/** Who can see it and who can comment, in a line. */
function whoText(audience, comments) {
  const see = audience === 'friends' ? 'Friends' : 'Everyone'
  if (comments === 'off') return `${see} can see · Comments off`
  const say = comments === 'friends' ? 'Friends' : 'Everyone'
  if (say === see) return `${see} can see and comment`
  return `${see} can see · ${say} can comment`
}

export function openMomentEditor({ origin, onPosted } = {}) {
  // ------------------------------------------------------------ what's being written, step by step
  // Every change is a step: Undo and Redo walk them (typing makes one step a pause).
  let s = { text: '', picks: [], tags: [], audience: 'everyone', comments: 'everyone', at: null }
  const past = []
  const future = []
  const urls = new Set() // object URLs, let go of when the editor closes
  let burst = 0
  function step(next) {
    clearTimeout(burst)
    burst = 0
    past.push(s)
    if (past.length > 200) past.shift()
    future.length = 0
    s = next
    paint()
  }
  function undo() {
    if (!past.length) return
    clearTimeout(burst)
    burst = 0
    future.push(s)
    s = past.pop()
    text.value = s.text
    grow()
    paint()
  }
  function redo() {
    if (!future.length) return
    past.push(s)
    s = future.pop()
    text.value = s.text
    grow()
    paint()
  }

  // ------------------------------------------------------------ the page
  const cancel = h('button', { class: 'me-cancel', type: 'button' }, 'Cancel')
  const post = h('button', { class: 'me-post', type: 'button', disabled: true }, 'Post')
  const progress = h('div', { class: 'me-progress', 'aria-hidden': 'true' }, h('i'))
  const head = h('header', { class: 'me-head' }, cancel, h('span', { class: 'me-status', role: 'status' }), post, progress)
  const text = h('textarea', { class: 'me-text', placeholder: "What's new?", maxlength: TEXT_MAX, rows: 3, 'aria-label': 'What you want to say' })
  const writing = h('div', { class: 'me-writing' }, h('span', { class: 'me-face' }, avatar(state.me?.avatar, nameOf(state.me), { size: 44 })), text)
  const strip = h('div', { class: 'me-strip', role: 'list', 'aria-label': 'Photos and video', hidden: true })
  const tagBtn = h('button', { class: 'me-row me-tags', type: 'button' }, icon('person'), h('span', { class: 'me-row-label' }, 'Tag people'))
  const whenBtn = h('button', { class: 'me-row me-when', type: 'button', hidden: true }, icon('calendar'), h('span', { class: 'me-row-label' }))
  const whenClear = h('button', { class: 'me-when-clear', type: 'button', 'aria-label': 'Share now instead', hidden: true }, icon('xmark'))
  const body = h('div', { class: 'me-body' }, writing, strip, h('div', { class: 'me-rows' }, tagBtn, h('div', { class: 'me-when-wrap' }, whenBtn, whenClear)))

  const whoBtn = h('button', { class: 'me-who', type: 'button', 'aria-haspopup': 'menu' }, h('span', { class: 'me-who-icon' }), h('span', { class: 'me-who-label' }))
  const undoBtn = h('button', { class: 'me-tool me-undo', type: 'button', 'aria-label': 'Undo' }, icon('undo'))
  const redoBtn = h('button', { class: 'me-tool me-redo', type: 'button', 'aria-label': 'Redo' }, icon('redo'))
  const library = h('input', { type: 'file', accept: 'image/*,video/*', multiple: true, hidden: true })
  const camera = h('input', { type: 'file', accept: 'image/*,video/*', capture: 'environment', hidden: true })
  const photosBtn = h('button', { class: 'me-tool', type: 'button', 'aria-label': 'Add photos or a video' }, icon('photo'))
  const cameraBtn = h('button', { class: 'me-tool', type: 'button', 'aria-label': 'Take a photo or video' }, icon('camera'))
  const scheduleBtn = h('button', { class: 'me-tool', type: 'button', 'aria-label': 'Schedule' }, icon('calendar'))
  const ringFill = document.createElementNS('http://www.w3.org/2000/svg', 'circle')
  const ring = h('span', { class: 'me-ring', role: 'img' })
  {
    const svg = document.createElementNS('http://www.w3.org/2000/svg', 'svg')
    svg.setAttribute('viewBox', '0 0 30 30')
    svg.setAttribute('aria-hidden', 'true')
    const track = document.createElementNS('http://www.w3.org/2000/svg', 'circle')
    for (const c of [track, ringFill]) { c.setAttribute('cx', '15'); c.setAttribute('cy', '15'); c.setAttribute('r', '12'); c.setAttribute('pathLength', '100') }
    track.setAttribute('class', 'me-ring-track')
    ringFill.setAttribute('class', 'me-ring-fill')
    svg.append(track, ringFill)
    ring.append(svg, h('span', { class: 'me-ring-n tabular' }))
  }
  const dock = h('footer', { class: 'me-dock' },
    h('div', { class: 'me-dock-top' }, whoBtn, h('span', { class: 'me-grow' }), undoBtn, redoBtn),
    h('div', { class: 'me-tools' }, photosBtn, cameraBtn, scheduleBtn, h('span', { class: 'me-grow' }), ring),
    library, camera)
  const content = h('div', { class: 'me-page' }, head, body, dock)

  const sheet = openSheet({
    label: 'New moment', content, tall: true, origin,
    // Leaving with something written asks first.
    guard: async () => !hasContent() || confirmAction(cancel, { title: 'Discard this moment?', message: 'What you wrote and the photos you picked won’t be kept.', confirm: 'Discard', destructive: true }),
    onClose: () => { for (const u of urls) URL.revokeObjectURL(u) }
  })
  sheet.el.classList.add('moments-editor')
  const hasContent = () => Boolean(s.text.trim() || s.picks.length || s.tags.length || s.at)

  // ------------------------------------------------------------ painting
  function grow() {
    text.style.height = 'auto'
    text.style.height = `${Math.max(84, text.scrollHeight)}px`
  }
  function paint() {
    // The cards: the same ones stay (and keep their place); new ones come in.
    const have = new Map([...strip.children].map(el => [el.dataset.id, el]))
    const els = s.picks.map((p, i) => {
      const el = have.get(p.key) && have.get(p.key)._pick === p ? have.get(p.key) : card(p)
      el.querySelector('.me-card-x').setAttribute('aria-label', `Remove ${p.type === 'video' ? 'video' : `photo ${i + 1}`}`)
      return el
    })
    strip.replaceChildren(...els)
    strip.hidden = !els.length
    // With a video there's no room for more; nine photos are all.
    const full = s.picks.some(p => p.type === 'video') || s.picks.length >= PHOTOS_MAX
    photosBtn.disabled = cameraBtn.disabled = full
    // Tagged friends; the time it's for.
    tagBtn.querySelector('.me-row-label').textContent = s.tags.length ? `With ${listNames(s.tags)}` : 'Tag people'
    tagBtn.classList.toggle('set', s.tags.length > 0)
    whenBtn.hidden = whenClear.hidden = !s.at
    whenBtn.querySelector('.me-row-label').textContent = s.at ? `Scheduled for ${whenText(s.at)}` : ''
    scheduleBtn.classList.toggle('set', Boolean(s.at))
    // Who can see it, and comment.
    whoBtn.querySelector('.me-who-icon').replaceChildren(icon(s.audience === 'friends' ? 'people' : 'globe'))
    whoBtn.querySelector('.me-who-label').textContent = whoText(s.audience, s.comments)
    whoBtn.setAttribute('aria-label', `${whoText(s.audience, s.comments)}. Change`)
    undoBtn.disabled = !past.length
    redoBtn.disabled = !future.length
    paintCount()
  }
  function paintCount() {
    const n = Array.from(s.text).length
    const left = TEXT_MAX - n
    ringFill.style.strokeDasharray = `${clamp((n / TEXT_MAX) * 100, 0, 100)} 100`
    ring.classList.toggle('near', left <= 100)
    ring.classList.toggle('none', n === 0)
    ring.querySelector('.me-ring-n').textContent = left <= 100 ? String(left) : ''
    ring.setAttribute('aria-label', `${left} characters left`)
    post.disabled = posting || !(s.text.trim() || s.picks.length)
    post.textContent = s.at ? 'Schedule' : 'Post'
  }
  const listNames = ids => {
    const names = ids.map(id => nameOf(friends.get(id)) || 'a friend')
    return names.length <= 2 ? names.join(' and ') : `${names[0]} and ${names.length - 1} others`
  }

  function card(p) {
    const ratio = p.w && p.h ? clamp(p.w / p.h, 0.62, 1.6) : 1
    const x = h('button', { class: 'me-card-x', type: 'button' }, icon('xmark'))
    x.addEventListener('click', () => step({ ...s, picks: s.picks.filter(q => q.key !== p.key) }))
    const tools = []
    if (p.type === 'image') {
      const edit = h('button', { class: 'me-card-btn me-card-edit', type: 'button', 'aria-label': 'Edit photo' }, icon('pencil'))
      edit.addEventListener('click', async () => {
        const next = await openPhotoEditor(p, { origin: edit, urls })
        if (next) step({ ...s, picks: s.picks.map(q => q.key === p.key ? next : q) })
      })
      const alt = h('button', { class: ['me-card-btn', 'me-card-alt', p.alt && 'set'], type: 'button', 'aria-label': p.alt ? `Description: ${p.alt}. Edit` : 'Add a description' }, p.alt ? [icon('check'), 'ALT'] : '+ALT')
      alt.addEventListener('click', async () => {
        const desc = await openAltEditor(p, { origin: alt })
        if (desc !== null && desc !== (p.alt || '')) step({ ...s, picks: s.picks.map(q => q.key === p.key ? { ...q, alt: desc } : q) })
      })
      tools.push(edit, alt)
    }
    const el = h('div', { class: ['me-card', p.type === 'video' && 'video'], role: 'listitem', dataset: { id: p.key }, style: { '--ratio': String(ratio) } },
      p.type === 'video' ? h('video', { src: p.url, muted: true, playsInline: true, preload: 'metadata' }) : h('img', { src: p.url, alt: p.alt || '', draggable: false }),
      p.type === 'video' ? h('span', { class: 'mo-play', 'aria-hidden': 'true' }, icon('play')) : null,
      x, tools.length ? h('div', { class: 'me-card-tools' }, tools) : null)
    el._pick = p
    return el
  }

  // ------------------------------------------------------------ writing
  text.addEventListener('input', () => {
    // One step per pause in the typing.
    if (!burst) { past.push(s); future.length = 0 }
    clearTimeout(burst)
    burst = setTimeout(() => { burst = 0 }, 700)
    s = { ...s, text: text.value }
    grow()
    undoBtn.disabled = !past.length
    redoBtn.disabled = true
    paintCount()
  })
  undoBtn.addEventListener('click', undo)
  redoBtn.addEventListener('click', redo)
  sheet.el.addEventListener('keydown', e => {
    if (!(e.metaKey || e.ctrlKey) || e.key.toLowerCase() !== 'z' || e.altKey) return
    e.preventDefault()
    if (e.shiftKey) redo()
    else undo()
  })

  // ------------------------------------------------------------ photos and video
  photosBtn.addEventListener('click', () => library.click())
  cameraBtn.addEventListener('click', () => camera.click())
  for (const input of [library, camera]) input.addEventListener('change', () => add([...input.files]).finally(() => { input.value = '' }))
  async function add(files) {
    const picks = [...s.picks]
    for (const f of files) {
      const video = f.type.startsWith('video/')
      if (video && (picks.length || files.length > 1)) { toast('A video goes on its own', { type: 'error' }); continue }
      if (!video && !f.type.startsWith('image/')) continue
      if (picks.some(p => p.type === 'video') || picks.length >= PHOTOS_MAX) { toast(`Up to ${PHOTOS_MAX} photos, or 1 video`); break }
      if (video) {
        if (f.size > VIDEO_MAX_BYTES) { toast('That video is too large (30 MB at most)', { type: 'error' }); continue }
        const url = URL.createObjectURL(f)
        urls.add(url)
        const [w, hh] = await videoSize(url)
        picks.push({ key: `p${++pickSeq}`, file: f, url, type: 'video', w, h: hh })
      } else {
        const { file, w, h: hh } = await prepareImage(f)
        const url = URL.createObjectURL(file)
        urls.add(url)
        picks.push({ key: `p${++pickSeq}`, file, url, type: 'image', w, h: hh, alt: '' })
      }
    }
    if (picks.length !== s.picks.length) {
      step({ ...s, picks })
      requestAnimationFrame(() => strip.lastElementChild?.scrollIntoView({ behavior: 'smooth', inline: 'end', block: 'nearest' }))
    }
  }

  // ------------------------------------------------------------ with whom, who can see, when
  const friends = new Map()
  const loadFriends = api.get('/api/friends').then(r => { for (const u of r.friends || []) friends.set(u.id, u); paint() }).catch(() => {})
  tagBtn.addEventListener('click', async () => {
    await loadFriends
    const next = await openTagPicker({ origin: tagBtn, friends: [...friends.values()], chosen: s.tags })
    if (next && next.join() !== s.tags.join()) step({ ...s, tags: next })
  })
  whoBtn.addEventListener('click', () => openMenu(whoBtn, [
    [
      { label: 'Everyone can see it', icon: 'globe', checked: s.audience === 'everyone', onSelect: () => s.audience !== 'everyone' && step({ ...s, audience: 'everyone' }) },
      { label: 'Only friends can see it', icon: 'people', checked: s.audience === 'friends', onSelect: () => s.audience !== 'friends' && step({ ...s, audience: 'friends' }) }
    ],
    [
      { label: 'Everyone can comment', icon: 'bubble', checked: s.comments === 'everyone', onSelect: () => s.comments !== 'everyone' && step({ ...s, comments: 'everyone' }) },
      { label: 'Only friends can comment', icon: 'people', checked: s.comments === 'friends', onSelect: () => s.comments !== 'friends' && step({ ...s, comments: 'friends' }) },
      { label: 'Comments off', icon: 'xmark', checked: s.comments === 'off', onSelect: () => s.comments !== 'off' && step({ ...s, comments: 'off' }) }
    ]
  ], { title: 'Who can see and comment' }))
  const schedule = async anchor => {
    const at = await openSchedulePicker({ origin: anchor, at: s.at })
    if (at !== undefined && at !== s.at) step({ ...s, at })
  }
  scheduleBtn.addEventListener('click', () => schedule(scheduleBtn))
  whenBtn.addEventListener('click', () => schedule(whenBtn))
  whenClear.addEventListener('click', () => step({ ...s, at: null }))

  // ------------------------------------------------------------ cancel, post
  cancel.addEventListener('click', async () => {
    if (hasContent() && !(await confirmAction(cancel, { title: 'Discard this moment?', message: 'What you wrote and the photos you picked won’t be kept.', confirm: 'Discard', destructive: true }))) return
    sheet.close()
  })
  let posting = false
  const status = head.querySelector('.me-status')
  post.addEventListener('click', async () => {
    if (posting) return
    if (s.at && s.at < Date.now() + 60 * 1000) { toast('Pick a time at least a minute from now', { type: 'error' }); return }
    posting = true
    sheet.el.classList.add('posting')
    paintCount()
    const bar = progress.firstChild
    const total = s.picks.length + 1
    const advance = i => { bar.style.transform = `scaleX(${i / total})` }
    try {
      const media = []
      for (const [i, p] of s.picks.entries()) {
        status.textContent = s.picks.length > 1 ? `Uploading ${i + 1} of ${s.picks.length}…` : 'Uploading…'
        advance(i + 0.3)
        const res = await fetch(`/api/media/upload?kind=moment&name=moment&w=${p.w || ''}&h=${p.h || ''}`, {
          method: 'POST', credentials: 'same-origin', headers: { 'content-type': p.file.type || (p.type === 'video' ? 'video/mp4' : 'image/jpeg') }, body: p.file
        })
        const data = await res.json().catch(() => ({}))
        if (!res.ok || !data.ok) throw new Error(data.error || 'Upload failed')
        media.push({ url: data.url, type: p.type, w: p.w, h: p.h, ...(p.alt && { alt: p.alt }) })
        advance(i + 1)
      }
      status.textContent = s.at ? 'Scheduling…' : 'Sharing…'
      const r = await api.post('/api/moments', { text: s.text, media, audience: s.audience, comments: s.comments, tags: s.tags, ...(s.at && { at: s.at }) })
      advance(total)
      sheet.close()
      toast(s.at ? `Scheduled for ${whenText(s.at)}` : s.audience === 'friends' ? 'Shared with your friends' : 'Shared', { type: 'ok' })
      onPosted?.(r.moment)
    } catch (err) {
      toast(err.message || "Couldn't share it", { type: 'error' })
      status.textContent = ''
      bar.style.transform = ''
      sheet.el.classList.remove('posting')
      posting = false
      paintCount()
    }
  })

  paint()
  grow()
  requestAnimationFrame(() => text.focus({ preventScroll: true }))
  return sheet
}

// ---------------------------------------------------------------- a description
/** Resolves to the description (maybe ''), or null if left as it was. */
function openAltEditor(p, { origin }) {
  return new Promise(settle => {
    const resolve = once(settle)
    let result = null
    const area = h('textarea', { class: 'me-alt-text', maxlength: ALT_MAX, rows: 5, placeholder: 'Describe what’s in the photo', 'aria-label': 'Description' })
    area.value = p.alt || ''
    const count = h('span', { class: 'me-alt-count tabular' })
    const done = h('button', { class: 'glass glass-btn me-alt-done', type: 'button', 'aria-label': 'Done' }, icon('check'))
    const cancel = h('button', { class: 'glass glass-btn', type: 'button', 'aria-label': 'Cancel' }, icon('xmark'))
    const content = h('div', { class: 'me-alt' },
      h('img', { class: 'me-alt-photo', src: p.url, alt: '' }),
      area, count,
      h('p', { class: 'me-hint' }, 'A description helps people who can’t see the photo, and comes up when they use a screen reader.'))
    const sheet = openSheet({ title: 'Description', content, start: cancel, end: done, origin, onClose: () => resolve(result) })
    sheet.el.classList.add('me-small-sheet')
    const paint = () => { count.textContent = `${Array.from(area.value).length}/${ALT_MAX}` }
    area.addEventListener('input', paint)
    cancel.addEventListener('click', () => sheet.close())
    done.addEventListener('click', () => { resolve(area.value.replace(/\s+/g, ' ').trim()); sheet.close() })
    paint()
    requestAnimationFrame(() => area.focus({ preventScroll: true }))
  })
}

// ---------------------------------------------------------------- with whom
/** Up to ten friends; resolves to their ids, or null if left as it was. */
function openTagPicker({ origin, friends, chosen }) {
  return new Promise(settle => {
    const resolve = once(settle)
    const picked = new Set(chosen)
    let result = null
    const search = h('input', { class: 'input me-tag-search', type: 'search', placeholder: 'Search friends', autocomplete: 'off', 'aria-label': 'Search friends' })
    const list = h('ul', { class: 'me-tag-list', 'aria-label': 'Friends' })
    const note = h('p', { class: 'me-hint' })
    const done = h('button', { class: 'glass glass-btn me-alt-done', type: 'button', 'aria-label': 'Done' }, icon('check'))
    const cancel = h('button', { class: 'glass glass-btn', type: 'button', 'aria-label': 'Cancel' }, icon('xmark'))
    const content = h('div', { class: 'me-tagging' }, search, list, note)
    const sheet = openSheet({ title: 'Tag people', content, tall: true, start: cancel, end: done, origin, onClose: () => resolve(result) })
    sheet.el.classList.add('me-small-sheet')
    function paint() {
      const q = search.value.trim().toLowerCase()
      const shown = friends.filter(u => !q || nameOf(u).toLowerCase().includes(q) || u.username.toLowerCase().includes(q))
      list.replaceChildren(...shown.map(u => {
        const on = picked.has(u.id)
        const b = h('button', { class: ['me-tag-row', on && 'on'], type: 'button', role: 'checkbox', 'aria-checked': String(on), dataset: { user: u.id } },
          avatar(u.avatar, nameOf(u), { size: 44 }),
          h('span', { class: 'me-tag-name' }, h('b', {}, nameOf(u)), h('span', {}, '@' + u.username)),
          h('span', { class: 'me-tag-check', 'aria-hidden': 'true' }, icon('check')))
        b.addEventListener('click', () => {
          if (picked.has(u.id)) picked.delete(u.id)
          else if (picked.size >= TAGS_MAX) { toast(`Up to ${TAGS_MAX} people`); return }
          else picked.add(u.id)
          paint()
        })
        return h('li', {}, b)
      }))
      note.textContent = friends.length ? `${picked.size} of up to ${TAGS_MAX} · Friends you tag see it with them.` : 'You can tag your friends: your contacts and the people you’ve written with.'
    }
    search.addEventListener('input', paint)
    cancel.addEventListener('click', () => sheet.close())
    done.addEventListener('click', () => { resolve(friends.map(u => u.id).filter(id => picked.has(id))); sheet.close() })
    paint()
  })
}

// ---------------------------------------------------------------- when
/** Resolves to a time to share it at, null to share it now, or undefined if left as it was. */
function openSchedulePicker({ origin, at }) {
  return new Promise(settle => {
    const resolve = once(settle)
    let result
    const pad = n => String(n).padStart(2, '0')
    const local = ts => { const d = new Date(ts); return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}` }
    const soonest = Date.now() + 5 * 60 * 1000
    const latest = Date.now() + 30 * 24 * 60 * 60 * 1000 - 60 * 1000
    const input = h('input', { class: 'input me-when-input', type: 'datetime-local', min: local(soonest), max: local(latest), 'aria-label': 'Date and time' })
    input.value = local(at || Date.now() + 60 * 60 * 1000)
    const at9 = (days, hour) => { const d = new Date(); d.setDate(d.getDate() + days); d.setHours(hour, 0, 0, 0); return d.getTime() }
    const tonight = at9(0, 20) > soonest ? at9(0, 20) : at9(1, 20)
    const quick = [['In an hour', Date.now() + 60 * 60 * 1000], [tonight === at9(0, 20) ? 'Tonight, 20:00' : 'Tomorrow, 20:00', tonight], ['Tomorrow, 9:00', at9(1, 9)]]
    const chips = h('div', { class: 'me-when-chips' }, quick.map(([label, ts]) => {
      const b = h('button', { class: 'me-chip', type: 'button' }, label)
      b.addEventListener('click', () => { input.value = local(ts); paint() })
      return b
    }))
    const summary = h('p', { class: 'me-when-summary' })
    const set = h('button', { class: 'glass glass-btn me-alt-done', type: 'button', 'aria-label': 'Schedule' }, icon('check'))
    const cancel = h('button', { class: 'glass glass-btn', type: 'button', 'aria-label': 'Cancel' }, icon('xmark'))
    const now = at ? h('button', { class: 'me-when-now', type: 'button' }, 'Share it now instead') : null
    const content = h('div', { class: 'me-scheduling' }, chips, input, summary, h('p', { class: 'me-hint' }, 'Only you see it until then; friends get it when the time comes. Up to 30 days ahead.'), now)
    const sheet = openSheet({ title: 'Schedule', content, start: cancel, end: set, origin, onClose: () => resolve(result) })
    sheet.el.classList.add('me-small-sheet')
    const chosen = () => { const t = new Date(input.value).getTime(); return Number.isFinite(t) ? t : NaN }
    function paint() {
      const t = chosen()
      const ok = t >= soonest - 60 * 1000 && t <= latest + 60 * 1000
      set.disabled = !ok
      summary.textContent = ok ? `Shares ${whenText(t)}` : 'Pick a time from a few minutes to 30 days ahead'
      summary.classList.toggle('bad', !ok)
    }
    input.addEventListener('input', paint)
    cancel.addEventListener('click', () => sheet.close())
    set.addEventListener('click', () => { resolve(chosen()); sheet.close() })
    now?.addEventListener('click', () => { resolve(null); sheet.close() })
    paint()
  })
}

// ---------------------------------------------------------------- editing a photo
// Turn it, crop it to a shape, give it a look — always from the photo as it
// was picked, so editing again starts over from the original.
const LOOKS = [
  ['none', 'Original', 'none'],
  ['vivid', 'Vivid', 'saturate(1.35) contrast(1.08)'],
  ['warm', 'Warm', 'sepia(.22) saturate(1.25) brightness(1.03)'],
  ['cool', 'Cool', 'hue-rotate(-10deg) saturate(1.08) brightness(1.04)'],
  ['mono', 'Mono', 'grayscale(1) contrast(1.12)'],
  ['fade', 'Fade', 'contrast(.86) brightness(1.08) saturate(.8)']
]
const SHAPES = [['original', 'Original', 0], ['square', 'Square', 1], ['portrait', '4:5', 4 / 5], ['wide', '16:9', 16 / 9]]
const canLook = typeof CanvasRenderingContext2D === 'function' && 'filter' in CanvasRenderingContext2D.prototype

/** Draws `img` turned, cropped and with a look into a canvas no larger than `max` on its long side. */
export function renderEdit(img, { rotate = 0, shape = 'original', look = 'none' }, max) {
  const turned = rotate % 180 !== 0
  const W = turned ? img.naturalHeight : img.naturalWidth
  const H = turned ? img.naturalWidth : img.naturalHeight
  const ratio = SHAPES.find(x => x[0] === shape)?.[2] || W / H
  // The largest centred rectangle of that shape.
  let cw = W, ch = W / ratio
  if (ch > H) { ch = H; cw = H * ratio }
  const scale = Math.min(1, max / Math.max(cw, ch))
  const canvas = document.createElement('canvas')
  canvas.width = Math.max(1, Math.round(cw * scale))
  canvas.height = Math.max(1, Math.round(ch * scale))
  const g = canvas.getContext('2d')
  if (canLook) g.filter = LOOKS.find(x => x[0] === look)?.[2] || 'none'
  g.translate(canvas.width / 2, canvas.height / 2)
  g.scale(scale, scale)
  g.rotate((rotate * Math.PI) / 180)
  g.drawImage(img, -img.naturalWidth / 2, -img.naturalHeight / 2)
  return canvas
}

function loadImage(url) {
  return new Promise((resolve, reject) => {
    const img = new Image()
    img.onload = () => resolve(img)
    img.onerror = reject
    img.src = url
  })
}

/** Resolves to the photo edited (a new pick), or null if left as it was. */
async function openPhotoEditor(p, { origin, urls }) {
  const original = p.original || { file: p.file, url: p.url, w: p.w, h: p.h }
  let img
  try { img = await loadImage(original.url) } catch { toast("Can't edit this photo", { type: 'error' }); return null }
  return new Promise(settle => {
    const resolve = once(settle)
    let edit = { rotate: 0, shape: 'original', look: 'none', ...p.edit }
    let result = null
    const stage = h('div', { class: 'me-edit-stage' })
    const turn = h('button', { class: 'me-chip me-turn', type: 'button' }, icon('rotate'), 'Rotate')
    const shapes = h('div', { class: 'seg me-shapes', role: 'radiogroup', 'aria-label': 'Crop', style: { '--n': String(SHAPES.length) } }, h('span', { class: 'thumb', 'aria-hidden': 'true' }),
      SHAPES.map(([id, label]) => h('button', { type: 'button', role: 'radio', dataset: { shape: id } }, label)))
    const looks = h('div', { class: 'me-looks', role: 'radiogroup', 'aria-label': 'Look', hidden: !canLook })
    const done = h('button', { class: 'glass glass-btn me-alt-done', type: 'button', 'aria-label': 'Done' }, icon('check'))
    const cancel = h('button', { class: 'glass glass-btn', type: 'button', 'aria-label': 'Cancel' }, icon('xmark'))
    const content = h('div', { class: 'me-edit' }, stage, h('div', { class: 'me-edit-row' }, turn, shapes), looks)
    // Done also closes the sheet (it is the sheet's end button), and saving
    // the edit takes a moment: if the sheet is gone first, wait for the edit
    // rather than settling on nothing (which lost it on a slow phone).
    let saving = null
    const sheet = openSheet({ title: 'Edit photo', content, tall: true, start: cancel, end: done, origin, onClose: () => (saving ? saving.then(resolve) : resolve(result)) })
    sheet.el.classList.add('me-small-sheet', 'me-edit-sheet')
    // A small copy to try the looks on.
    const thumb = renderEdit(img, { rotate: 0, shape: 'square', look: 'none' }, 120)
    function paintLooks() {
      looks.replaceChildren(...LOOKS.map(([id, label, filter]) => {
        const c = document.createElement('canvas')
        c.width = c.height = 64
        const g = c.getContext('2d')
        g.filter = filter
        g.drawImage(thumb, 0, 0, 64, 64)
        const b = h('button', { class: ['me-look', edit.look === id && 'on'], type: 'button', role: 'radio', 'aria-checked': String(edit.look === id), dataset: { look: id } }, c, h('span', {}, label))
        b.addEventListener('click', () => { edit = { ...edit, look: id }; paint() })
        return b
      }))
    }
    function paint() {
      const preview = renderEdit(img, edit, 900)
      preview.classList.add('me-edit-preview')
      stage.replaceChildren(preview)
      const i = SHAPES.findIndex(x => x[0] === edit.shape)
      shapes.style.setProperty('--i', String(i))
      for (const b of shapes.querySelectorAll('button')) b.setAttribute('aria-checked', String(b.dataset.shape === edit.shape))
      if (canLook) paintLooks()
      done.disabled = false
    }
    turn.addEventListener('click', () => { edit = { ...edit, rotate: (edit.rotate + 90) % 360 }; paint() })
    shapes.addEventListener('click', e => { const b = e.target.closest('button'); if (b) { edit = { ...edit, shape: b.dataset.shape }; paint() } })
    cancel.addEventListener('click', () => sheet.close())
    done.addEventListener('click', async () => {
      const same = !edit.rotate && edit.shape === 'original' && edit.look === 'none'
      if (same) {
        // Back to the photo as picked.
        resolve(p.original ? { ...p, ...original, original: undefined, edit: undefined } : null)
        sheet.close()
        return
      }
      done.disabled = true
      saving = (async () => {
        const canvas = renderEdit(img, edit, 2048)
        const blob = await new Promise(r => canvas.toBlob(r, 'image/jpeg', 0.9))
        if (!blob) { toast("Can't save this edit", { type: 'error' }); return null }
        const file = new File([blob], 'moment.jpg', { type: 'image/jpeg' })
        const url = URL.createObjectURL(file)
        urls.add(url)
        return { ...p, file, url, w: canvas.width, h: canvas.height, original, edit }
      })()
      const next = await saving
      if (!next) { saving = null; done.disabled = false; return }
      resolve(next)
      sheet.close()
    })
    paint()
  })
}

function videoSize(url) {
  return new Promise(settle => {
    const resolve = once(settle)
    const v = document.createElement('video')
    v.preload = 'metadata'
    v.muted = true
    v.onloadedmetadata = () => resolve([v.videoWidth || 0, v.videoHeight || 0])
    v.onerror = () => resolve([0, 0])
    setTimeout(() => resolve([0, 0]), 4000)
    v.src = url
  })
}
