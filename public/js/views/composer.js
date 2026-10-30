// Message composer: a field that grows with its lines and one button after
// it. Empty, the button adds a photo or a drawing: it opens into a small
// panel grown out of the button itself, its + turning into ×. With text it
// becomes Send in the same place. Enter sends (the keyboard shows 发送),
// except while a Chinese IME is composing; Shift+Enter inserts a newline.

import { h, icon } from '../ui/dom.js'
import { haptic } from '../ui/haptics.js'
import { getDraft, setDraft } from '../store.js'
import { openAttachments } from './attachments.js'

// The field shows up to five lines, fewer when the window is short, then
// scrolls inside.
const MAX_LINES = 5
let panelIds = 0

export function createComposer({ onSend, onImages, onHeight, onType, tools = [] }) {
  const textarea = h('textarea', {
    rows: 1,
    placeholder: '消息',
    'aria-label': '消息',
    enterkeyhint: 'send',
    autocomplete: 'off',
    spellcheck: true
  })
  // Measures the text at the field's width without touching the live
  // editor, so its caret, selection and IME composition never jump.
  const twin = h('div', { class: 'field-twin', 'aria-hidden': 'true' })
  const field = h('div', { class: 'field glass' }, textarea, twin)

  const panelId = `composer-tools-${++panelIds}`
  const toolButtons = new Map()
  const panelBody = h('div', { class: 'composer-panel-body' }, ...tools.map(tool => {
    const button = h('button', { class: 'composer-tool', type: 'button', role: 'menuitem', dataset: { tool: tool.id } },
      icon(tool.icon), h('span', { class: 'label' }, tool.title))
    button.addEventListener('click', () => {
      // Focus goes back to the button before the panel turns inert, so it
      // is never stranded on the page.
      setOpen(false)
      tool.onSelect?.()
    })
    toolButtons.set(tool.id, button)
    return button
  }))
  const panel = h('div', { class: 'composer-panel', id: panelId, role: 'menu', 'aria-label': '添加' }, panelBody)
  const action = h('button', {
    class: 'composer-action',
    type: 'button',
    'aria-label': '添加照片或手绘',
    'aria-haspopup': 'menu',
    'aria-expanded': 'false',
    'aria-controls': panelId
  }, icon('plus', 'action-add'), icon('arrow-up', 'action-send'))
  const form = h('form', { class: 'composer', autocomplete: 'off' }, field, action, panel)

  let chat = null
  let draftTimer = 0
  let readonly = false
  let attachmentSheet = null
  let docked = null
  let open = false
  let hasText = false

  function openImages(files = []) {
    if (readonly || !chat) return false
    if (attachmentSheet && !attachmentSheet.closed) {
      attachmentSheet.addFiles(files)
      return attachmentSheet
    }
    const destination = chat
    attachmentSheet = openAttachments({
      files,
      onSend: (selected, options) => {
        if (readonly || chat !== destination) return false
        return onImages?.(selected, options)
      }
    })
    return attachmentSheet
  }

  // ------------------------------------------------------------ the field
  function lineHeight() {
    const cs = getComputedStyle(textarea)
    return parseFloat(cs.lineHeight) || 1.45 * parseFloat(cs.fontSize)
  }
  function autosize() {
    const cs = getComputedStyle(textarea)
    twin.style.width = `${textarea.clientWidth}px`
    twin.style.font = cs.font
    twin.style.letterSpacing = cs.letterSpacing
    twin.style.padding = cs.padding
    // A zero-width space keeps a trailing newline's empty line.
    twin.textContent = `${textarea.value}\u200b`
    const pad = parseFloat(cs.paddingTop) + parseFloat(cs.paddingBottom)
    const line = lineHeight()
    const room = (window.visualViewport?.height || window.innerHeight) * 0.3
    const lines = Math.max(2, Math.min(MAX_LINES, Math.floor((room - pad) / line)))
    const height = Math.min(twin.scrollHeight, lines * line + pad)
    textarea.style.height = `${Math.ceil(height)}px`
    field.classList.toggle('multiline', twin.scrollHeight > line + pad + 2)
    setHasText(textarea.value.trim().length > 0)
  }

  // ------------------------------------------------------------ the button
  // One button, two jobs: it always holds its place, and only its symbol and
  // fill change.
  function setHasText(next) {
    if (next === hasText && action.disabled === readonly) return
    hasText = next
    if (hasText && open) setOpen(false, { focus: false })
    form.classList.toggle('has-text', hasText)
    action.disabled = readonly
    action.type = hasText ? 'submit' : 'button'
    action.setAttribute('aria-label', hasText ? '发送' : '添加照片或手绘')
    if (hasText) {
      action.removeAttribute('aria-haspopup')
      action.removeAttribute('aria-expanded')
    } else {
      action.setAttribute('aria-haspopup', 'menu')
      action.setAttribute('aria-expanded', String(open))
    }
  }

  // The panel grows out of the button and shrinks back into it. Toggling
  // mid-way turns it around from where it is (CSS transitions retarget).
  function setOpen(next, { focus = true } = {}) {
    if (next === open || (next && (hasText || readonly))) return
    open = next
    if (open) {
      // Open toward the room there is: up from the foot of the screen, down
      // when the bar sits just under a fold.
      const r = action.getBoundingClientRect()
      const fold = document.documentElement.dataset.fold === 'horizontal'
      const ceiling = fold ? parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--fold-end')) || 0 : 0
      form.classList.toggle('panel-down', r.top - ceiling < panelBody.scrollHeight + 8)
    }
    form.classList.toggle('panel-open', open)
    action.setAttribute('aria-expanded', String(open))
    panel.inert = !open
    if (open) {
      document.addEventListener('pointerdown', onOutside, true)
      if (focus) toolButtons.values().next().value?.focus({ preventScroll: true })
    } else {
      document.removeEventListener('pointerdown', onOutside, true)
      if (focus && panel.contains(document.activeElement)) action.focus({ preventScroll: true })
    }
  }
  function onOutside(e) {
    if (!form.contains(e.target)) setOpen(false, { focus: false })
  }
  panel.inert = true

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
    onType?.('')
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
  action.addEventListener('click', e => {
    if (hasText) return // the form's submit sends
    e.preventDefault()
    // Opened from the keyboard, focus goes into the panel; from a tap it
    // stays where it was, so the keyboard doesn't drop.
    setOpen(!open, { focus: e.detail === 0 })
  })
  form.addEventListener('keydown', e => {
    if (e.key === 'Escape' && open) {
      e.preventDefault()
      e.stopPropagation()
      setOpen(false)
    }
  })
  // Keep focus in the field when tapping the button, so the keyboard doesn't drop.
  action.addEventListener('pointerdown', e => { if (document.activeElement === textarea) e.preventDefault() })
  action.addEventListener('mousedown', e => { if (document.activeElement === textarea) e.preventDefault() })
  textarea.addEventListener('focus', () => form.classList.add('is-focused'))
  textarea.addEventListener('blur', () => form.classList.remove('is-focused'))

  // The border box: the keyboard changes only the bar's bottom padding.
  new ResizeObserver(() => onHeight?.(form.offsetHeight)).observe(form, { box: 'border-box' })
  // A new width rewraps the text; a new height changes how many lines fit.
  let lastWidth = 0
  new ResizeObserver(() => {
    if (textarea.clientWidth === lastWidth) return
    lastWidth = textarea.clientWidth
    autosize()
  }).observe(field)
  window.visualViewport?.addEventListener('resize', () => autosize())

  return {
    el: form,
    setChat(id, { readonly: ro = false } = {}) {
      attachmentSheet?.close()
      setOpen(false, { focus: false })
      if (chat && chat !== id) {
        clearTimeout(draftTimer)
        setDraft(chat, textarea.value)
      }
      chat = id
      readonly = ro
      form.classList.toggle('readonly', ro)
      textarea.disabled = ro
      textarea.placeholder = ro ? '无法发送消息' : '消息'
      textarea.value = id ? getDraft(id) : ''
      // A different conversation's draft takes its height at once.
      field.classList.add('no-grow')
      autosize()
      requestAnimationFrame(() => field.classList.remove('no-grow'))
    },
    flushDraft() {
      if (chat) setDraft(chat, textarea.value)
    },
    openImages,
    /** Show which tool's surface is open (the drawing board in the next column). */
    setTool(id, active) {
      const button = toolButtons.get(id)
      if (!button) return
      button.classList.toggle('active', Boolean(active))
      button.setAttribute('aria-checked', String(Boolean(active)))
    },
    closeTools() { setOpen(false, { focus: false }) },
    /** Carry a bar section beside the field (horizontal bars), or release it. */
    dock(section) {
      if (section === docked) return
      if (docked?.parentElement === form && !section) docked.remove()
      docked = section
      if (section) form.prepend(section)
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
