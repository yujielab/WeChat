// Message composer: glass "+" button and capsule field with a send button that
// morphs in when there's text. Enter sends (the keyboard shows 发送), except
// while a Chinese IME is composing; Shift+Enter inserts a newline.

import { h, icon } from '../ui/dom.js'
import { haptic } from '../ui/haptics.js'
import { getDraft, setDraft } from '../store.js'
import { openMenu } from './overlay.js'

export function createComposer({ onSend, onImages, onHeight, onType, onDraw }) {
  const textarea = h('textarea', {
    rows: 1,
    placeholder: '消息',
    'aria-label': '消息',
    enterkeyhint: 'send',
    autocomplete: 'off',
    spellcheck: true
  })
  const send = h('button', { class: 'send', type: 'submit', 'aria-label': '发送' }, icon('arrow-up'))
  const field = h('div', { class: 'field glass' }, textarea, send)
  const fileInput = h('input', { type: 'file', accept: 'image/*', multiple: true, hidden: true })
  const attach = h('button', { class: 'attach glass glass-btn', type: 'button', 'aria-label': '添加内容' }, icon('plus'))
  const form = h('form', { class: 'composer', autocomplete: 'off' }, attach, field, fileInput)

  let chat = null
  let draftTimer = 0
  let readonly = false

  function autosize() {
    textarea.style.height = 'auto'
    textarea.style.height = `${Math.min(textarea.scrollHeight, 6 * 1.32 * parseFloat(getComputedStyle(textarea).fontSize) + 10)}px`
    form.classList.toggle('has-text', textarea.value.trim().length > 0)
  }

  function saveDraftSoon() {
    clearTimeout(draftTimer)
    const c = chat
    draftTimer = setTimeout(() => c && setDraft(c, textarea.value), 300)
  }

  function submit() {
    const text = textarea.value
    if (!text.trim() || readonly) return
    haptic()
    textarea.value = ''
    autosize()
    clearTimeout(draftTimer)
    if (chat) setDraft(chat, '')
    onSend(text.replace(/\s+$/, ''))
    // Keep the keyboard up for the next message.
    textarea.focus({ preventScroll: true })
  }

  textarea.addEventListener('input', () => {
    autosize()
    saveDraftSoon()
    onType?.(textarea.value)
  })
  textarea.addEventListener('keydown', e => {
    if (e.key !== 'Enter' || e.isComposing || e.keyCode === 229) return
    if (e.shiftKey || e.altKey) return
    e.preventDefault()
    submit()
  })
  form.addEventListener('submit', e => {
    e.preventDefault()
    submit()
  })
  // Keep focus in the field when tapping send, so the keyboard doesn't drop.
  send.addEventListener('pointerdown', e => e.preventDefault())
  send.addEventListener('mousedown', e => e.preventDefault())

  attach.addEventListener('click', () => {
    if (readonly) return
    openMenu(attach, [[
      { label: '照片', icon: 'photo', onSelect: () => { fileInput.value = ''; fileInput.click() } },
      { label: '画板', icon: 'brush', onSelect: () => onDraw?.() }
    ]], { preferAbove: true })
  })
  fileInput.addEventListener('change', () => {
    const files = [...fileInput.files].filter(f => f.type.startsWith('image/'))
    if (files.length) onImages(files)
  })

  new ResizeObserver(() => onHeight?.(form.offsetHeight)).observe(form)

  return {
    el: form,
    setChat(id, { readonly: ro = false } = {}) {
      if (chat && chat !== id) {
        clearTimeout(draftTimer)
        setDraft(chat, textarea.value)
      }
      chat = id
      readonly = ro
      form.classList.toggle('readonly', ro)
      textarea.disabled = ro
      attach.disabled = ro
      textarea.placeholder = '消息'
      textarea.value = id ? getDraft(id) : ''
      autosize()
    },
    flushDraft() {
      if (chat) setDraft(chat, textarea.value)
    },
    focus() {
      textarea.focus({ preventScroll: true })
    },
    blur() {
      textarea.blur()
    },
    get focused() {
      return document.activeElement === textarea
    }
  }
}

/** Downscale and re-encode photos on the phone before upload (HEIC → JPEG, ≤2048px). */
export async function prepareImage(file) {
  if (file.type === 'image/gif') return { file, w: 0, h: 0 }
  try {
    const bmp = await createImageBitmap(file, { imageOrientation: 'from-image' })
    const scale = Math.min(1, 2048 / Math.max(bmp.width, bmp.height))
    const w = Math.round(bmp.width * scale)
    const h = Math.round(bmp.height * scale)
    const canvas = document.createElement('canvas')
    canvas.width = w
    canvas.height = h
    canvas.getContext('2d').drawImage(bmp, 0, 0, w, h)
    bmp.close?.()
    const blob = await new Promise(r => canvas.toBlob(r, 'image/jpeg', 0.86))
    if (!blob) return { file, w, h }
    const name = (file.name || 'photo').replace(/\.[^.]+$/, '') + '.jpg'
    return { file: new File([blob], name, { type: 'image/jpeg' }), w, h }
  } catch {
    return { file, w: 0, h: 0 }
  }
}
