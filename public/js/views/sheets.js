// Settings, chat info and the new-chat contact picker (all sheets).

import { h, icon, storage } from '../ui/dom.js'
import { listTime } from '../ui/format.js'
import { getPrefs, setTheme, setGlass, setMotion, setHaptics } from '../ui/appearance.js'
import { isStandalone } from '../ui/viewport.js'
import { state, upsertChats, clearThread } from '../store.js'
import { api } from '../api.js'
import { avatar } from './avatar.js'
import { openSheet, confirmAction, toast } from './overlay.js'

function cell(label, right, { icon: ic, color, sub, onClick, tint, destructive } = {}) {
  const tag = onClick ? 'button' : 'div'
  const el = h(tag, {
    class: ['cell', ic && 'icon-left', tint && 'tint', destructive && 'destructive'],
    type: onClick ? 'button' : undefined
  },
  ic ? h('span', { class: 'cell-icon', style: { background: color || 'var(--gray)' } }, icon(ic)) : null,
  h('span', { class: 'grow' }, label, sub ? h('span', { class: 'sub' }, sub) : null),
  right ?? null)
  if (onClick) el.addEventListener('click', onClick)
  return el
}

function toggle(checked, onChange, label) {
  const sw = h('button', { class: 'switch', type: 'button', role: 'switch', 'aria-checked': String(Boolean(checked)), 'aria-label': label })
  sw.addEventListener('click', async () => {
    const next = sw.getAttribute('aria-checked') !== 'true'
    sw.setAttribute('aria-checked', String(next))
    const ok = await onChange(next)
    if (ok === false) sw.setAttribute('aria-checked', String(!next))
  })
  return sw
}

function segmented(options, value, onChange, label) {
  const i0 = Math.max(0, options.findIndex(o => o.value === value))
  const seg = h('div', { class: 'seg', role: 'radiogroup', 'aria-label': label, style: { '--n': String(options.length), '--i': String(i0) } })
  seg.append(h('span', { class: 'thumb', 'aria-hidden': 'true' }))
  options.forEach((o, i) => {
    const b = h('button', { type: 'button', role: 'radio', 'aria-checked': String(i === i0) }, o.label)
    b.addEventListener('click', () => {
      seg.style.setProperty('--i', String(i))
      for (const x of seg.querySelectorAll('button')) x.setAttribute('aria-checked', String(x === b))
      onChange(o.value)
    })
    seg.append(b)
  })
  return seg
}

// ---------------------------------------------------------------- settings

export function openSettings({ onLogoutWx, onLock }) {
  const prefs = getPrefs()
  const me = state.me
  const wx = state.wx || {}
  const autoSolid = prefs.glassAuto && prefs.glass !== 'solid'

  const pushCell = h('div')
  const diagBody = h('div', { class: 'group-foot', hidden: true })

  const content = h('div', {},
    h('div', { class: 'profile' },
      avatar(me?.id, me?.name || '我', { size: 84 }),
      h('h3', {}, me?.name || '未登录'),
      me?.alias ? h('p', {}, `微信号：${me.alias}`) : me?.sig ? h('p', {}, me.sig) : null),

    h('div', { class: 'group-title' }, '显示与交互'),
    h('div', { class: 'group' },
      cell('外观', segmented([
        { label: '自动', value: 'system' },
        { label: '浅色', value: 'light' },
        { label: '深色', value: 'dark' }
      ], prefs.theme, setTheme, '外观')),
      cell('降低透明度', toggle(prefs.glass === 'solid' || autoSolid, on => setGlass(on ? 'solid' : 'auto'), '降低透明度'), {
        sub: autoSolid ? '检测到滚动掉帧，已自动改为实色界面' : '用实色代替玻璃材质'
      }),
      cell('减少动态效果', toggle(document.documentElement.dataset.motion === 'reduce', on => setMotion(on ? 'reduce' : 'system'), '减少动态效果'), {
        sub: '默认跟随系统“减弱动态效果”设置'
      }),
      cell('触感反馈', toggle(prefs.haptics, on => setHaptics(on), '触感反馈'))),

    h('div', { class: 'group-title' }, '通知'),
    pushCell,

    h('div', { class: 'group-title' }, '连接'),
    h('div', { class: 'group' },
      cell('微信', h('span', { class: 'value' }, phaseLabel(wx.phase))),
      cell('上次同步', h('span', { class: 'value tabular' }, wx.lastSyncAt ? `${listTime(wx.lastSyncAt)} ${new Date(wx.lastSyncAt).toLocaleTimeString('zh-CN', { hour12: false })}` : '—')),
      cell('诊断信息', icon('chevron-down', 'chev'), { onClick: () => toggleDiag() })),
    diagBody,

    h('div', { class: 'group-title' }, ''),
    h('div', { class: 'group' },
      cell('退出微信网页版', null, {
        destructive: true,
        onClick: async e => {
          const ok = await confirmAction(e.currentTarget, { title: '退出后需要重新扫码登录。本设备上的聊天记录会保留。', confirm: '退出微信' })
          if (ok) {
            sheet.close()
            onLogoutWx()
          }
        }
      })),
    h('div', { class: 'group', style: { marginTop: '12px' } },
      cell('锁定本应用', null, { tint: true, onClick: () => onLock() })),
    h('p', { class: 'group-foot' }, '非官方客户端，基于微信网页版协议，仅供个人使用。消息只保存在你自己的 Cloudflare 账户中。')
  )

  const sheet = openSheet({ title: '设置', content, tall: true })
  renderPush(pushCell)

  async function toggleDiag() {
    diagBody.hidden = !diagBody.hidden
    if (diagBody.hidden) return
    diagBody.textContent = '正在读取…'
    try {
      const d = await api.get('/api/diag')
      const lines = [
        `服务器：${d.host || '—'}`,
        `联系人 ${d.counts.contacts} · 聊天 ${d.counts.chats} · 消息 ${d.counts.messages} · 连接 ${d.sockets}`,
        ...d.log.slice(-8).reverse().map(l => `${new Date(l.at).toLocaleTimeString('zh-CN', { hour12: false })}  ${l.step}${l.code ? ` (${l.code})` : ''}：${l.message}`)
      ]
      diagBody.replaceChildren(...lines.flatMap((l, i) => (i ? [h('br'), l] : [l])))
    } catch (err) {
      diagBody.textContent = err.message
    }
  }
}

