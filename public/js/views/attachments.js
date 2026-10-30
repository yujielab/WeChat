// Images are staged locally before entering the existing real send pipeline.
// The magnetic field follows pointer activity; it has no idle animation loop.
import { h, icon, reducedMotion, announce } from '../ui/dom.js'
import { openSheet, toast } from './overlay.js'
import { dotRenderer } from '../ui/dots.js'

const IMAGE_EXT = /\.(avif|bmp|gif|heic|heif|jpe?g|png|svg|tiff?|webp)$/i
const hasFiles = event => [...(event.dataTransfer?.types || [])].includes('Files')
const isImage = file => file?.type?.startsWith('image/') || (!file?.type && IMAGE_EXT.test(file?.name || ''))
const sizeText = bytes => bytes < 1024 ? `${bytes} B` : bytes < 1048576 ? `${Math.round(bytes / 1024)} KB` : `${(bytes / 1048576).toFixed(1).replace(/\.0$/, '')} MB`

export function openAttachments({ files = [], onSend } = {}) {
  const selected = new Map()
  let submitting = false
  let serial = 0
  let depth = 0
  const fileInput = h('input', { class: 'attachment-file-input', type: 'file', accept: 'image/*', multiple: true, hidden: true })
  const canvas = h('canvas', { 'aria-hidden': 'true' })
  const title = h('span', { class: 'attachment-drop-title' }, '添加图片')
  const pick = h('button', { class: 'attachment-pick', type: 'button', 'aria-label': '选择图片' },
    h('span', { class: 'attachment-drop-icon', 'aria-hidden': 'true' }, icon('photo')), title)
  const dropzone = h('div', { class: 'attachment-dropzone', 'aria-label': '图片选择区域' }, canvas, pick, fileInput)
  const error = h('p', { class: 'attachment-error', role: 'alert' })
  const preview = h('div', { class: 'attachment-previews', role: 'list', 'aria-label': '待发送图片' })
  // The count is for assistive technology; the send button already shows it.
  const count = h('span', { class: 'sr-only', 'aria-live': 'polite' })
  const send = h('button', { class: 'btn primary solid-press attachment-send', type: 'button', disabled: true }, icon('arrow-up'), '发送图片')
  const content = h('div', { class: 'attachment-content' }, dropzone, error, preview, h('div', { class: 'attachment-footer' }, count, send))
  let cleanupField = () => {}
  const ctl = openSheet({
    title: '分享图片', content, label: '预览并发送图片', side: 'thread',
    onClose() {
      cleanupField()
      for (const item of selected.values()) URL.revokeObjectURL(item.url)
      selected.clear()
    }
  })
  ctl.el.classList.add('attachment-sheet')
  cleanupField = magneticField(dropzone, canvas)

  function update() {
    const n = selected.size
    count.textContent = n ? `已选择 ${n} 张图片` : ''
    send.disabled = submitting || !n
    send.replaceChildren(icon('arrow-up'), submitting ? '正在发送…' : n ? `发送 ${n} 张图片` : '发送图片')
    dropzone.classList.toggle('has-images', n > 0)
  }

  function addFiles(list) {
    if (submitting || ctl.closed) return
    error.textContent = ''
    let rejected = 0
    let added = 0
    for (const file of [...list]) {
      if (!isImage(file)) { rejected++; continue }
      const key = `${file.name}\u0000${file.size}\u0000${file.lastModified}\u0000${file.type}`
      if ([...selected.values()].some(item => item.key === key)) continue
      const id = ++serial
      const url = URL.createObjectURL(file)
      const image = h('img', { src: url, alt: file.name || '所选图片', decoding: 'async' })
      const visual = h('div', { class: 'attachment-preview-image' }, image)
      image.addEventListener('error', () => {
        image.hidden = true
        visual.append(icon('photo'), h('span', {}, '原图'))
      }, { once: true })
      const remove = h('button', { class: 'attachment-remove', type: 'button', 'aria-label': `移除 ${file.name || '图片'}` }, icon('xmark'))
      const tile = h('div', { class: 'attachment-preview', role: 'listitem' }, visual,
        h('div', { class: 'attachment-preview-meta' }, h('span', { title: file.name }, file.name || '图片'), h('span', {}, sizeText(file.size))), remove)
      remove.addEventListener('click', () => {
        const index = [...preview.children].indexOf(tile)
        URL.revokeObjectURL(url)
        selected.delete(id)
        tile.remove()
        update()
        const next = preview.children[index] || preview.lastElementChild
        ;(next?.querySelector('button') || pick).focus({ preventScroll: true })
      })
      selected.set(id, { key, file, url, remove, image })
      preview.append(tile)
      added++
    }
    if (rejected) error.textContent = `有 ${rejected} 个文件不是图片，已略过。`
    if (added) announce(`已选择 ${selected.size} 张图片`)
    update()
  }

  function over(on) {
    dropzone.classList.toggle('is-over', on)
    title.textContent = on ? '松开以添加' : '添加图片'
  }
  pick.addEventListener('click', () => { if (!submitting) { fileInput.value = ''; fileInput.click() } })
  fileInput.addEventListener('change', () => addFiles(fileInput.files))
  dropzone.addEventListener('dragenter', event => {
    if (!hasFiles(event)) return
    event.preventDefault()
    depth++
    over(true)
  })
  dropzone.addEventListener('dragover', event => {
    if (!hasFiles(event)) return
    event.preventDefault()
    event.dataTransfer.dropEffect = 'copy'
  })
  dropzone.addEventListener('dragleave', event => {
    if (!hasFiles(event)) return
    depth = Math.max(0, depth - 1)
    if (!depth) over(false)
  })
  dropzone.addEventListener('drop', event => {
    if (!hasFiles(event)) return
    event.preventDefault()
    event.stopPropagation()
    depth = 0
    over(false)
    addFiles(event.dataTransfer.files)
  })
  content.addEventListener('paste', event => {
    const images = [...(event.clipboardData?.files || [])].filter(isImage)
    if (!images.length) return
    event.preventDefault()
    addFiles(images)
  })
  send.addEventListener('click', async () => {
    if (submitting || !selected.size || ctl.closed) return
    submitting = true
    pick.disabled = true
    for (const item of selected.values()) item.remove.disabled = true
    update()
    try {
      // The chat owns upload, retries and real failure feedback. Do not claim
      // that staging or a resolved callback means an upload has succeeded.
      if (typeof onSend !== 'function') throw new Error('暂时无法发送，请重新打开聊天。')
      // Where each photo was seen, so its message can carry on from there.
      const from = [...selected.values()].map(item => (item.image.hidden ? null : item.image.getBoundingClientRect()))
      const delivery = onSend([...selected.values()].map(item => item.file), { from })
      if (delivery === false) throw new Error('当前聊天已变化，请重新选择发送位置。')
      await ctl.close()
      Promise.resolve(delivery).catch(err => toast(err?.message || '图片发送失败，请在聊天中重试。', { type: 'error' }))
    } catch (err) {
      submitting = false
      pick.disabled = false
      for (const item of selected.values()) item.remove.disabled = false
      error.textContent = err?.message || '暂时无法发送，请重试。'
      update()
    }
  })
  ctl.addFiles = addFiles
  addFiles(files)
  return ctl
}

