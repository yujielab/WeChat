// Account gate: the app's name, then sign in or create an account, with the
// same paper, ink and tactile controls as the messenger.
import { h, stagger, reducedMotion } from '../ui/dom.js'
import { haptic } from '../ui/haptics.js'
import { enhanceInviteInput } from '../ui/invite-code.js'

export function renderAuth(app, { needsCode = false, onSuccess }) {
  let mode = 'login'
  let pending = false
  let modeAnimation = null
  let cardAnimation = null
  let errorAnimation = null
  const username = field({ id: 'u', type: 'text', label: 'Username', autocomplete: 'username', enterkeyhint: 'next' })
  username.input.required = true
  username.input.maxLength = 24
  const display = field({ id: 'd', type: 'text', label: 'Display name', optional: true, autocomplete: 'nickname', enterkeyhint: 'next' })
  const password = field({ id: 'p', type: 'password', label: 'Password', autocomplete: 'current-password', enterkeyhint: 'go' })
  password.input.required = true
  password.input.minLength = 6
  const showPassword = h('button', { class: 'password-toggle', type: 'button', 'aria-label': 'Show password', 'aria-pressed': 'false' }, 'Show')
  password.well.append(showPassword)
  showPassword.addEventListener('click', () => {
    const show = password.input.type === 'password'
    password.input.type = show ? 'text' : 'password'
    showPassword.textContent = show ? 'Hide' : 'Show'
    showPassword.setAttribute('aria-label', show ? 'Hide password' : 'Show password')
    showPassword.setAttribute('aria-pressed', String(show))
  })
  const code = field({ id: 'c', type: 'text', label: 'Invite code', autocomplete: 'off', enterkeyhint: 'go' })
  const invite = enhanceInviteInput(code.input)
  const error = h('div', { class: 'field-error', role: 'alert', id: 'auth-error' })
  const submitLabel = h('span')
  const submit = h('button', { class: 'btn primary solid-press auth-submit', type: 'submit' }, submitLabel)
  const form = h('form', { class: 'auth-form', 'aria-describedby': 'auth-error' }, username.wrap, display.wrap, password.wrap, code.wrap, error, submit)
  const loginTab = h('button', { type: 'button', class: 'auth-tab', 'aria-pressed': 'true' }, 'Log in')
  const registerTab = h('button', { type: 'button', class: 'auth-tab', 'aria-pressed': 'false' }, 'Sign up')
  const tabs = h('div', { class: 'auth-tabs', role: 'group', 'aria-label': 'Account' }, h('span', { class: 'auth-tab-indicator', 'aria-hidden': 'true' }), loginTab, registerTab)
  // The tabs say which form this is.
  const name = h('h1', { class: 'auth-name' }, 'Cuven')
  const card = h('section', { class: 'auth-card', 'aria-label': 'Account' }, tabs, form)
  const main = h('main', { class: 'auth', dataset: { mode } }, h('div', { class: 'auth-layout' }, name, card))
  const parts = [name, card]
  for (const part of parts) part.classList.add('reveal')
  stagger(parts)
  app.replaceChildren(main)

  function apply() {
    const reg = mode === 'register'
    main.dataset.mode = mode
    display.wrap.hidden = !reg
    display.input.disabled = !reg
    code.wrap.hidden = !(reg && needsCode)
    code.input.disabled = !(reg && needsCode)
    code.input.required = reg && needsCode
    password.input.autocomplete = reg ? 'new-password' : 'current-password'
    password.input.placeholder = reg ? 'At least 6 characters' : ''
    submitLabel.textContent = reg ? 'Sign up' : 'Log in'
    loginTab.setAttribute('aria-pressed', String(!reg))
    registerTab.setAttribute('aria-pressed', String(reg))
    error.textContent = ''
    invite.setState('idle')
  }
  function setMode(next) {
    if (pending || next === mode) return
    const before = card.getBoundingClientRect()
    cardAnimation?.cancel()
    mode = next
    modeAnimation?.cancel()
    apply()
    if (!reducedMotion()) {
      const after = card.getBoundingClientRect()
      cardAnimation = card.animate?.(
        [{ height: `${before.height}px`, transform: `translateY(${before.top - after.top}px)` }, { height: `${after.height}px`, transform: 'none' }],
        { duration: 320, easing: 'cubic-bezier(.32,.72,0,1)' })
      modeAnimation = form.animate?.(
        [{ opacity: 0.35, transform: 'translateY(5px)' }, { opacity: 1, transform: 'none' }],
        { duration: 260, easing: 'cubic-bezier(.22,1,.36,1)' })
    }
  }
  loginTab.addEventListener('click', () => setMode('login'))
  registerTab.addEventListener('click', () => setMode('register'))
  for (const input of [username.input, password.input, display.input, code.input]) input.addEventListener('input', () => { error.textContent = ''; input.removeAttribute('aria-invalid') })
  apply()

  form.addEventListener('submit', async e => {
    e.preventDefault()
    if (pending) return
    const u = username.input.value.trim(), p = password.input.value
    if (!u || !p) return
    pending = true
    invite.setState(mode === 'register' && needsCode ? 'pending' : 'idle')
    submit.disabled = loginTab.disabled = registerTab.disabled = true
    main.classList.add('is-submitting')
    submit.replaceChildren(h('span', { class: 'spinner' }), h('span', {}, mode === 'register' ? 'Creating account…' : 'Logging in…'))
    error.textContent = ''
    for (const f of [username, password, display, code]) f.input.removeAttribute('aria-invalid')
    try {
      const res = await fetch(mode === 'register' ? '/auth/register' : '/auth/login', {
        method: 'POST', headers: { 'content-type': 'application/json' }, credentials: 'same-origin',
        body: JSON.stringify(mode === 'register'
          ? { username: u, password: p, display: display.input.value.trim(), code: code.input.value.trim() }
          : { username: u, password: p })
      })
      const data = await res.json().catch(() => ({}))
      if (!res.ok || !data.ok) throw new Error(data.error || 'Something went wrong, please try again later')
      onSuccess(data.me)
    } catch (err) {
      invite.setState('idle')
      haptic()
      error.textContent = err instanceof TypeError ? 'Can\'t connect, check your network and try again.' : err.message
      errorAnimation?.cancel()
      if (!reducedMotion()) errorAnimation = form.animate?.(
        [{ transform: 'translateX(0)' }, { transform: 'translateX(-5px)' }, { transform: 'translateX(4px)' }, { transform: 'translateX(0)' }],
        { duration: 280, easing: 'ease-out' })
      pending = false
      submit.disabled = loginTab.disabled = registerTab.disabled = false
      main.classList.remove('is-submitting')
      submit.replaceChildren(submitLabel)
      // Focus goes where the fix is (UX audit P2-5): the password after a
      // refused sign-in, marked invalid; the button again when the network failed.
      if (err instanceof TypeError) submit.focus({ preventScroll: true })
      else {
        const msg = String(err?.message || '')
        const at = /invite code/i.test(msg) && !code.wrap.hidden ? code : /username(?! or password)|display name/i.test(msg) ? username : password
        at.input.setAttribute('aria-invalid', 'true')
        at.input.setAttribute('aria-describedby', 'auth-error')
        at.input.focus({ preventScroll: true })
        at.input.select?.()
      }
    }
  })
}

function field({ id, type, label, optional, placeholder, autocomplete, enterkeyhint }) {
  const input = h('input', { class: 'input', type, id: `auth-${id}`, name: id, placeholder, autocomplete, enterkeyhint, autocapitalize: 'off', autocorrect: 'off', spellcheck: false })
  const well = h('div', { class: 'auth-input-well' }, input)
  const wrap = h('div', { class: 'auth-field' }, h('label', { class: 'auth-label', for: `auth-${id}` }, label, optional ? h('span', {}, 'Optional') : null), well)
  return { wrap, well, input }
}
