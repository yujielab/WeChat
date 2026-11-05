// Your photo and your cover, edited the way the system edits yours (Settings ›
// your name › photo): Cancel and Done at the top corners with 头像 | 封面
// between them; the picture large in the middle, with − to take it away and
// 自定义 to move and zoom it in its circle; then where a new one comes from —
// a photo, or one used before (最近使用) — and, for the cover, the app's own.
// The sheet takes its colour from the photo. Nothing is saved until Done.

import { h, icon } from '../ui/dom.js'
import { api } from '../api.js'
import { state, setMe } from '../store.js'
import { avatar } from './avatar.js'
import { openSheet, toast } from './overlay.js'
import { PRESETS, backdropLayer, paintBackdrop } from '../ui/backdrops.js'
import { prepareImage } from './composer.js'
import { clampFrame, frameBox, cropRect, zoomAbout, tintOf, MAX_ZOOM, OUTPUT } from '../ui/framing.js'

async function upload(kind, blob) {
  const res = await fetch(`/api/media/upload?kind=${kind}&name=${kind}`, {
    method: 'POST', credentials: 'same-origin', headers: { 'content-type': blob.type || 'image/jpeg' }, body: blob
  })
  const data = await res.json().catch(() => ({}))
  if (!res.ok || !data.ok) throw new Error(data.error || '上传失败')
  return data.url
}

/** The average colour of a loaded picture, or null when it can't be read. */
function averageColour(img) {
  try {
    const c = document.createElement('canvas')
    c.width = c.height = 12
    const g = c.getContext('2d', { willReadFrequently: true })
    g.drawImage(img, 0, 0, 12, 12)
    const d = g.getImageData(0, 0, 12, 12).data
    let r = 0, gr = 0, b = 0, n = 0
    for (let i = 0; i < d.length; i += 4) { if (d[i + 3] < 128) continue; r += d[i]; gr += d[i + 1]; b += d[i + 2]; n++ }
    return n ? [r / n, gr / n, b / n] : null
  } catch {
    return null
  }
}

/**
 * tab: 'avatar' | 'cover'; origin: what opened it (the sheet grows out of
 * it unfolded); onSaved(me) once Done has saved something.
 */
