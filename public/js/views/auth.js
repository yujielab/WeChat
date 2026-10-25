// Password gate (protects this deployment) and the WeChat QR login screen.

import { h, icon, stagger } from '../ui/dom.js'
import { haptic } from '../ui/haptics.js'
import { api } from '../api.js'
import { avatar } from './avatar.js'
import { toast } from './overlay.js'

function appIcon() {
  return h('div', { class: 'app-icon', 'aria-hidden': 'true' }, icon('bubble'))
}

/** Mark a screen's pieces for the staggered blur-up entrance. */
function reveal(...els) {
  for (const el of els) el.classList.add('reveal')
  stagger(els)
}

export function renderSetup(app) {
  const parts = [
    appIcon(),
    h('h1', {}, '还差一步'),
    h('p', { class: 'lead' }, '这个部署还没有设置访问密码。在项目目录运行下面的命令，设置后刷新本页：'),
    h('div', { class: 'auth-error' }, h('code', {}, 'npx wrangler secret put APP_PASSWORD'))
  ]
  reveal(...parts)
  app.replaceChildren(h('main', { class: 'auth' }, h('div', { class: 'auth-card' }, parts)))
}

export function renderGate(app, { onSuccess }) {
  const input = h('input', {
    class: 'input',
    type: 'password',
    id: 'pw',
    name: 'password',
    autocomplete: 'current-password',
    placeholder: '访问密码',
    enterkeyhint: 'go',
    required: true
  })
  const error = h('div', { class: 'field-error', id: 'pw-error', role: 'alert' })
  input.setAttribute('aria-describedby', 'pw-error')
  const button = h('button', { class: 'btn primary solid-press', type: 'submit' }, '继续')
  const form = h('form', { class: 'auth-form' },
    h('label', { class: 'sr-only', for: 'pw' }, '访问密码'), input, error, button)
  const parts = [
    appIcon(),
    h('h1', {}, '微信'),
    h('p', { class: 'lead' }, '这是你的私人客户端。输入访问密码继续。'),
    form
  ]
  reveal(...parts)
  const card = h('div', { class: 'auth-card' }, parts)
  app.replaceChildren(h('main', { class: 'auth' }, card))

  input.addEventListener('input', () => {
    if (input.getAttribute('aria-invalid')) {
      input.removeAttribute('aria-invalid')
      error.textContent = ''
    }
  })
  form.addEventListener('submit', async e => {
    e.preventDefault()
    if (!input.value) return
    button.disabled = true
    button.replaceChildren(h('span', { class: 'spinner' }), '正在验证')
    try {
      const res = await fetch('/auth/login', {
        method: 'POST',
        headers: { 'content-type': 'application/json' },
        body: JSON.stringify({ password: input.value })
      })
      const data = await res.json().catch(() => ({}))
      if (!res.ok || !data.ok) throw new Error(data.error || '登录失败')
      onSuccess()
    } catch (err) {
      haptic()
      input.setAttribute('aria-invalid', 'true')
      error.textContent = err.message
      card.animate?.(
        [{ transform: 'translateX(0)' }, { transform: 'translateX(-8px)' }, { transform: 'translateX(7px)' }, { transform: 'translateX(-4px)' }, { transform: 'translateX(0)' }],
        { duration: 360, easing: 'ease-out' }
      )
      input.select()
      button.disabled = false
      button.replaceChildren('继续')
    }
  })
  // No autofocus on touch: it would throw the keyboard up before the user asks.
  if (!matchMedia('(pointer: coarse)').matches) input.focus()
}