/** Dragging or pasting an image into an active thread opens the same preview. */
export function bindImageDropTarget(root, { onFiles, enabled = () => true } = {}) {
  let depth = 0
  const prompt = h('div', { class: 'chat-image-drop', 'aria-hidden': 'true' },
    h('div', {}, h('span', { class: 'chat-image-drop-mark' }, icon('photo')), h('strong', {}, '松开以添加图片')))
  root.append(prompt)
  const active = event => enabled() && hasFiles(event)
  const reset = () => { depth = 0; prompt.classList.remove('on') }
  const enter = event => { if (!active(event)) return; event.preventDefault(); depth++; prompt.classList.add('on') }
  const over = event => { if (!active(event)) return; event.preventDefault(); event.dataTransfer.dropEffect = 'copy' }
  const leave = event => { if (!hasFiles(event)) return; depth = Math.max(0, depth - 1); if (!depth) reset() }
  const drop = event => {
    if (!active(event)) return
    event.preventDefault()
    event.stopPropagation()
    reset()
    onFiles?.([...event.dataTransfer.files])
  }
  const paste = event => {
    if (!enabled()) return
    const images = [...(event.clipboardData?.files || [])].filter(isImage)
    if (!images.length) return
    event.preventDefault()
    onFiles?.(images)
  }
  // Keep file drags from navigating away if the pointer leaves the chat pane.
  const preventNavigation = event => { if (active(event)) event.preventDefault() }
  root.addEventListener('dragenter', enter)
  root.addEventListener('dragover', over)
  root.addEventListener('dragleave', leave)
  root.addEventListener('drop', drop)
  root.addEventListener('paste', paste)
  window.addEventListener('dragover', preventNavigation)
  window.addEventListener('drop', preventNavigation)
  window.addEventListener('dragend', reset)
  window.addEventListener('drop', reset)
  return {
    destroy() {
      reset()
      prompt.remove()
      root.removeEventListener('dragenter', enter)
      root.removeEventListener('dragover', over)
      root.removeEventListener('dragleave', leave)
      root.removeEventListener('drop', drop)
      root.removeEventListener('paste', paste)
      window.removeEventListener('dragover', preventNavigation)
      window.removeEventListener('drop', preventNavigation)
      window.removeEventListener('dragend', reset)
      window.removeEventListener('drop', reset)
    }
  }
}

