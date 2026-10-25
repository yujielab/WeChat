// App entry: password gate → WeChat login → chats.

import { initViewport } from './ui/viewport.js'
import { initPress } from './ui/press.js'
import { syncThemeColor, startPerfProbe } from './ui/appearance.js'
import { api, connectSocket, onApiEvent } from './api.js'
import {
  state, setWx, setChats, upsertChats, upsertMessage, replaceMessage, removeMessage, clearThread
} from './store.js'
import { renderGate, renderSetup, createConnect } from './views/auth.js'
import { createShell } from './views/shell.js'
import { toast, closeAllOverlays } from './views/overlay.js'

const app = document.getElementById('app')
let socket = null
let shell = null
let connect = null
let screen = null
let wantConnect = false

initViewport()
initPress()
syncThemeColor()
matchMedia('(prefers-color-scheme: dark)').addEventListener('change', syncThemeColor)

if ('serviceWorker' in navigator) {
  navigator.serviceWorker.register('/sw.js').catch(() => {})
  navigator.serviceWorker.addEventListener('message', e => {
    if (e.data?.t === 'open' && e.data.chat && shell) shell.openChat(e.data.chat)
  })
}

onApiEvent(evt => {
  if (evt === 'unauthorized') location.reload()
})

boot()

async function boot() {
  let auth
  try {
    auth = await fetch('/auth/status', { credentials: 'same-origin' }).then(r => r.json())
  } catch {
    app.replaceChildren()
    toast('无法连接服务器，请检查网络', { type: 'error', duration: 6000 })
    setTimeout(boot, 4000)
    return
  }
  if (!auth.configured) return renderSetup(app)
  if (!auth.authed) return renderGate(app, { onSuccess: start })
  start()
}

async function start() {
  try {
    await refresh()
  } catch (err) {
    toast(err.message, { type: 'error' })
    setTimeout(start, 3000)
    return
  }
  socket?.close()
  socket = connectSocket({
    onMessage: handle,
    onOpen: () => {
      state.socket = true
      updateStatus()
      // Anything missed while the socket was down (iOS suspends it in the background).
      refresh().then(() => shell?.thread.catchUp()).catch(() => {})
    },
    onClose: () => {
      state.socket = false
      updateStatus()
    }
  })
  route()
}

async function refresh() {
  const boot = await api.get('/api/bootstrap')
  state.me = boot.me
  setWx(boot.state)
  setChats(boot.chats)
  shell?.setMe(state.me)
  updateStatus()
  route()
}

function handle(msg) {
  switch (msg.t) {
    case 'state': {
      const prev = state.wx?.phase
      setWx(msg.state)
      updateStatus()
      if (prev !== msg.state.phase) {
        if (msg.state.phase === 'online') {
          wantConnect = false
          refresh().catch(() => {})
        }
        route()
      }
      connect?.update(msg.state)
      shell?.setBanner(msg.state)
      break
    }
    case 'msg':
      upsertMessage(msg.msg)
      break
    case 'replace':
      replaceMessage(msg.from, msg.msg)
      break
    case 'remove':
      removeMessage(msg.id, msg.chat)
      break
    case 'chats':
      upsertChats(msg.chats || [])
      break
    case 'cleared':
      clearThread(msg.chat)
      break
    case 'contacts':
      state.contacts = null
      break
    case 'reload':
      refresh().catch(() => {})
      break
  }
}

function route() {
  const wx = state.wx
  if (!wx) return
  const live = wx.phase === 'online'
  const hasHistory = state.chats.size > 0
  const showMain = live || (hasHistory && !wantConnect && !['qr', 'scanned', 'connecting'].includes(wx.phase))
  if (showMain) {
    if (screen !== 'main') {
      screen = 'main'
      connect = null
      closeAllOverlays()
      shell = createShell(app, {
        socketSend: obj => socket?.send(obj),
        loadContacts,
        onLogoutWx: logoutWx,
        onLock: lock,
        onReconnect: () => {
          wantConnect = true
          route()
          // Straight to a fresh QR code; no second "重新登录" tap.
          if (['offline', 'expired', 'idle'].includes(state.wx?.phase)) connect?.start()
        }
      })
      shell.setMe(state.me)
      startPerfProbe()
    }
    shell.setBanner(wx)
    updateStatus()
  } else {
    if (screen !== 'connect') {
      screen = 'connect'
      shell = null
      closeAllOverlays()
      connect = createConnect(app, { onLock: lock })
    }
    connect.update(wx)
  }
}

function updateStatus() {
  if (!shell) return
  const wx = state.wx || {}
  let s = {}
  if (!state.socket) s = { text: '连接中…', spinner: true }
  else if (wx.phase === 'connecting') s = { text: '登录中…', spinner: true }
  else if (wx.phase === 'online' && !wx.contactsLoaded) s = { text: '收取中…', spinner: true }
  else if (wx.phase !== 'online') s = { text: '未连接', warn: true }
  shell.setStatus(s)
}

let contactsLoading = null
async function loadContacts() {
  if (state.contacts) return state.contacts
  contactsLoading ||= api.get('/api/contacts')
    .then(list => {
      state.contacts = new Map(list.map(c => [c.id, c]))
      return state.contacts
    })
    .catch(err => {
      toast(err.message, { type: 'error' })
      return null
    })
    .finally(() => { contactsLoading = null })
  return contactsLoading
}

async function logoutWx() {
  try {
    await api.post('/api/logout')
    wantConnect = true
  } catch (err) {
    toast(err.message, { type: 'error' })
  }
}

async function lock() {
  await fetch('/auth/logout', { method: 'POST', credentials: 'same-origin' }).catch(() => {})
  location.reload()
}