/** WeChat QR login. `update(wx)` re-renders for each session state. */
export function createConnect(app, { onLock }) {
  const img = h('img', { class: 'qr-img', alt: '微信登录二维码', width: 188, height: 188, hidden: true })
  const spinner = h('span', { class: 'spinner' })
  const scannedAvatar = h('span')
  const refresh = h('button', { class: 'btn primary solid-press', type: 'button' }, icon('refresh'), '刷新二维码')
  const overScanned = h('div', { class: 'qr-over scanned' }, scannedAvatar, '请在手机上确认登录')
  const expiredText = h('span', {}, '二维码已失效')
  const overExpired = h('div', { class: 'qr-over expired' }, expiredText, refresh)
  const overConnecting = h('div', { class: 'qr-over connecting' }, h('span', { class: 'spinner' }), '正在登录…')
  const wrap = h('div', { class: 'qr-wrap', 'aria-live': 'polite' }, img, spinner, overScanned, overExpired, overConnecting)

  const saveBtn = h('button', { class: 'btn-outline', type: 'button' }, icon('download'), '保存二维码')
  const linkBtn = h('button', { class: 'btn-outline', type: 'button' }, icon('link'), '复制本页地址')
  const actions = h('div', { class: 'qr-actions' }, saveBtn, linkBtn)

  const title = h('h1', {}, '登录微信')
  const lead = h('p', { class: 'lead' }, '用手机微信“扫一扫”扫描二维码，并在手机上确认。')
  const errorBox = h('div', { class: 'auth-error', role: 'alert', hidden: true })
  const tips = h('ul', { class: 'tips' },
    h('li', {}, '二维码显示在这台 iPhone 上时，可以在电脑或平板上打开本页地址扫码。'),
    h('li', {}, '也可以保存二维码，在微信“扫一扫”里从相册选取（部分微信版本可能不支持）。'),
    h('li', {}, '登录后由服务器保持会话并接收消息，锁屏或关闭页面不会丢失。'))
  const lock = h('button', { type: 'button' }, '锁定本应用')
  const foot = h('div', { class: 'auth-foot' }, '非官方客户端，基于微信网页版协议 · ', lock)

  reveal(wrap, actions, title, lead, tips, foot)
  const card = h('div', { class: 'auth-card wide' },
    h('div', { class: 'qr-col' }, wrap, actions),
    h('div', { class: 'text-col' }, title, lead, errorBox, tips, foot))
  const root = h('main', { class: 'auth' }, card)
  app.replaceChildren(root)

  let starting = false
  let lastUuid = ''

  async function start() {
    if (starting) return
    starting = true
    errorBox.hidden = true
    wrap.className = 'qr-wrap'
    img.hidden = true
    spinner.hidden = false
    try {
      await api.post('/api/login')
    } catch (err) {
      showError(err.message, err.data)
      wrap.className = 'qr-wrap expired'
    } finally {
      starting = false
    }
  }

  function showError(message, detail) {
    errorBox.hidden = false
    errorBox.replaceChildren(...[
      message || '登录失败',
      detail?.code ? h('code', {}, `（${detail.step || ''} ${detail.code}）`) : null,
      detail?.code === 1203 ? h('p', { class: 'auth-hint' }, refusalHint(detail)) : null
    ].filter(Boolean))
  }

  refresh.addEventListener('click', start)
  lock.addEventListener('click', onLock)
  linkBtn.addEventListener('click', async () => {
    try {
      await navigator.clipboard.writeText(location.origin)
      toast('已复制，在电脑或平板上打开即可扫码', { type: 'ok' })
    } catch {
      toast(location.origin)
    }
  })
  saveBtn.addEventListener('click', async () => {
    if (img.hidden || !img.src) return
    try {
      const file = await qrPng(img.src)
      if (navigator.canShare?.({ files: [file] })) await navigator.share({ files: [file] })
      else {
        const a = h('a', { href: URL.createObjectURL(file), download: file.name })
        a.click()
      }
    } catch (err) {
      if (err?.name !== 'AbortError') toast('无法保存二维码', { type: 'error' })
    }
  })

  return {
    el: root,
    start,
    update(wx) {
      const phase = wx?.phase || 'idle'
      if (phase === 'idle') {
        title.textContent = '登录微信'
        start()
        return
      }
      if (phase === 'qr' || phase === 'scanned') {
        errorBox.hidden = true
        if (wx.uuid && wx.uuid !== lastUuid) {
          lastUuid = wx.uuid
          img.onload = () => {
            img.hidden = false
            spinner.hidden = true
            img.classList.remove('fresh')
            void img.offsetWidth
            img.classList.add('fresh')
          }
          img.src = `/api/login/qr.svg?u=${encodeURIComponent(wx.uuid)}`
        }
      }
      wrap.className = `qr-wrap ${phase === 'scanned' ? 'scanned' : phase === 'connecting' ? 'connecting' : phase === 'expired' || phase === 'offline' ? 'expired' : ''}`
      if (phase === 'expired' || phase === 'offline') spinner.hidden = true
      expiredText.textContent = phase === 'offline' ? '会话已结束' : '二维码已失效'
      if (phase === 'scanned') {
        scannedAvatar.replaceChildren(avatar(null, '', { size: 64 }))
        if (wx.avatar?.startsWith('data:image/')) {
          const a = scannedAvatar.firstChild
          const i = new Image()
          i.alt = ''
          i.onload = () => i.classList.add('loaded')
          i.src = wx.avatar
          a.append(i)
        }
        haptic()
      }
      if (phase === 'offline' || (phase === 'expired' && wx.error)) {
        title.textContent = phase === 'offline' ? '微信已退出' : '登录微信'
        showError(wx.error?.message || '会话已结束', wx.error)
        refresh.replaceChildren(icon('refresh'), '重新登录')
      } else {
        title.textContent = '登录微信'
        refresh.replaceChildren(icon('refresh'), '刷新二维码')
      }
    }
  }
}

/** ret 1203 is WeChat refusing this kind of login, not a bug here. */
function refusalHint(detail) {
  const both = detail.tried?.length > 1
  return [
    '这是微信服务器对网页 / UOS 协议登录的限制，不是本应用的故障。',
    both ? '已用桌面版（UOS）和网页版两种方式各试了一次。' : '',
    '可以过一段时间再扫码；如果有新的可用 client-version / extspam，可在 Cloudflare 变量 WX_CLIENT_VERSION、WX_EXTSPAM 中填入后重新部署（见 README）。'
  ].join('')
}

async function qrPng(src) {
  const svg = await fetch(src).then(r => r.text())
  const url = URL.createObjectURL(new Blob([svg], { type: 'image/svg+xml' }))
  const im = new Image()
  await new Promise((resolve, reject) => {
    im.onload = resolve
    im.onerror = reject
    im.src = url
  })
  const size = 720
  const canvas = document.createElement('canvas')
  canvas.width = canvas.height = size
  const g = canvas.getContext('2d')
  g.imageSmoothingEnabled = false
  g.fillStyle = '#fff'
  g.fillRect(0, 0, size, size)
  g.drawImage(im, 40, 40, size - 80, size - 80)
  URL.revokeObjectURL(url)
  const blob = await new Promise(r => canvas.toBlob(r, 'image/png'))
  return new File([blob], 'wechat-login-qr.png', { type: 'image/png' })
}