function magneticField(zone, canvas) {
  const renderer = dotRenderer(canvas, () => resize())
  if (!renderer.current) return () => {}
  const coarse = matchMedia('(hover: none), (pointer: coarse)')
  let frame = 0
  let width = 0, height = 0, ratio = 1
  let x = -200, y = -200, targetX = -200, targetY = -200
  let strength = 0, targetStrength = 0
  let destroyed = false
  function draw() {
    const dots = renderer.current
    dots.begin(width, height, ratio, getComputedStyle(zone).color)
    const reach = 92
    for (let py = 9; py < height; py += 12) {
      for (let px = 9; px < width; px += 12) {
        const distance = Math.hypot(px - x, py - y)
        const pull = !reducedMotion() && distance < reach ? (1 - distance / reach) ** 2 * strength : 0
        dots.dot(px + (x - px) * pull * 0.065, py + (y - py) * pull * 0.065, 0.65 + pull * 0.8, 0.13 + pull * 0.23)
      }
    }
    dots.end()
    const leanX = !reducedMotion() ? (x - width / 2) / Math.max(width, 1) * strength * 3 : 0
    const leanY = !reducedMotion() ? (y - height / 2) / Math.max(height, 1) * strength * 3 : 0
    zone.style.setProperty('--drop-x', `${leanX.toFixed(2)}px`)
    zone.style.setProperty('--drop-y', `${leanY.toFixed(2)}px`)
  }
  function tick() {
    frame = 0
    if (destroyed) return
    x += (targetX - x) * 0.22
    y += (targetY - y) * 0.22
    strength += (targetStrength - strength) * 0.18
    draw()
    if (Math.abs(targetX - x) > 0.2 || Math.abs(targetY - y) > 0.2 || Math.abs(targetStrength - strength) > 0.005) frame = requestAnimationFrame(tick)
  }
  function schedule() { if (!frame && !destroyed) frame = requestAnimationFrame(tick) }
  function resize() {
    width = zone.clientWidth
    height = zone.clientHeight
    ratio = Math.min(devicePixelRatio || 1, 2)
    renderer.current.canvas.width = Math.round(width * ratio)
    renderer.current.canvas.height = Math.round(height * ratio)
    draw()
  }
  function move(event) {
    if (coarse.matches || reducedMotion()) return
    const box = zone.getBoundingClientRect()
    targetX = event.clientX - box.left
    targetY = event.clientY - box.top
    targetStrength = 1
    schedule()
  }
  function leave() { targetStrength = 0; schedule() }
  const resizeObserver = new ResizeObserver(resize)
  resizeObserver.observe(zone)
  const appearance = new MutationObserver(() => { targetStrength = 0; strength = 0; draw() })
  appearance.observe(document.documentElement, { attributes: true, attributeFilter: ['data-theme', 'data-motion'] })
  const themeQuery = matchMedia('(prefers-color-scheme: dark)')
  themeQuery.addEventListener('change', resize)
  zone.addEventListener('pointermove', move)
  zone.addEventListener('pointerleave', leave)
  resize()
  return () => {
    destroyed = true
    cancelAnimationFrame(frame)
    renderer.destroy()
    resizeObserver.disconnect()
    appearance.disconnect()
    themeQuery.removeEventListener('change', resize)
    zone.removeEventListener('pointermove', move)
    zone.removeEventListener('pointerleave', leave)
  }
}
