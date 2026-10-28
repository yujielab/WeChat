// The segmented rail borrows the rhythm of an OTP control while the original
// input keeps normal editing, IME, paste, autofill and arbitrary code lengths.
import { h, reducedMotion } from './dom.js'

export function enhanceInviteInput(input) {
  const rail = h('span', { class: 'invite-code-rail', 'aria-hidden': 'true' })
  const segments = Array.from({ length: 8 }, () => h('i'))
  rail.append(...segments)
  const el = h('div', { class: 'invite-code', dataset: { state: 'idle' } })
  input.before(el)
  el.append(input, rail)
  input.classList.add('invite-code-input')
  let state = 'idle'
  let animation = null
  let composing = false
  let destroyed = false

  function update() {
    if (destroyed) return
    const length = input.value.length
    const caret = input.selectionStart ?? length
    // Relative caret position is visual only: eight strokes are not a length
    // requirement and never consume, trim or transform the actual value.
    const active = length ? Math.min(7, Math.floor(caret / length * 7)) : 0
    segments.forEach((segment, index) => {
      segment.classList.toggle('is-current', index === active)
    })
    el.classList.toggle('has-value', length > 0)
    el.classList.toggle('is-focused', document.activeElement === input)
  }
  function changed() {
    if (state === 'error') setState('idle')
    update()
    if (composing || reducedMotion()) return
    animation?.cancel()
    animation = rail.animate?.(
      [{ transform: 'rotateX(-28deg)', opacity: .55 }, { transform: 'rotateX(0)', opacity: 1 }],
      { duration: 280, easing: 'cubic-bezier(.22,1,.36,1)' })
  }
  const compositionStart = () => { composing = true }
  const compositionEnd = () => { composing = false; changed() }
  input.addEventListener('input', changed)
  input.addEventListener('focus', update)
  input.addEventListener('blur', update)
  input.addEventListener('keyup', update)
  input.addEventListener('click', update)
  input.addEventListener('select', update)
  input.addEventListener('compositionstart', compositionStart)
  input.addEventListener('compositionend', compositionEnd)

  function setState(next) {
    if (destroyed) return
    state = ['idle', 'pending', 'error'].includes(next) ? next : 'idle'
    el.dataset.state = state
    if (state === 'error') input.setAttribute('aria-invalid', 'true')
    else input.removeAttribute('aria-invalid')
    update()
  }
  function destroy() {
    if (destroyed) return
    destroyed = true
    animation?.cancel()
    input.removeEventListener('input', changed)
    input.removeEventListener('focus', update)
    input.removeEventListener('blur', update)
    input.removeEventListener('keyup', update)
    input.removeEventListener('click', update)
    input.removeEventListener('select', update)
    input.removeEventListener('compositionstart', compositionStart)
    input.removeEventListener('compositionend', compositionEnd)
    input.classList.remove('invite-code-input')
    input.removeAttribute('aria-invalid')
    el.replaceWith(input)
  }
  update()
  return { el, setState, destroy }
}