function phaseLabel(phase) {
  return {
    online: '在线',
    connecting: '登录中',
    qr: '等待扫码',
    scanned: '等待确认',
    expired: '二维码已失效',
    offline: '已退出',
    idle: '未登录'
  }[phase] || '—'
}

async function renderPush(slot) {
  const supported = 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window
  const configured = state.wx?.push?.configured
  let sub = null
  if (supported) {
    try {
      const reg = await navigator.serviceWorker.ready
      sub = await reg.pushManager.getSubscription()
    } catch {
      // No subscription available.
    }
  }
  let note = '收到新消息时在锁屏和通知中心提醒你。'
  let disabled = false
  if (!configured) {
    note = '服务器未配置 VAPID 密钥，通知不可用（见 README）。'
    disabled = true
  } else if (!supported) {
    note = isStandalone() ? '此设备不支持网页推送。' : '请先用 Safari 的“添加到主屏幕”安装本应用，再从主屏幕打开以开启通知。'
    disabled = true
  } else if (Notification.permission === 'denied') {
    note = '通知权限已被拒绝，请在“设置 › 通知”中允许。'
    disabled = true
  }
  const sw = toggle(Boolean(sub), on => (on ? enablePush() : disablePush()), '新消息通知')
  sw.disabled = disabled
  slot.replaceChildren(
    h('div', { class: 'group' }, cell('新消息通知', sw, { icon: 'bell', color: 'var(--red)' })),
    h('p', { class: 'group-foot' }, note))
}

async function enablePush() {
  try {
    const perm = await Notification.requestPermission()
    if (perm !== 'granted') {
      toast('没有获得通知权限', { type: 'error' })
      return false
    }
    const { key } = await api.get('/api/push/key')
    const reg = await navigator.serviceWorker.ready
    const sub = await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: b64urlToBytes(key) })
    await api.post('/api/push/subscribe', { subscription: sub.toJSON() })
    toast('通知已开启', { type: 'ok' })
    return true
  } catch (err) {
    toast(`无法开启通知：${err.message}`, { type: 'error' })
    return false
  }
}

async function disablePush() {
  try {
    const reg = await navigator.serviceWorker.ready
    const sub = await reg.pushManager.getSubscription()
    if (sub) {
      await api.post('/api/push/unsubscribe', { endpoint: sub.endpoint })
      await sub.unsubscribe()
    }
    return true
  } catch (err) {
    toast(err.message, { type: 'error' })
    return false
  }
}

function b64urlToBytes(s) {
  const bin = atob(s.replace(/-/g, '+').replace(/_/g, '/') + '==='.slice((s.length + 3) % 4))
  return Uint8Array.from(bin, c => c.charCodeAt(0))
}

// ---------------------------------------------------------------- chat info

