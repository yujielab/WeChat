// The signed-in app: conversation list + conversation, arranged for the
// current iPhone Duo posture. Folded → stack with push/pop; unfolded → side by
// side. Folding or unfolding keeps the open conversation on screen.

import { createNav } from '../ui/nav.js'
import { getLayout, onLayout } from '../ui/viewport.js'
import { state, chatInfo } from '../store.js'
import { createChatList } from './chatList.js'
import { createThread } from './thread.js'
import { openSettings, openRoomInfo, openNewChat, rememberOpen } from './sheets.js'
import { closeAllOverlays } from './overlay.js'
import { h } from '../ui/dom.js'

export function createShell(app, { socketSend, loadContacts, onCall, onLogout }) {
  const listPane = h('section', { class: 'pane', 'aria-label': '会话列表' })
  const threadPane = h('section', { class: 'pane', 'aria-label': '对话' })
  const shell = h('div', { class: 'shell', dataset: { layout: getLayout(), thread: 'closed' } }, listPane, threadPane)
  app.replaceChildren(shell)

  const list = createChatList(listPane, {
    onOpen: id => openChat(id),
    onSettings: () => openSettings({ onLogout }),
    onCompose: () => openNewChat({ loadContacts, onOpen: id => openChat(id) })
  })

  const thread = createThread(threadPane, {
    onBack: () => { if (history.state?.chat) history.back(); else closeChat() },
    onInfo: id => openRoomInfo(id, { onOpen: rid => openChat(rid), loadContacts }),
    onCompose: () => openNewChat({ loadContacts, onOpen: id => openChat(id) }),
    onCall,
    socketSend
  })

  const nav = createNav(shell, listPane, threadPane, {
    onSwipeBack: () => { skipPop = true; if (history.state?.chat) history.back(); afterClose() }
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
      history.replaceState({ list: true }, '')
      history.pushState({ chat: thread.current }, '')
    }
  })

  function openChat(id, { replace = false } = {}) {
    if (!id) return
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
    if (skipPop) { skipPop = false; return }
    if (e.state?.chat && getLayout() === 'stack') {
      if (thread.current !== e.state.chat) openChat(e.state.chat, { replace: true })
      return
    }
    if (thread.current && getLayout() === 'stack') closeChat({ instant: Boolean(e.hasUAVisualTransition) })
  })

  const deep = new URLSearchParams(location.search).get('chat')
  if (deep) { history.replaceState({}, '', location.pathname); openChat(deep) }
  else if (getLayout() === 'split') {
    const last = localStorage.getItem('ui:open')
    if (last && chatInfo(last)) openChat(last, { replace: true })
    else thread.showEmpty()
  }
  list.render()

  return {
    list,
    thread,
    openChat,
    setMe(me) { list.setMe(me) },
    setStatus(s) { list.setStatus(s) }
  }
}
