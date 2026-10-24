// The signed-in app: chat list + conversation, arranged for the current
// iPhone Duo posture. Folded → stack with push/pop; unfolded → side by side.
// Folding or unfolding keeps the open conversation on screen.

import { h, icon } from '../ui/dom.js'
import { createNav } from '../ui/nav.js'
import { getLayout, onLayout } from '../ui/viewport.js'
import { state, emit, chatInfo } from '../store.js'
import { createChatList } from './chatList.js'
import { createThread } from './thread.js'
import { openSettings, openInfo, openContacts, rememberOpen } from './sheets.js'
import { closeAllOverlays } from './overlay.js'

export function createShell(app, { socketSend, loadContacts, onLogoutWx, onLock, onReconnect }) {
  const listPane = h('section', { class: 'pane', 'aria-label': '聊天列表' })
  const threadPane = h('section', { class: 'pane', 'aria-label': '对话' })
  const shell = h('div', { class: 'shell', dataset: { layout: getLayout(), thread: 'closed' } }, listPane, threadPane)
  const banner = h('div', { class: 'offline-banner glass', role: 'status', hidden: true })
  app.replaceChildren(shell)

  const list = createChatList(listPane, {
    onOpen: (id, contact) => openChat(id, { contact }),
    onSettings: () => openSettings({ onLogoutWx, onLock }),
    onCompose: () => openContacts({ onPick: c => openChat(c.id, { contact: c }), loadContacts }),
    loadContacts
  })
  listPane.append(banner)

  const thread = createThread(threadPane, {
    onBack: () => {
      if (history.state?.chat) history.back()
      else closeChat()
    },
    onInfo: id => openInfo(id),
    socketSend
  })

  const nav = createNav(shell, listPane, threadPane, {
    // The gesture already animated the pop; keep history in sync without a second animation.
    onSwipeBack: () => {
      skipPop = true
      if (history.state?.chat) history.back()
      afterClose()
    }
  })

  let skipPop = false

  function applyLayout(layout) {
    shell.dataset.layout = layout
    list.setLayout(layout)
    thread.setLayout(layout)
    document.getElementById('overlays').dataset.layout = layout
  }
  applyLayout(getLayout())

  onLayout((layout, prev) => {
    applyLayout(layout)
    nav.settle(Boolean(thread.current))
    if (layout === 'split') {
      if (!thread.current) {
        const last = state.open || localStorage.getItem('ui:open')
        if (last && chatInfo(last)) openChat(last, { replace: true })
        else thread.showEmpty()
      }
    } else if (prev === 'split' && thread.current) {
      // Folding with a chat open: keep it in front, with a history step back to the list.
      history.replaceState({ list: true }, '')
      history.pushState({ chat: thread.current }, '')
    }
  })

  function openChat(id, { contact, replace = false } = {}) {
    if (contact && !state.chats.has(id)) {
      state.temp.set(id, {
        id,
        name: contact.name,
        room: contact.room,
        count: contact.count,
        pinned: contact.pinned,
        muted: contact.muted,
        ts: 0,
        unread: 0,
        last: null
      })
      emit('chats', [id])
    }
    closeAllOverlays()
    state.open = id
    rememberOpen(id)
    list.setSelected(id)
    const wasOpen = thread.current
    thread.open(id)
    if (getLayout() === 'stack') {
      if (history.state?.chat && wasOpen) history.replaceState({ chat: id }, '')
      else history.pushState({ chat: id }, '')
      nav.push()
    } else {
      history.replaceState({ chat: id }, '')
      nav.settle(true)
    }
  }

  function afterClose() {
    thread.close()
    state.open = null
    rememberOpen(null)
    list.setSelected(null)
  }

  function closeChat({ instant = false } = {}) {
    if (getLayout() === 'split') return
    nav.pop({ instant }).then(afterClose)
  }

  window.addEventListener('popstate', e => {
    if (skipPop) {
      skipPop = false
      return
    }
    if (e.state?.chat && getLayout() === 'stack') {
      if (thread.current !== e.state.chat) openChat(e.state.chat, { replace: true })
      return
    }
    if (thread.current && getLayout() === 'stack') {
      // Safari's own edge swipe already animated a snapshot; don't animate twice.
      closeChat({ instant: Boolean(e.hasUAVisualTransition) })
    }
  })

  // Start: reopen the last chat on the unfolded display, like iPad Messages.
  const deep = new URLSearchParams(location.search).get('chat')
  if (deep) {
    history.replaceState({}, '', location.pathname)
    openChat(deep)
  } else if (getLayout() === 'split') {
    const last = localStorage.getItem('ui:open')
    if (last && chatInfo(last)) openChat(last, { replace: true })
    else thread.showEmpty()
  }
  list.render()

  return {
    list,
    thread,
    openChat,
    setMe(me) {
      list.setMe(me)
    },
    setStatus(s) {
      list.setStatus(s)
    },
    setBanner(wx) {
      const off = wx && (wx.phase === 'offline' || wx.phase === 'idle' || wx.phase === 'expired')
      banner.hidden = !off
      if (!off) return
      const btn = h('button', { class: 'text-button', type: 'button' }, '重新登录')
      btn.addEventListener('click', onReconnect)
      banner.replaceChildren(
        icon('wifi-slash'),
        h('span', { class: 'grow' }, h('b', {}, '微信未连接'), h('span', {}, wx.error?.message || '可以查看历史消息，发送需要重新登录')),
        btn)
    }
  }
}
