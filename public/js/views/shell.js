// The signed-in app as one strip of columns — sidebar | list | conversation |
// details — seen through a window one column wide folded and two columns
// wide unfolded (ui/strip.js). Going forward slides the window right and
// pushes a history entry; Back, a swipe or the browser's back slides it
// left. Folding or unfolding keeps the focused column on screen.

import { createStrip, COLS } from '../ui/strip.js'
import { getLayout, onLayout } from '../ui/viewport.js'
import { state, chatInfo } from '../store.js'
import { createSidebar } from './sidebar.js'
import { createChatList } from './chatList.js'
import { createThread } from './thread.js'
import { createArtifact } from './artifact.js'
import { openSettings, openNewChat, rememberOpen } from './sheets.js'
import { closeAllOverlays } from './overlay.js'
import { h } from '../ui/dom.js'

const SIDEBAR = 0
const LIST = 1
const THREAD = 2
const ARTIFACT = 3

export function createShell(app, { socketSend, loadContacts, onCall, onLogout }) {
  const panes = ['边栏', '会话列表', '对话', '详情'].map(label => h('section', { class: 'pane', tabindex: '-1', 'aria-label': label }))
  const shell = h('div', { class: 'shell', dataset: { layout: getLayout() } }, ...panes)
  app.replaceChildren(shell)
  const overlays = document.getElementById('overlays')

  const compose = () => openNewChat({ loadContacts, onOpen: id => openChat(id) })
  const sidebar = createSidebar(panes[SIDEBAR], {
    onScope: key => {
      list.setFilter(key)
      forward(LIST)
    },
    onSettings: origin => openSettings({ onLogout, origin }),
    onSearch: () => {
      forward(LIST)
      list.openSearch()
    },
    onCompose: compose
  })
  const list = createChatList(panes[LIST], {
    onOpen: id => openChat(id),
    onBack: () => back(LIST),
    onFilter: () => sidebar.render(),
    onCompose: compose,
    onSettings: origin => openSettings({ onLogout, origin })
  })
  const thread = createThread(panes[THREAD], {
    onBack: () => back(THREAD),
    onInfo: id => toggleArtifact('info', id),
    onDraw: id => toggleArtifact('draw', id),
    onCompose: compose,
    onCall,
    socketSend
  })
  const artifact = createArtifact(panes[ARTIFACT], {
    onClose: () => back(ARTIFACT),
    onSend: (blob, size) => thread.sendDrawing(blob, size),
    loadContacts
  })
  const views = [sidebar, list, thread, artifact]

  const strip = createStrip(shell, panes, {
    onRoles: changed => {
      // The open conversation is being read while it (or its details) has
      // the screen; beside the sidebar it's out of view, so new messages in
      // it count as unread again.
      state.open = panes[THREAD].dataset.role !== 'hidden' || strip.focus === ARTIFACT ? thread.current : null
      for (const pane of changed) {
        // A column out of view keeps the arrangement it was last seen in.
        if (pane.dataset.role !== 'hidden') views[panes.indexOf(pane)].setLayout(pane.dataset.role)
      }
    },
    onSwipeBack: ({ from, velocity }) => back(from, { velocity }),
    swipeZone: pane => (pane.dataset.edgeSwipe !== undefined ? 40 : pane.clientWidth * 0.6)
  })

  // ------------------------------------------------------------ navigation
  // History mirrors the strip: entries pushed going forward to a
  // conversation or its details, popped going back.
  const pushed = []
  let skipPop = 0
  let afterPop = null
  const entry = col => ({ duo: col, chat: thread.current, art: col === ARTIFACT ? artifact.current : null })

  function go(col, opts) {
    const active = document.activeElement
    const done = strip.go(col, opts)
    syncToggles()
    done.then(finished => {
      if (!finished) return
      settled()
      // Focus that was in a column that slid away follows the window.
      if (active && !active.isConnected) panes[strip.focus].focus({ preventScroll: true })
      else if (active && panes.some(p => p.inert && p.contains(active))) panes[strip.focus].focus({ preventScroll: true })
    })
    return done
  }

  /** Move to a column after the focused one (or stay, replacing the entry). */
  function forward(col) {
    if (col > strip.focus && col >= THREAD) {
      // One entry per column passed, so Back retraces every step.
      for (let c = Math.max(strip.focus + 1, THREAD); c <= col; c++) {
        history.pushState(entry(c), '')
        pushed.push(c)
      }
    } else history.replaceState(entry(col), '')
    return go(col)
  }

  // Unfolded, using the other column of the window makes it the focus.
  for (const type of ['pointerdown', 'focusin']) {
    shell.addEventListener(type, e => {
      const col = panes.findIndex(pane => pane.contains(e.target))
      const from = strip.focus
      if (col < 0 || panes[col].dataset.role === 'hidden' || !strip.touch(col)) return
      if (col === THREAD && from < THREAD) {
        history.pushState(entry(THREAD), '')
        pushed.push(THREAD)
      }
    }, { capture: true })
  }

  /** Back from a column: to the one before it. */
  function back(from, { velocity = 0 } = {}) {
    const to = Math.max(0, from - 1)
    const n = pushed.filter(c => c > to).length
    if (n) {
      pushed.length -= n
      skipPop++
      afterPop = entry(to)
      history.go(-n)
    } else history.replaceState(entry(to), '')
    return go(to, { velocity })
  }

  // Escape closes the details column from either column of the window.
  shell.addEventListener('keydown', e => {
    if (e.key !== 'Escape' || e.defaultPrevented || strip.focus !== ARTIFACT) return
    e.preventDefault()
    back(ARTIFACT)
  })

  window.addEventListener('popstate', e => {
    if (skipPop) {
      skipPop--
      if (afterPop) history.replaceState(afterPop, '')
      afterPop = null
      return
    }
    const s = e.state || {}
    const col = Number.isInteger(s.duo) ? s.duo : LIST
    const instant = Boolean(e.hasUAVisualTransition)
    if (col < strip.focus) {
      while (pushed.length && pushed.at(-1) > col) pushed.pop()
      go(col, { instant })
      return
    }
    // Forward again (or the same column for another conversation).
    if (s.chat && chatInfo(s.chat) && s.chat !== thread.current) openChat(s.chat, { focus: false })
    if (col === ARTIFACT && s.art?.chat === thread.current) artifact.show(s.art.kind, s.art.chat)
    if (col > strip.focus) {
      pushed.push(col)
      go(col, { instant })
    }
  })

  function syncToggles() {
    const art = strip.focus === ARTIFACT ? artifact.current : null
    thread.bars.set('info', { state: { active: art?.kind === 'info' } })
    thread.setTool('draw', art?.kind === 'draw')
  }

  /**
   * After a slide: columns that left the window let go of what they showed.
   * Going back past the conversation closes it; folding past it doesn't, so
   * unfolding again finds it where it was.
   */
  function settled({ navigated = true } = {}) {
    if (strip.focus < ARTIFACT && !strip.shows(ARTIFACT)) artifact.clear()
    if (navigated && strip.count === 1 && strip.focus < THREAD && thread.current) {
      thread.close()
      state.open = null
      rememberOpen(null)
      list.setSelected(null)
    }
  }

  function openChat(id, { focus = true } = {}) {
    if (!id) return
    closeAllOverlays()
    state.open = id
    rememberOpen(id)
    list.setSelected(id)
    if (thread.current !== id) thread.open(id)
    // Details belong to one conversation: another one brings its
    // conversation back to the front.
    const leaveDetails = strip.focus === ARTIFACT && (focus || artifact.current?.chat !== id)
    if (artifact.current && artifact.current.chat !== id) artifact.clear()
    if (leaveDetails) {
      if (pushed.at(-1) === ARTIFACT) pushed[pushed.length - 1] = THREAD
      history.replaceState(entry(THREAD), '')
      go(THREAD)
    } else if (focus) forward(THREAD)
    else if (strip.focus === THREAD) history.replaceState(entry(THREAD), '')
  }

  function toggleArtifact(kind, chat) {
    const shown = artifact.current
    if (strip.focus === ARTIFACT && shown?.kind === kind && shown.chat === chat) return back(ARTIFACT)
    closeAllOverlays()
    artifact.show(kind, chat)
    return forward(ARTIFACT)
  }

  // ------------------------------------------------------------ posture
  function restoreLast({ focus }) {
    const last = state.open || localStorage.getItem('ui:open')
    if (last && chatInfo(last)) openChat(last, { focus })
    else thread.showEmpty()
  }

  let enterTimer = 0
  function applyLayout(layout) {
    const before = panes.filter(p => !p.classList.contains('off'))
    shell.dataset.layout = layout
    overlays.dataset.layout = layout
    // Unfolded, the room goes to the list and the conversation: the
    // sidebar's scopes, search, New Chat and settings are all the list's
    // there, so unfolding from the sidebar lands on the list.
    if (layout === 'split' && strip.focus === SIDEBAR) {
      history.replaceState(entry(LIST), '')
      strip.go(LIST, { instant: true })
    }
    strip.setCount(layout === 'split' ? 2 : 1)
    // Unfolding, the column that joins the window arrives from its side.
    clearTimeout(enterTimer)
    for (const pane of panes) {
      delete pane.dataset.enter
      if (layout === 'split' && before.length && !before.includes(pane) && !pane.classList.contains('off')) pane.dataset.enter = pane.dataset.role
    }
    enterTimer = setTimeout(() => { for (const pane of panes) delete pane.dataset.enter }, 900)
    if (strip.shows(THREAD) && !thread.current) restoreLast({ focus: false })
    syncToggles()
    settled({ navigated: false })
  }

  history.replaceState(entry(LIST), '')
  applyLayout(getLayout())
  onLayout(layout => applyLayout(layout))

  const deep = new URLSearchParams(location.search).get('chat')
  if (deep) {
    history.replaceState(entry(LIST), '', location.pathname)
    openChat(deep)
  } else if (getLayout() === 'split') restoreLast({ focus: true })
  list.render()

  return {
    list,
    thread,
    sidebar,
    artifact,
    strip,
    openChat,
    /** Show a column (sidebar, list, thread, artifact) as if navigated to. */
    show: name => {
      const col = COLS.indexOf(name)
      return col < strip.focus ? back(col + 1) : forward(col)
    },
    setMe(me) {
      sidebar.setMe(me)
      list.setMe(me)
    },
    setStatus(s) { list.setStatus(s) }
  }
}
