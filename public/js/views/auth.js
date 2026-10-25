// Account gate: log in or register with a username and password. White card,
// staggered blur-up entrance (same language as the rest of the app).

import { h, icon, stagger } from '../ui/dom.js'
import { haptic } from '../ui/haptics.js'

function appIcon() {
  return h('div', { class: 'app-icon', 'aria-hidden': 'true' }, icon('bubble'))
}
function reveal(...els) {
  for (const el of els) el.classList.add('reveal')
  stagger(els)
}

export function renderAuth(app, { needsCode = false, onSuccess }) {
  let mode = 'login' // login | register

  const title = h('h1', {})
  const lead = h('p', { class: 'lead' })

  const username = field({ id: 'u', type: 'text', label: '用户名', placeholder: '用户名', autocomplete: 'username', enterkeyhint: 'next' })
  const display = field({ id: 'd', type: 'text', label: '昵称（可选）', placeholder: '昵称（别人看到的名字）', autocomplete: 'nickname', enterkeyhint: 'next' })
  const password = field({ id: 'p', type: 'password', label: '密码', placeholder: '密码', autocomplete: 'current-password', enterkeyhint: 'go' })
  const code = field({ id: 'c', type: 'text', label: '邀请码', placeholder: '邀请码', autocomplete: 'off', enterkeyhint: 'go' })

  const error = h('div', { class: 'field-error', role: 'alert' })
  const submit = h('button', { class: 'btn primary solid-press', type: 'submit' })
  const form = h('form', { class: 'auth-form' }, username.wrap, display.wrap, password.wrap, code.wrap, error, submit)

  const switchBtn = h('button', { type: 'button' })
  const foot = h('div', { class: 'auth-foot' }, switchBtn)

  const card = h('div', { class: 'auth-card' })
  const parts = [appIcon(), title, lead, form, foot]
  reveal(...parts)
  card.append(...parts)
  app.replaceChildren(h('main', { class: 'auth' }, card))

  function apply() {
    const reg = mode === 'register'
    title.textContent = reg ? '创建账号' : '登录'
    lead.textContent = reg ? '设置用户名和密码，别人用你的用户名就能找到你。' : '用你的用户名和密码登录。'
    display.wrap.hidden = !reg
    code.wrap.hidden = !(reg && needsCode)
    password.input.setAttribute('autocomplete', reg ? 'new-password' : 'current-password')
    submit.replaceChildren(reg ? '注册并进入' : '登录')
    switchBtn.textContent = reg ? '已有账号？去登录' : '还没有账号？创建一个'
    error.textContent = ''
    username.clear(); password.clear()
  }
  switchBtn.addEventListener('click', () => { mode = mode === 'login' ? 'register' : 'login'; apply(); username.input.focus() })
  apply()

  form.addEventListener('submit', async e => {
    e.preventDefault()
    const u = username.input.value.trim()
    const p = password.input.value
    if (!u || !p) return
    submit.disabled = true
    submit.replaceChildren(h('span', { class: 'spinner' }), mode === 'register' ? '注册中' : '登录中')
    const path = mode === 'register' ? '/auth/register' : '/auth/login'
    const body = mode === 'register'
      ? { username: u, password: p, display: display.input.value.trim(), code: code.input.value.trim() }
      : { username: u, password: p }
    try {
      const res = await fetch(path, {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        credentials: 'same-origin',
        body: JSON.stringify(body)
      })
      const data = await res.json().catch(() => ({}))
      if (!res.ok || !data.ok) throw new Error(data.error || '操作失败')
      onSuccess(data.me)
    } catch (err) {
      haptic()
      error.textContent = err.message
      card.animate?.(
        [{ transform: 'translateX(0)' }, { transform: 'translateX(-8px)' }, { transform: 'translateX(7px)' }, { transform: 'translateX(-4px)' }, { transform: 'translateX(0)' }],
        { duration: 360, easing: 'ease-out' }
      )
      submit.disabled = false
      apply.restore?.()
      submit.replaceChildren(mode === 'register' ? '注册并进入' : '登录')
    }
  })

  if (!matchMedia('(pointer: coarse)').matches) username.input.focus()
}

function field({ id, type, label, placeholder, autocomplete, enterkeyhint }) {
  const input = h('input', {
    class: 'input', type, id: `auth-${id}`, name: id,
    placeholder, autocomplete, enterkeyhint,
    autocapitalize: 'off', autocorrect: 'off', spellcheck: false
  })
  const wrap = h('div', { class: 'auth-field' }, h('label', { class: 'sr-only', for: `auth-${id}` }, label), input)
  return { wrap, input, clear: () => { input.value = '' } }
}