export async function openInfo(chatId) {
  const chat = state.chats.get(chatId) || state.temp.get(chatId) || {}
  const body = h('div', {}, h('div', { class: 'profile' }, avatar(chatId, chat.name, { room: chat.room, size: 84 }), h('h3', {}, chat.name || '')))
  const sheet = openSheet({ title: chat.room ? '群聊信息' : '联系人', content: body, tall: Boolean(chat.room) })
  let c = null
  try {
    c = await api.get(`/api/contact/${encodeURIComponent(chatId)}`)
  } catch {
    c = { id: chatId, name: chat.name, room: chat.room, pinned: chat.pinned, muted: chat.muted, stale: chat.stale }
  }
  if (sheet.closed) return
  const parts = []
  const sub = []
  if (!c.room && c.remark && c.nick && c.remark !== c.nick) sub.push(`昵称：${c.nick}`)
  if (c.alias) sub.push(`微信号：${c.alias}`)
  body.firstChild.append(...sub.map(s => h('p', {}, s)))

  if (!c.room) {
    const rows = []
    if (c.region) rows.push(cell('地区', h('span', { class: 'value' }, c.region)))
    if (c.sig) rows.push(cell('个性签名', h('span', { class: 'value' }, c.sig)))
    if (rows.length) parts.push(h('div', { class: 'group-title' }, ''), h('div', { class: 'group' }, rows))
  } else {
    const members = c.members || []
    parts.push(h('div', { class: 'group-title' }, `群成员（${c.count || members.length}）`))
    const grid = h('div', { class: 'members' })
    for (const m of members.slice(0, 80)) {
      grid.append(h('div', { class: 'member' }, avatar(m.id, m.dn || m.nick, { size: 48, inRoom: chatId }), h('span', {}, m.dn || m.nick)))
    }
    parts.push(h('div', { class: 'group' }, members.length ? grid : cell('成员列表加载中，稍后再看', null)))
    if (members.length > 80) parts.push(h('p', { class: 'group-foot' }, `仅显示前 80 位成员`))
  }

  parts.push(h('div', { class: 'group-title' }, ''), h('div', { class: 'group' },
    cell('置顶聊天', c.stale ? null : toggle(c.pinned, async on => {
      try {
        await api.post('/api/pin', { chat: chatId, on })
        upsertChats([{ id: chatId, pinned: on }])
        return true
      } catch (err) {
        toast(err.message, { type: 'error' })
        return false
      }
    }, '置顶聊天')),
    cell('消息免打扰', h('span', { class: 'value' }, c.muted ? '已开启' : '未开启'), { sub: '请在手机上修改' })))

  parts.push(h('div', { class: 'group-title' }, ''), h('div', { class: 'group' },
    cell('清空本设备上的聊天记录', null, {
      destructive: true,
      onClick: async e => {
        const ok = await confirmAction(e.currentTarget, { title: '只会清除这个客户端里的记录，手机上的不受影响。', confirm: '清空记录' })
        if (!ok) return
        try {
          await api.post('/api/clear', { chat: chatId })
          clearThread(chatId)
          toast('已清空', { type: 'ok' })
        } catch (err) {
          toast(err.message, { type: 'error' })
        }
      }
    })))
  body.append(...parts)
}

// ---------------------------------------------------------------- new chat

export async function openContacts({ onPick, loadContacts }) {
  const input = h('input', {
    class: 'input',
    type: 'search',
    placeholder: '搜索联系人、群聊或拼音',
    autocomplete: 'off',
    autocorrect: 'off',
    autocapitalize: 'off',
    spellcheck: false,
    enterkeyhint: 'search',
    'aria-label': '搜索联系人'
  })
  const list = h('div', {}, h('div', { class: 'list-empty' }, h('span', { class: 'spinner' })))
  const content = h('div', {}, h('div', { style: { padding: '0 16px 8px' } }, input), list)
  const sheet = openSheet({ title: '新聊天', content, tall: true })
  await loadContacts()
  if (sheet.closed) return
  const all = [...(state.contacts?.values() || [])].filter(c => (c.friend || c.room || c.id === 'filehelper') && !c.special && !c.biz && !c.stale && c.id !== state.me?.id)
  const keyOf = c => {
    const k = (c.py || c.pyi || c.name || '#')[0]?.toUpperCase() || '#'
    return /[A-Z]/.test(k) ? k : '#'
  }
  const render = () => {
    const q = input.value.trim().toLowerCase()
    const hits = all.filter(c => !q || [c.name, c.remark, c.nick, c.py, c.pyi, c.alias].some(v => v && String(v).toLowerCase().includes(q)))
    const groups = hits.filter(c => c.room)
    const people = hits.filter(c => !c.room).sort((a, b) => (a.py || a.name).localeCompare(b.py || b.name, 'zh-CN'))
    const out = []
    const row = c => {
      const b = h('button', { class: 'contact-row', type: 'button' },
        avatar(c.id, c.name, { room: c.room, size: 40 }),
        h('div', { class: 'grow' }, h('div', { class: 'name' }, c.name), c.room && c.count ? h('div', { class: 'sub' }, `${c.count} 位成员`) : null))
      b.addEventListener('click', async () => {
        await sheet.close()
        onPick(c)
      })
      return b
    }
    if (groups.length) {
      out.push(h('div', { class: 'section-title' }, '群聊'))
      groups.slice(0, 50).forEach(c => out.push(row(c)))
    }
    let last = ''
    for (const c of people.slice(0, 400)) {
      const k = keyOf(c)
      if (k !== last) {
        out.push(h('div', { class: 'section-title' }, k))
        last = k
      }
      out.push(row(c))
    }
    if (!out.length) out.push(h('div', { class: 'list-empty' }, h('h2', {}, '无结果'), state.wx?.contactsLoaded ? '' : '通讯录还在同步，请稍后再试。'))
    list.replaceChildren(...out)
  }
  input.addEventListener('input', render)
  render()
}

export function rememberOpen(chat) {
  storage('ui:open', chat || null)
}
