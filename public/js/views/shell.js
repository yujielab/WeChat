// The signed-in app as one strip of columns — sidebar | list | conversation |
// details — seen through a window one column wide folded and two columns
// wide unfolded (ui/strip.js). Going forward slides the window right and
// pushes a history entry; Back, a swipe or the browser's back slides it
// left. Folding or unfolding keeps the focused column on screen.

import { createStrip, COLS } from '../ui/strip.js'
import { getLayout, onLayout, getPose, onPose } from '../ui/viewport.js'
import { state, chatInfo } from '../store.js'
import { createSidebar } from './sidebar.js'
import { createChatList } from './chatList.js'
import { createThread } from './thread.js'
import { createArtifact } from './artifact.js'
import { openSettings, openNewChat, rememberOpen } from './sheets.js'
import { openInsights } from './insights.js'
import { closeAllOverlays, healOverlays, confirmAction } from './overlay.js'
import { h } from '../ui/dom.js'
import { createDiscardGuard } from './draw-guard.js'

const SIDEBAR = 0
const LIST = 1
const THREAD = 2
const ARTIFACT = 3

export function createShell(app, { socketSend, loadContacts, onCall, onCallBack = () => 'none', callRinging = () => false, onLogout }) {
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
    onSettings: origin => openSettings({ onLogout, origin }),
    onInsights: origin => openInsights({ origin, onOpen: id => openChat(id) })
  })
  const thread = createThread(panes[THREAD], {
    onBack: () => leaveThread(),
    onInfo: id => toggleArtifact('info', id),
    onDraw: id => toggleArtifact('draw', id),
    onCompose: compose,
    onCall,
    socketSend
  })
  const artifact = createArtifact(panes[ARTIFACT], {
    // After sending a drawing, typing carries on in the composer.
    onClose: opts => leaveArtifact().then(() => { if (opts?.sent) thread.focusComposer() }),
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
    onSwipeBack: ({ from, velocity }) => (from === ARTIFACT ? leaveArtifact({ velocity, swiped: true }) : from === THREAD ? leaveThread({ velocity, swiped: true }) : back(from, { velocity })),
    swipeZone: pane => (pane.dataset.edgeSwipe !== undefined ? 40 : pane.clientWidth * 0.6)
  })

  // ------------------------------------------------------------ navigation
  // History mirrors the strip: entries pushed going forward to a
  // conversation or its details, popped going back.
  const pushed = []
  let skipPop = 0
  let afterPop = null
  // d: how many entries this app has pushed up to this one, so a popstate
  // can tell how many steps it jumped (the long-press history list).
  const entry = (col, d = pushed.length) => ({ duo: col, chat: thread.current, art: col === ARTIFACT ? artifact.current : null, d })

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
        history.pushState(entry(c, pushed.length + 1), '')
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
        history.pushState(entry(THREAD, pushed.length + 1), '')
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
    leaveArtifact()
  })

  /**
   * Back from the details column, but a drawing that hasn't been sent is
   * not thrown away without asking (Close, Escape, the 手绘 tool again, or a
   * swipe back all come here). An empty board closes at once. The same
   * question for every way out (views/draw-guard.js): the browser's Back is
   * with popstate, another conversation with openChat.
   */
  const guard = createDiscardGuard({
    unsaved: () => artifact.unsaved,
    ask: anchor => confirmAction(anchor, { title: '放弃这张手绘？画好的内容不会保存', confirm: '放弃' })
  })
  const mayDiscardDrawing = () => guard.mayDiscard()
  async function leaveArtifact({ velocity = 0, swiped = false } = {}) {
    // A swipe that let go with ink on the board springs back first; the board stays until answered.
    if (swiped && artifact.unsaved) go(ARTIFACT, { velocity })
    if (!await mayDiscardDrawing()) return
    return back(ARTIFACT, { velocity })
  }
  /**
   * The conversation's own back (its button, or a swipe from its edge) while
   * the board is open beside it, unfolded: leaving the conversation would
   * close the board too, so it asks first.
   */
  async function leaveThread({ velocity = 0, swiped = false } = {}) {
    if (artifact.unsaved && strip.shows(ARTIFACT)) {
      if (swiped) go(strip.focus, { velocity })
      if (!await guard.mayDiscard({ focus: 'canvas' })) return
    }
    return back(THREAD, { velocity })
  }

  // ------------------------------------------------------------ a call over the whole app (P2-11)
  // A call that covers the app holds one history entry of its own: the same
  // route and depth as the one under it, plus `call`. Back takes it and only
  // shrinks the call; at most one is ever there.
  let callEntry = false
  function callCover(callId, on) {
    if (on && !callEntry) {
      history.pushState({ ...entry(strip.focus, Number.isInteger(history.state?.d) ? history.state.d : pushed.length), call: callId }, '')
      callEntry = true
    } else if (!on && callEntry) {
      callEntry = false
      skipPop++
      afterPop = null
      history.back()
    }
  }
  /** The call entry was just popped (or Forward landed on a stale one): handled here, the route stays. */
  function callPop(s) {
    if (callEntry && !s.call) {
      callEntry = false
      const steps = Number.isInteger(s.d) ? pushed.length - s.d : 0
      if (onCallBack() === 'ringing') {
        // Still ringing: the entry goes back on, the call stays as it is.
        skipPop++
        afterPop = null
        history.go(steps + 1)
        callEntry = true
      } else if (steps > 0) {
        // A jump of several steps: only the call shrank, back to the entry under it.
        skipPop++
        afterPop = null
        history.go(steps)
      }
      return true
    }
    // Unfolded, a ringing call holds no entry, so the route already went back:
    // straight back to where it was (no list flashes), and only the reminder.
    if (!callEntry && !s.call && callRinging()) {
      const steps = Number.isInteger(s.d) ? pushed.length - s.d : 0
      skipPop++
      afterPop = null
      history.go(steps || 1)
      onCallBack()
      return true
    }
    if (s.call && !callEntry) {
      skipPop++
      afterPop = null
      history.back()
      return true
    }
    return false
  }

  window.addEventListener('popstate', e => {
    if (skipPop) {
      skipPop--
      if (afterPop) history.replaceState(afterPop, '')
      afterPop = null
      return
    }
    // Before the drawing's guard: Back over a full-screen call only shrinks it.
    if (callPop(e.state || {})) return
    const s = e.state || {}
    const col = Number.isInteger(s.duo) ? s.duo : LIST
    const instant = Boolean(e.hasUAVisualTransition)
    // The browser's Back with ink on the board: the entry goes back on, the
    // board stays, and the same question as Close decides (5ba2794). Also
    // Back or Forward onto another conversation's entry (the long-press
    // history list): that would swap the board's conversation away.
    // restore() puts back the entry of what's on screen; 放弃 then takes
    // the step it held.
    const elsewhere = Boolean(s.chat && s.chat !== thread.current && chatInfo(s.chat))
    // How far the browser jumped: back is positive. Entries from before d
    // existed fall back to pushing the current one again.
    const steps = Number.isInteger(s.d) ? pushed.length - s.d : null
    const held = guard.holdPop({
      leaving: strip.shows(ARTIFACT) && (col < strip.focus || elsewhere),
      // Return to the very entry that was showing, so no entry is lost and
      // the ones after it (Forward) stay too.
      restore: () => {
        if (steps) { skipPop++; afterPop = null; history.go(steps) }
        else history.pushState(entry(strip.focus), '')
      },
      leave: () => {
        if (col < strip.focus && steps > 1) {
          // 放弃 after a jump of several steps: take the whole jump.
          skipPop++
          afterPop = null
          history.go(-steps)
          while (pushed.length && pushed.at(-1) > col) pushed.pop()
          return go(col)
        }
        return col < strip.focus ? back(strip.focus) : showChat(s.chat, { focus: false })
      }
    })
    if (held) return
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
    strip.heal()
    if (strip.focus < ARTIFACT && !strip.shows(ARTIFACT)) artifact.clear()
    if (navigated && strip.count === 1 && strip.focus < THREAD && thread.current) {
      thread.close()
      state.open = null
      rememberOpen(null)
      list.setSelected(null)
    }
  }

  /**
   * Another conversation (a notification, the list beside it, search…) while
   * a drawing for this one is unsent: only once it may go. Kept: nothing
   * moves, and the board has the focus again.
   */
  function openChat(id, opts = {}) {
    if (!id) return
    if (artifact.unsaved && strip.shows(ARTIFACT)) {
      // The same conversation (its notification while drawing in it): the
      // board stays as it is; bringing the conversation forward would close it.
      if (id === thread.current) return
      const trigger = document.activeElement
      return guard.before(() => showChat(id, opts), { trigger: panes.some(p => p.contains(trigger)) ? trigger : null })
    }
    return showChat(id, opts)
  }
  function showChat(id, { focus = true } = {}) {
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
    if (strip.focus === ARTIFACT && shown?.kind === kind && shown.chat === chat) return leaveArtifact()
    // Swapping an unsent drawing for the details asks first, as closing does.
    if (artifact.unsaved && kind !== 'draw') {
      return mayDiscardDrawing().then(ok => {
        if (!ok) return
        closeAllOverlays()
        artifact.show(kind, chat)
        return forward(ARTIFACT).then(r => { focusBoard(kind); return r })
      })
    }
    closeAllOverlays()
    artifact.show(kind, chat)
    return forward(ARTIFACT).then(r => { focusBoard(kind); return r })
  }
  // The board takes focus once it's on screen, unfolded too, where the + that
  // opened it would otherwise keep it (UX audit P2-13).
  function focusBoard(kind) {
    const canvas = kind === 'draw' ? artifact.canvas : null
    if (canvas?.isConnected) canvas.focus({ preventScroll: true })
  }
  // Reloading or closing the tab with ink on the board asks too (UX audit P2-8).
  window.addEventListener('beforeunload', e => {
    if (!artifact.unsaved) return
    e.preventDefault()
    e.returnValue = ''
  })

  // ------------------------------------------------------------ touch always lands
  // A touch that reaches no control at all — the shell between columns, the
  // app, the page, a scrim — may be one that something left behind
  // swallowed: a column left unreachable, a scrim without its sheet. Put those right at
  // once, so the next touch lands; and again whenever the app comes back.
  const heal = () => {
    strip.heal()
    healOverlays()
  }
  document.addEventListener('pointerdown', e => {
    const t = e.target
    if (t === shell || t === app || t === document.body || t === document.documentElement || t.matches?.('#overlays > .scrim')) heal()
  }, { capture: true })
  document.addEventListener('visibilitychange', () => { if (!document.hidden) heal() })

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
  strip.setPose(getPose(), { animate: false })
  applyLayout(getLayout())
  onLayout(layout => applyLayout(layout))
  // Half open ↔ flat: the divider glides between the hinge and the
  // conversation's own width (js/ui/columns.js).
  onPose(next => strip.setPose(next))

  const deep = new URLSearchParams(location.search).get('chat')
  if (deep) {
    history.replaceState(entry(LIST), '', location.pathname)
    openChat(deep)
  } else if (getLayout() === 'split') restoreLast({ focus: true })
  list.render()

  return {
    callCover,
    /** After a call shrinks: where focus goes when what had it is gone. */
    focusAfterCall() {
      if (strip.focus === THREAD && thread.current) thread.focusComposer()
      else panes[strip.focus].focus({ preventScroll: true })
    },
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
    setStatus(s) { list.setStatus(s); thread.setStatus(s) }
  }
}