export function openAvatarEditor({ tab = 'avatar', origin, onSaved } = {}) {
  const me = state.me || {}
  const name = me.display || me.username || '我'
  // The avatar as it stands in the editor: a picture (the one in use, one used
  // before, or a new photo) or none (the initials), and how it is framed.
  let photo = me.avatar ? { src: me.avatar, kind: 'current' } : null
  let frame = null      // { w, h, zoom, x, y } once the picture has loaded
  let framed = false    // moved or zoomed since it was chosen
  let framing = false   // 自定义 is on: drag and pinch move and zoom it
  let cover = me.cover || ''
  let busy = false
  let picked = null     // the object URL of a photo chosen here, let go on close

  // ---------------------------------------------------------------- head: Cancel, 头像 | 封面, Done
  const cancel = h('button', { class: 'glass glass-btn av-cancel', type: 'button', 'aria-label': '取消' }, icon('xmark'))
  const done = h('button', { class: 'glass glass-btn av-done', type: 'button', 'aria-label': '完成' }, icon('check'))
  const tabs = [['avatar', '头像'], ['cover', '封面']]
  const seg = h('div', { class: 'av-seg', role: 'tablist', 'aria-label': '编辑' },
    h('span', { class: 'av-seg-thumb', 'aria-hidden': 'true' }),
    tabs.map(([id, label]) => h('button', { type: 'button', role: 'tab', class: 'av-seg-item', dataset: { tab: id } }, label)))

  // ---------------------------------------------------------------- avatar
  const preview = h('div', { class: 'av-preview', role: 'img', 'aria-label': '头像预览' })
  const remove = h('button', { class: 'av-remove', type: 'button', 'aria-label': '移除照片' }, h('span', { 'aria-hidden': 'true' }, '−'))
  const custom = h('button', { class: 'av-custom', type: 'button' }, '自定义')
  const zoom = h('input', { class: 'av-zoom', type: 'range', min: '1', max: String(MAX_ZOOM), step: '0.01', value: '1', 'aria-label': '缩放', hidden: true })
  const hint = h('p', { class: 'av-hint', hidden: true }, '拖动移动，双指或滑块缩放。')
  const file = h('input', { type: 'file', accept: 'image/*', hidden: true })
  const pick = h('button', { class: 'av-pick', type: 'button' },
    h('span', { class: 'av-pick-icon', 'aria-hidden': 'true' }, icon('photo')),
    h('span', { class: 'av-pick-text' }, h('span', { class: 'av-pick-title' }, '选取照片'), h('span', { class: 'av-pick-sub' }, '从相册选一张，再移动、缩放到合适的位置。')))
  const recentGrid = h('div', { class: 'av-recent', role: 'list' })
  const recentSection = h('section', { class: 'av-section', hidden: true }, h('h3', {}, '最近使用'), recentGrid)
  const avatarPane = h('div', { class: 'av-pane', role: 'tabpanel', dataset: { pane: 'avatar' } },
    h('div', { class: 'av-stage' }, preview, remove),
    h('div', { class: 'av-under' }, custom, zoom, hint),
    h('section', { class: 'av-section' }, h('h3', {}, '照片'), pick, file),
    recentSection)

  // ---------------------------------------------------------------- cover
  const coverBand = backdropLayer(cover)
  const face = h('span', { class: 'cv-face', 'aria-hidden': 'true' })
  const coverPreview = h('div', { class: 'cv-preview', role: 'img', 'aria-label': '封面预览' },
    h('div', { class: 'cv-band' }, coverBand), face, h('span', { class: 'cv-face-name' }, name))
  const coverRemove = h('button', { class: 'av-remove cv-remove', type: 'button', 'aria-label': '移除封面' }, h('span', { 'aria-hidden': 'true' }, '−'))
  const coverFile = h('input', { type: 'file', accept: 'image/*', hidden: true })
  const coverPick = h('button', { class: 'av-pick', type: 'button' },
    h('span', { class: 'av-pick-icon', 'aria-hidden': 'true' }, icon('photo')),
    h('span', { class: 'av-pick-text' }, h('span', { class: 'av-pick-title' }, '选取照片'), h('span', { class: 'av-pick-sub' }, '打开你的资料的人会在最上面看到它。')))
  const presetGrid = h('div', { class: 'cv-grid', role: 'radiogroup', 'aria-label': '封面样式' })
  const presetTiles = [['', '无'], ...PRESETS.map(p => [`preset:${p.id}`, p.label])].map(([value, label]) => {
    const b = h('button', { class: 'cv-tile', type: 'button', role: 'radio', 'aria-label': label }, backdropLayer(value), h('span', { class: 'cv-name' }, label))
    b._value = value
    b.addEventListener('click', () => setCover(value))
    return b
  })
  presetGrid.append(...presetTiles)
  const coverPane = h('div', { class: 'av-pane', role: 'tabpanel', dataset: { pane: 'cover' }, hidden: true },
    h('div', { class: 'cv-stage' }, coverPreview, coverRemove),
    h('section', { class: 'av-section' }, h('h3', {}, '照片'), coverPick, coverFile),
    h('section', { class: 'av-section' }, h('h3', {}, '样式'), presetGrid))

  const content = h('div', { class: 'av-editor-body' }, avatarPane, coverPane)
  const sheet = openSheet({
    label: '编辑头像和封面', content, tall: true, start: cancel, end: done, origin,
    onClose: () => { if (picked) URL.revokeObjectURL(picked) }
  })
  sheet.el.classList.add('av-editor')
  sheet.el.querySelector('.sheet-head .end').before(seg)
  cancel.addEventListener('click', () => sheet.close())

  // ---------------------------------------------------------------- tabs
  function show(id) {
    tab = id
    seg.style.setProperty('--i', String(tabs.findIndex(t => t[0] === id)))
    for (const b of seg.querySelectorAll('.av-seg-item')) b.setAttribute('aria-selected', String(b.dataset.tab === id))
    avatarPane.hidden = id !== 'avatar'
    coverPane.hidden = id !== 'cover'
    if (id !== 'avatar') setFraming(false)
    // Sizes are only known on the tab that shows.
    if (id === 'avatar') place()
    else paintFace()
  }
  seg.addEventListener('click', e => { const b = e.target.closest('.av-seg-item'); if (b) show(b.dataset.tab) })

  // ---------------------------------------------------------------- the picture
  // The circle's size on screen; 0 while its tab is hidden.
  const diameter = () => preview.clientWidth
  let img = null
  function paintAvatar() {
    preview.replaceChildren()
    img = null
    frame = null
    remove.hidden = !photo
    custom.hidden = !photo
    setFraming(false)
    if (!photo) {
      const mono = avatar('', name)
      preview.append(mono)
      const hue = getComputedStyle(mono).getPropertyValue('--avatar-hue').trim() || '27'
      tint(`hsl(${hue} 22% 80%)`, `hsl(${hue} 22% 17%)`)
      paintFace()
      return
    }
    img = new Image()
    img.className = 'av-photo'
    img.alt = ''
    img.draggable = false
    img.decoding = 'async'
    img.addEventListener('load', () => {
      if (!img) return
      frame = { w: img.naturalWidth, h: img.naturalHeight, zoom: 1, x: 0, y: 0 }
      place()
      paintFace()
      const c = averageColour(img)
      if (c) tint(tintOf(...c, false), tintOf(...c, true))
    })
    img.addEventListener('error', () => {
      // The photo in use that didn't load is still in use: shown as the
      // initials, but never taken away by a Done meant for the cover.
      if (photo?.kind === 'current') {
        img = null
        preview.replaceChildren(avatar('', name))
        custom.hidden = true
        paintFace()
        return
      }
      toast('这张图片打不开', { type: 'error' })
      photo = me.avatar ? { src: me.avatar, kind: 'current' } : null
      framed = false
      paintAvatar()
    })
    img.src = photo.src
    preview.append(img)
  }
  const drawAt = (el, box) => Object.assign(el.style, { left: `${box.left}px`, top: `${box.top}px`, width: `${box.width}px`, height: `${box.height}px` })
  function place() {
    const d = diameter()
    if (!img || !frame || !d) return
    // The framing is kept in the circle's pixels (frame.d); a circle drawn at
    // another size (the window changed) keeps the same part of the photo.
    const k = frame.d ? d / frame.d : 1
    const f = clampFrame({ ...frame, d, x: frame.x * k, y: frame.y * k })
    frame = { ...frame, d, zoom: f.zoom, x: f.x, y: f.y }
    drawAt(img, frameBox({ ...frame, d }))
    zoom.value = String(frame.zoom)
  }
  // The same picture, framed the same way, over the cover's lower edge.
  let faceImg = null
  function paintFace() {
    if (!photo || !img) {
      faceImg = null
      face.replaceChildren(avatar('', name))
      return
    }
    if (!faceImg || faceImg.dataset.src !== photo.src) {
      faceImg = h('img', { class: 'av-photo', alt: '', draggable: false, src: photo.src, dataset: { src: photo.src } })
      face.replaceChildren(faceImg)
    }
    const fd = face.clientWidth
    if (!frame || !fd) return
    const k = frame.d ? fd / frame.d : 0
    drawAt(faceImg, frameBox({ ...frame, d: fd, x: frame.x * k, y: frame.y * k }))
  }
  // Both shades are kept, and the stylesheet wears the one the theme asks for,
  // so switching theme with the sheet open still reads.
  function tint(light, dark) {
    sheet.el.style.setProperty('--av-tint-light', light)
    sheet.el.style.setProperty('--av-tint-dark', dark)
  }

  function setFraming(on) {
    framing = Boolean(on && photo)
    preview.classList.toggle('framing', framing)
    zoom.hidden = hint.hidden = !framing
    custom.textContent = framing ? '完成调整' : '自定义'
    custom.setAttribute('aria-pressed', String(framing))
  }
  custom.addEventListener('click', () => setFraming(!framing))
  remove.addEventListener('click', () => { photo = null; framed = false; paintAvatar() })
  zoom.addEventListener('input', () => {
    if (!frame) return
    frame = zoomAbout({ ...frame, d: diameter() }, Number(zoom.value), 0, 0)
    framed = true
    place()
  })

  // Drag to move; two fingers (or the wheel) to zoom about where they are.
  const pointers = new Map()
  let pinch = null
  preview.addEventListener('pointerdown', e => {
    if (!framing || !frame) return
    preview.setPointerCapture?.(e.pointerId)
    pointers.set(e.pointerId, { x: e.clientX, y: e.clientY })
    if (pointers.size === 2) {
      const [a, b] = [...pointers.values()]
      pinch = { dist: Math.hypot(a.x - b.x, a.y - b.y), zoom: frame.zoom }
    }
  })
  preview.addEventListener('pointermove', e => {
    const was = pointers.get(e.pointerId)
    if (!was || !frame) return
    const now = { x: e.clientX, y: e.clientY }
    pointers.set(e.pointerId, now)
    const r = preview.getBoundingClientRect()
    if (pointers.size >= 2 && pinch) {
      const [a, b] = [...pointers.values()]
      const mid = { x: (a.x + b.x) / 2 - r.left - r.width / 2, y: (a.y + b.y) / 2 - r.top - r.height / 2 }
      frame = zoomAbout({ ...frame, d: diameter() }, pinch.zoom * Math.hypot(a.x - b.x, a.y - b.y) / Math.max(1, pinch.dist), mid.x, mid.y)
    } else {
      frame = { ...frame, x: frame.x + now.x - was.x, y: frame.y + now.y - was.y }
    }
    framed = true
    place()
  })
  const lift = e => { pointers.delete(e.pointerId); if (pointers.size < 2) pinch = null }
  preview.addEventListener('pointerup', lift)
  preview.addEventListener('pointercancel', lift)
  preview.addEventListener('wheel', e => {
    if (!framing || !frame) return
    e.preventDefault()
    const r = preview.getBoundingClientRect()
    frame = zoomAbout({ ...frame, d: diameter() }, frame.zoom * Math.exp(-e.deltaY / 400), e.clientX - r.left - r.width / 2, e.clientY - r.top - r.height / 2)
    framed = true
    place()
  }, { passive: false })

  // A new photo: shown at once, framed here, uploaded only on Done.
  pick.addEventListener('click', () => file.click())
  file.addEventListener('change', async () => {
    const f = file.files[0]
    file.value = ''
    if (!f) return
    const { file: prepared } = await prepareImage(f)
    if (picked) URL.revokeObjectURL(picked)
    picked = URL.createObjectURL(prepared)
    photo = { src: picked, kind: 'file' }
    framed = false
    paintAvatar()
    setFraming(true)
  })

  // Photos used before.
  api.get('/api/profile/avatars').then(r => {
    const recent = (r?.recent || []).filter(u => typeof u === 'string')
    if (!recent.length || !sheet.el.isConnected) return
    recentGrid.replaceChildren(...recent.map(src => {
      const b = h('button', { class: 'av-recent-item', type: 'button', role: 'listitem', 'aria-label': '用这张' }, h('img', { src, alt: '', draggable: false, loading: 'lazy' }))
      b.addEventListener('click', () => { photo = { src, kind: 'url' }; framed = false; paintAvatar() })
      return b
    }))
    recentSection.hidden = false
  }).catch(() => {})

  // ---------------------------------------------------------------- cover
  function setCover(value) {
    cover = value
    paintBackdrop(coverBand, value)
    coverRemove.hidden = !value
    for (const t of presetTiles) t.setAttribute('aria-checked', String(t._value === value))
  }
  coverRemove.addEventListener('click', () => setCover(''))
  coverPick.addEventListener('click', () => coverFile.click())
  coverFile.addEventListener('change', async () => {
    const f = coverFile.files[0]
    coverFile.value = ''
    if (!f || busy) return
    busy = true
    coverPick.classList.add('loading')
    try {
      const { file: prepared } = await prepareImage(f)
      setCover(await upload('cover', prepared))
    } catch (err) {
      toast(err.message || '上传失败', { type: 'error' })
    } finally {
      busy = false
      coverPick.classList.remove('loading')
    }
  })

  // ---------------------------------------------------------------- Done
  /** The square the circle shows, cut out at OUTPUT pixels. */
  function cut() {
    const { sx, sy, size } = cropRect({ ...frame, d: frame.d || OUTPUT })
    const c = document.createElement('canvas')
    c.width = c.height = OUTPUT
    c.getContext('2d').drawImage(img, sx, sy, size, size, 0, 0, OUTPUT, OUTPUT)
    return new Promise((resolve, reject) => c.toBlob(b => (b ? resolve(b) : reject(new Error('无法处理这张图片'))), 'image/jpeg', 0.9))
  }
  async function avatarValue() {
    if (!photo) return ''
    if (photo.kind !== 'file' && !framed) return photo.src
    if (!img || !frame) throw new Error('图片还没有准备好')
    return upload('avatar', await cut())
  }
  done.addEventListener('click', async () => {
    if (busy) return
    busy = true
    done.disabled = true
    try {
      const patch = {}
      const avatarChanged = (photo?.kind === 'current' ? framed : true) && !(photo === null && !me.avatar)
      if (avatarChanged) patch.avatar = await avatarValue()
      if (cover !== (me.cover || '')) patch.cover = cover
      if (Object.keys(patch).length) {
        const r = await api.post('/api/profile', patch)
        setMe(r.me)
        onSaved?.(r.me)
        toast(patch.avatar !== undefined ? '头像已更新' : '封面已更新', { type: 'ok' })
      }
      sheet.close()
    } catch (err) {
      toast(err.message || '保存失败', { type: 'error' })
      busy = false
      done.disabled = false
    }
  })

  // A circle drawn at a new size (the window changed) is framed again.
  if (typeof ResizeObserver === 'function') new ResizeObserver(() => { place(); paintFace() }).observe(preview)

  setCover(cover)
  show(tab)
  // The preview's size is known once the sheet is laid out.
  requestAnimationFrame(() => paintAvatar())
  return sheet
}
