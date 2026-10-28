// Account gate: the same paper, ink and tactile controls as the messenger.
import { h, icon, stagger, reducedMotion } from '../ui/dom.js'
import { haptic } from '../ui/haptics.js'
import { createHalftone } from '../ui/halftone.js'
import { enhanceInviteInput } from '../ui/invite-code.js'

function mark() {
  return h('span', { class: 'duo-mark', 'aria-hidden': 'true' }, icon('bubble'), icon('bubble'))
}

export function renderAuth(app, { needsCode = false, onSuccess }) {
  let mode = 'login'
  let pending = false
  let modeAnimation = null
  let cardAnimation = null
  let errorAnimation = null
  const title = h('h1', {})
  const lead = h('p', { class: 'lead' })
  const username = field({ id: 'u', type: 'text', label: '用户名', placeholder: '输入你的用户名', autocomplete: 'username', enterkeyhint: 'next' })
  username.input.required = true
  username.input.maxLength = 24
  const display = field({ id: 'd', type: 'text', label: '昵称', optional: true, placeholder: '朋友看到的名字', autocomplete: 'nickname', enterkeyhint: 'next' })
  const password = field({ id: 'p', type: 'password', label: '密码', placeholder: '至少 6 位', autocomplete: 'current-password', enterkeyhint: 'go' })
  password.input.required = true
  password.input.minLength = 6
  const showPassword = h('button', { class: 'password-toggle', type: 'button', 'aria-label': '显示密码', 'aria-pressed': 'false' }, '显示')
  password.well.append(showPassword)
  showPassword.addEventListener('click', () => {
    const show = password.input.type === 'password'
    password.input.type = show ? 'text' : 'password'
    showPassword.textContent = show ? '隐藏' : '显示'
    showPassword.setAttribute('aria-label', show ? '隐藏密码' : '显示密码')
    showPassword.setAttribute('aria-pressed', String(show))
  })
  const code = field({ id: 'c', type: 'text', label: '邀请码', placeholder: '输入你的邀请码', autocomplete: 'off', enterkeyhint: 'go' })
  const invite = enhanceInviteInput(code.input)
  const error = h('div', { class: 'field-error', role: 'alert', id: 'auth-error' })
  const submitLabel = h('span')
  const submit = h('button', { class: 'btn primary solid-press auth-submit', type: 'submit' }, submitLabel, icon('chevron-right'))
  const form = h('form', { class: 'auth-form', 'aria-describedby': 'auth-error' }, username.wrap, display.wrap, password.wrap, code.wrap, error, submit)
  const loginTab = h('button', { type: 'button', class: 'auth-tab', 'aria-pressed': 'true' }, '登录')
  const registerTab = h('button', { type: 'button', class: 'auth-tab', 'aria-pressed': 'false' }, '创建账号')
  const tabs = h('div', { class: 'auth-tabs', role: 'group', 'aria-label': '账号操作' }, h('span', { class: 'auth-tab-indicator', 'aria-hidden': 'true' }), loginTab, registerTab)
  const switchBtn = h('button', { type: 'button' })
  const foot = h('div', { class: 'auth-foot' }, switchBtn)
  const card = h('section', { class: 'auth-card', 'aria-label': 'Duo 账号' },
    tabs, h('div', { class: 'auth-heading' }, title, lead), form, foot,
    h('div', { class: 'auth-privacy' }, icon('lock'), '只用一个账号，和在意的人保持联系'))
  const art = h('div', { class: 'auth-art' },
    h('div', { class: 'auth-art-caption' }, 'A LITTLE CLOSER'),
    createHalftone())
  const story = h('section', { class: 'auth-story' },
    h('p', { class: 'auth-eyebrow' }, '为每一份亲近而设计'),
    h('h2', {}, '小事，也值得', h('br'), '好好聊。'),
    h('p', { class: 'auth-story-copy' }, '把日常说给在意的人听。', h('br'), '一句消息，一笔涂鸦，一次见面。'), art,
    h('div', { class: 'auth-features' },
      h('span', {}, icon('bubble'), '即时聊天'), h('span', {}, icon('brush'), '随手画'), h('span', {}, icon('video'), '语音与视频')))
  const main = h('main', { class: 'auth', dataset: { mode } },
    h('header', { class: 'auth-brand' }, h('div', { class: 'duo-wordmark' }, mark(), h('span', {}, 'Duo')), h('span', { class: 'auth-brand-note' }, '更近一点。')),
    h('div', { class: 'auth-layout' }, story, card),
    h('footer', { class: 'auth-colophon' }, 'Duo', h('span', {}, '让聊天回到聊天。')))
  const parts = [main.querySelector('.auth-brand'), story, card, main.querySelector('.auth-colophon')]
  for (const part of parts) part.classList.add('reveal')
  stagger(parts)
  app.replaceChildren(main)

  function apply() {
    const reg = mode === 'register'
    main.dataset.mode = mode
    title.textContent = reg ? '从一句你好开始。' : '欢迎回来。'
    lead.textContent = reg ? '创建你的 Duo 账号，把朋友带到身边。' : '登录 Duo，接着聊。'
    display.wrap.hidden = !reg
    display.input.disabled = !reg
    code.wrap.hidden = !(reg && needsCode)
    code.input.disabled = !(reg && needsCode)
    code.input.required = reg && needsCode
    password.input.autocomplete = reg ? 'new-password' : 'current-password'
    submitLabel.textContent = reg ? '创建账号' : '登录 Duo'
    switchBtn.textContent = reg ? '已有账号？去登录' : '第一次来？创建一个账号'
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
        { duration: 400, easing: 'cubic-bezier(.32,.72,0,1)' })
      modeAnimation = form.animate?.(
        [{ opacity: 0.35, transform: 'translateY(5px)' }, { opacity: 1, transform: 'none' }],
        { duration: 260, easing: 'cubic-bezier(.22,1,.36,1)' })
    }
    if (document.activeElement === switchBtn) (mode === 'login' ? loginTab : registerTab).focus({ preventScroll: true })
  }
  loginTab.addEventListener('click', () => setMode('login'))
  registerTab.addEventListener('click', () => setMode('register'))
  switchBtn.addEventListener('click', () => setMode(mode === 'login' ? 'register' : 'login'))
  for (const input of [username.input, password.input, display.input, code.input]) input.addEventListener('input', () => { error.textContent = '' })
  apply()

  form.addEventListener('submit', async e => {
    e.preventDefault()
    if (pending) return
    const u = username.input.value.trim(), p = password.input.value
    if (!u || !p) return
    pending = true
    invite.setState(mode === 'register' && needsCode ? 'pending' : 'idle')
    submit.disabled = loginTab.disabled = registerTab.disabled = switchBtn.disabled = true
    main.classList.add('is-submitting')
    submit.replaceChildren(h('span', { class: 'spinner' }), h('span', {}, mode === 'register' ? '正在创建账号…' : '正在登录…'))
    error.textContent = ''
    try {
      const res = await fetch(mode === 'register' ? '/auth/register' : '/auth/login', {
        method: 'POST', headers: { 'content-type': 'application/json' }, credentials: 'same-origin',
        body: JSON.stringify(mode === 'register'
          ? { username: u, password: p, display: display.input.value.trim(), code: code.input.value.trim() }
          : { username: u, password: p })
      })
      const data = await res.json().catch(() => ({}))
      if (!res.ok || !data.ok) throw new Error(data.error || '暂时无法完成，请稍后重试')
      submit.replaceChildren(icon('check'), h('span', {}, '准备好了'))
      onSuccess(data.me)
    } catch (err) {
      invite.setState('idle')
      haptic()
      error.textContent = err instanceof TypeError ? '暂时无法连接，请检查网络后重试。' : err.message
      errorAnimation?.cancel()
      if (!reducedMotion()) errorAnimation = form.animate?.(
        [{ transform: 'translateX(0)' }, { transform: 'translateX(-5px)' }, { transform: 'translateX(4px)' }, { transform: 'translateX(0)' }],
        { duration: 280, easing: 'ease-out' })
      pending = false
      submit.disabled = loginTab.disabled = registerTab.disabled = switchBtn.disabled = false
      main.classList.remove('is-submitting')
      submit.replaceChildren(submitLabel, icon('chevron-right'))
    }
  })
}

function field({ id, type, label, optional, placeholder, autocomplete, enterkeyhint }) {
  const input = h('input', { class: 'input', type, id: `auth-${id}`, name: id, placeholder, autocomplete, enterkeyhint, autocapitalize: 'off', autocorrect: 'off', spellcheck: false })
  const well = h('div', { class: 'auth-input-well' }, input)
  const wrap = h('div', { class: 'auth-field' }, h('label', { class: 'auth-label', for: `auth-${id}` }, label, optional ? h('span', {}, '可选') : null), well)
  return { wrap, well, input }
}
