// Input prediction (src/assist.js on the server): while you write, the rest
// of the sentence appears after the caret in grey; in an empty field, a short
// reply to the last message. Tap it, or press Tab or →, to take it; typing on
// replaces it (letters that match it are typed through).
//
// A suggestion stays on this device. It is drawn over the field, never put
// in it, so it reaches the draft — and the live preview the others see — only
// when taken. Only sent messages are read to make one; nobody's live typing
// preview ever is.

import { h, storage } from '../ui/dom.js'
import { api } from '../api.js'
import { state } from '../store.js'

const WAIT_MS = 450
const MAX_DRAFT = 200

export const assistPrefs = () => ({ predict: storage('ui:predict') !== 'off', keys: storage('ui:keys') !== 'off' })
export function setAssistPref(name, on) {
  storage(`ui:${name}`, on ? null : 'off')
  if (name === 'keys') applyKeysPref()
}
// Key-word marks are always in the text; this decides whether they show.
function applyKeysPref() {
  if (assistPrefs().keys) delete document.documentElement.dataset.keys
  else document.documentElement.dataset.keys = 'off'
}
applyKeysPref()
/** Writing help of this kind, if the server offers it and it isn't switched off here. */
export const assistOn = kind => Boolean(state.assist) && assistPrefs()[kind]

let hints = 0

export function createPredictor({ textarea, field, chat }) {
  const typed = h('span', { class: 'typed' })
  const rest = h('span', { class: 'rest' })
  const layer = h('div', { class: 'field-predict', 'aria-hidden': 'true', hidden: true }, typed, rest)
  // Read out with the field: what is offered, and how to take it.
  const hint = h('span', { class: 'sr-only', id: `predict-hint-${++hints}` })
  field.append(layer, hint)
  textarea.setAttribute('aria-describedby', hint.id)

  let shown = ''          // the suggestion on screen
  let base = null         // the draft it continues
  let timer = 0
  let asking = null
  let composing = false
  const cache = new Map()
  const replied = new Set() // last messages already offered a reply

  const atEnd = () => textarea.selectionStart === textarea.value.length && textarea.selectionEnd === textarea.value.length

  function draw() {
    const on = Boolean(shown) && document.activeElement === textarea && atEnd() && !composing
    layer.hidden = !on
    hint.textContent = on ? `建议：${shown}。按 Tab 采用` : ''
    // An empty field's suggestion stands where the placeholder would.
    textarea.classList.toggle('has-prediction', on && !textarea.value)
    if (!on) return
    // Laid over the field's text exactly: same box, font and scroll.
    const cs = getComputedStyle(textarea)
    Object.assign(layer.style, {
      left: `${textarea.offsetLeft}px`,
      top: `${textarea.offsetTop}px`,
      width: `${textarea.clientWidth}px`,
      height: `${textarea.clientHeight}px`,
      font: cs.font,
      letterSpacing: cs.letterSpacing,
      padding: cs.padding
    })
    typed.textContent = textarea.value
    rest.textContent = shown
    layer.scrollTop = textarea.scrollTop
  }

  function clear() {
    shown = ''
    base = null
    clearTimeout(timer)
    asking?.abort()
    asking = null
    draw()
  }

  // The last message is someone else's, and hasn't been offered a reply yet.
  function replyDue(id) {
    const t = state.threads.get(id)
    const last = t?.list?.filter(m => m.type === 'text' && m.status !== 'revoked').at(-1)
    return last && !last.out && !replied.has(last.id) ? last.id : null
  }

  async function ask() {
    const id = chat()
    const draft = textarea.value
    if (!id || !assistOn('predict') || composing || !atEnd() || draft.length > MAX_DRAFT || draft.includes('\n')) return
    if (draft && [...draft.trim()].length < 2) return
    const replyTo = draft ? null : replyDue(id)
    if (!draft && !replyTo) return
    const key = `${id}\u0000${draft}`
    let text = cache.get(key)
    if (text === undefined) {
      asking?.abort()
      const ctl = new AbortController()
      asking = ctl
      try {
        text = (await api.post('/api/ai/suggest', { room: id, draft }, { signal: ctl.signal })).text || ''
      } catch {
        return
      } finally {
        if (asking === ctl) asking = null
      }
      cache.set(key, text)
      if (cache.size > 60) cache.delete(cache.keys().next().value)
    }
    if (replyTo) replied.add(replyTo)
    // Only if the field still holds what was asked about.
    if (chat() !== id || textarea.value !== draft) return
    shown = text
    base = draft
    draw()
  }

  function schedule(delay = WAIT_MS) {
    clearTimeout(timer)
    timer = setTimeout(ask, delay)
  }

  /** The field's text changed (by typing, or a draft loaded). */
  function input() {
    const value = textarea.value
    // Typing what was suggested types through it.
    if (shown && base !== null && value.startsWith(base) && value.length > base.length) {
      const added = value.slice(base.length)
      if (shown.startsWith(added) && shown.length > added.length) {
        shown = shown.slice(added.length)
        base = value
        draw()
        return
      }
    }
    shown = ''
    base = null
    draw()
    if (value) schedule()
  }

  /** Put the suggestion into the field, as if typed. */
  function take() {
    if (!shown || !atEnd()) return false
    const text = shown
    clear()
    textarea.setRangeText(text, textarea.value.length, textarea.value.length, 'end')
    textarea.dispatchEvent(new Event('input', { bubbles: true }))
    return true
  }

  textarea.addEventListener('keydown', e => {
    if (!shown || layer.hidden || e.isComposing) return
    if ((e.key === 'Tab' && !e.shiftKey && !e.altKey && !e.ctrlKey && !e.metaKey) || (e.key === 'ArrowRight' && atEnd())) {
      if (take()) e.preventDefault()
    } else if (e.key === 'Escape') {
      clear()
      e.preventDefault()
      e.stopPropagation()
    }
  })
  // A tap on the grey text takes it; anywhere else in the field is the field's.
  rest.addEventListener('pointerdown', e => {
    e.preventDefault()
    take()
  })
  textarea.addEventListener('compositionstart', () => { composing = true; draw() })
  textarea.addEventListener('compositionend', () => { composing = false; input() })
  textarea.addEventListener('focus', () => {
    draw()
    if (!textarea.value) schedule(120)
  })
  textarea.addEventListener('blur', () => draw())
  textarea.addEventListener('scroll', () => { layer.scrollTop = textarea.scrollTop })
  // Moving the caret off the end hides it; back at the end shows it again.
  document.addEventListener('selectionchange', () => { if (document.activeElement === textarea) draw() })
  new ResizeObserver(() => draw()).observe(textarea)

  return {
    input,
    clear,
    /** A different conversation (or none): nothing carries over. */
    reset() {
      clear()
      if (document.activeElement === textarea && !textarea.value) schedule(120)
    },
    /** Someone else wrote: an empty, focused field may offer a reply. */
    incoming() {
      if (document.activeElement === textarea && !textarea.value) schedule(300)
    },
    get suggestion() { return layer.hidden ? '' : shown }
  }
}
