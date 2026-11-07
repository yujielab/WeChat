// Conversation view.

import { h, icon, clear, reducedMotion, announce, edge, storage } from '../ui/dom.js'
import { ghost, filler } from '../ui/skeleton.js'
import { tip } from '../ui/guides.js'
import { setProgress } from '../ui/reveal.js'
import { symbolEffect, replaceSymbol } from '../ui/symbols.js'
import { threadTime, callSummary, sendState, groupState } from '../ui/format.js'
import { haptic } from '../ui/haptics.js'
import { cancelPress } from '../ui/press.js'
import {
  state, on, thread, mergeMessages, upsertMessage, replaceMessage, removeMessage, chatInfo,
  unreadTotal, newCid, patchRoom, upsertRoom, normMsg, avatarOf, nameOf, setMembers, previewText as listPreview
} from '../store.js'
import { api, ApiError } from '../api.js'
import { outbox, blobStore } from '../outbox.js'
import { stillBelow } from './unread.js'
import { avatar } from './avatar.js'
import { renderBubble, hasTail, mediaSize, callMine, bubbleMeta, fillMeta, spokenMentions } from './bubbles.js'
import { openStickers, mountStickers } from './stickers.js'
import { createComposer, prepareImage } from './composer.js'
import { glassSurface, barShapes } from '../ui/liquid-glass/surface.js'
import { openViewer } from './viewer.js'
import { openMenu, openSheet, toast, confirmAction } from './overlay.js'
import { bindImageDropTarget } from './attachments.js'
import { renderPhotoStack, openPhotoStack, stackSize } from './photo-stack.js'
import { createBars, railed } from '../ui/bars.js'
import { onBars } from '../ui/viewport.js'
import { backdropLayer, paintBackdrop, readBackdrop } from '../ui/backdrops.js'
import { chatBackdrop } from './backdrops.js'

// A mouse or trackpad drag-selects text already (thread.css); touch asks for it from the menu.
const finePointer = matchMedia('(hover: hover) and (pointer: fine)')

const TS_GAP = 5 * 60 * 1000
const RUN_GAP = 3 * 60 * 1000
const PAGE = 60

/** Links in messages come from other people: only ever open http(s). */
const safeUrl = u => {
  try {
    const url = new URL(u)
    return url.protocol === 'https:' || url.protocol === 'http:' ? url.href : null
  } catch {
    return null
  }
}

const isGroup = id => chatInfo(id)?.kind === 'group'
// Not a bubble: the conversation's own notes, and a message taken back
// (which leaves a note in its place, never an empty bubble).
const isSys = m => m.type === 'system' || m.status === 'revoked'
const REACTIONS = ['❤️', '😂', '👍', '😮', '😢', '🙏']
const REACTION_NAMES = { '❤️': 'Love', '😂': 'Laugh', '👍': 'Like', '😮': 'Wow', '😢': 'Sad', '🙏': 'Thanks' }
const reactable = m => m && !isSys(m) && !String(m.id).startsWith('local:') && !['sending', 'failed', 'revoked'].includes(m.status)
const myReaction = m => m.reactions?.find(g => g.users.includes(state.me?.id))?.emoji || ''
// What a bubble shows, apart from its reactions: a reaction alone patches the
// chip in place rather than rebuilding (and re-fading) the whole message.
// What a bubble shows; its key words (src/assist.js) arrive after it and redraw it.
const bodySig = m => [m.type, m.text, m.url, m.status === 'read' ? 'sent' : m.status, m.w, m.h, m.dur, m.name, (m.meta?.keys || []).join('\u0002'), m.edited || 0, quoteSig(m), m.lost ? 'lost' : ''].join('\u0001')
// What a reply's quote shows: the answered message as this device knows it
// now (taken back since?), else as the server last saw it.
function quoted(m) {
  if (!m?.replyTo) return null
  const live = state.threads.get(m.chat)?.byId.get(m.replyTo)
  if (live) return { id: live.id, sender: live.from, type: live.type, state: live.status, body: live.text, url: live.url, emoji: live.meta?.emoji }
  return m.reply || { id: m.replyTo, missing: true }
}
const quoteSig = m => {
  const q = quoted(m)
  return q ? [q.id, q.state === 'revoked' ? 'r' : '', q.body || '', q.url || ''].join('\u0003') : ''
}
/** One line saying what a message is, for a quote of it. */
export function quotePreview(q) {
  if (!q || q.missing) return 'Original message unavailable'
  if (q.state === 'revoked') return 'Original message was unsent'
  if (q.type === 'image') return '[Photo]'
  if (q.type === 'drawing') return '[Drawing]'
  if (q.type === 'sticker') return `[Sticker]${q.emoji ? ` ${q.emoji}` : ''}`
  if (q.type === 'voice') return '[Voice]'
  if (q.type === 'video') return '[Video]'
  if (q.type === 'file') return '[File]'
  return String(q.body || '').replace(/\s+/g, ' ')
}
// A text message can be rewritten by whoever sent it, for 15 minutes, five
// times (the server holds the same rule: src/store.js editProblem).
const EDIT_WINDOW = 15 * 60 * 1000
const EDIT_MAX = 5
const editable = m => m?.out && m.type === 'text' && reactable(m) && Date.now() - m.ts <= EDIT_WINDOW && (m.edited || 0) < EDIT_MAX
const reactSig = m => (m.reactions || []).map(g => `${g.emoji}${g.users.join(',')}`).join('|')

/** Apply one person's reaction locally, mirroring the server's one-per-person rule. */
function withReaction(groups = [], uid, emoji) {
  const next = groups.map(g => ({ ...g, users: g.users.filter(u => u !== uid) })).filter(g => g.users.length)
  if (!emoji) return next
  const group = next.find(g => g.emoji === emoji)
  if (group) group.users.push(uid)
  else next.push({ emoji, users: [uid] })
  return next
}
const sameRun = (a, b) =>
  a && b && !isSys(a) && !isSys(b) && a.out === b.out && a.from === b.from && b.ts - a.ts < RUN_GAP

// The bubble as it is on screen, to lift above the blur. A plain copy would
// lose what it takes from the conversation around it (its row, side and
// column) and could size or wrap differently; so each element's computed
// look is written onto its copy, and the copy keeps the bubble's box.
const FROZEN = [
  'font-family', 'font-size', 'font-weight', 'font-style', 'line-height', 'letter-spacing', 'word-spacing',
  'text-align', 'text-decoration-line', 'white-space', 'overflow-wrap', 'word-break', 'color',
  'background-color', 'background-image', 'opacity', 'display', 'flex-direction', 'flex-wrap', 'align-items',
  'justify-content', 'gap', 'border-top-left-radius', 'border-top-right-radius', 'border-bottom-left-radius',
  'border-bottom-right-radius', 'padding-top', 'padding-right', 'padding-bottom', 'padding-left', 'object-fit'
]
/** An element's border-box size as laid out, with fractions and without its transform. */
function layoutSize(el) {
  const cs = getComputedStyle(el)
  let w = parseFloat(cs.width)
  let ht = parseFloat(cs.height)
  if (!(w > 0) || !(ht > 0)) return { w: el.offsetWidth, ht: el.offsetHeight }
  if (cs.boxSizing !== 'border-box') {
    const sum = (...props) => props.reduce((n, p) => n + (parseFloat(cs.getPropertyValue(p)) || 0), 0)
    w += sum('padding-left', 'padding-right', 'border-left-width', 'border-right-width')
    ht += sum('padding-top', 'padding-bottom', 'border-top-width', 'border-bottom-width')
  }
  return { w, ht }
}

function liftedCopy(bubble, width, height) {
  const copy = bubble.cloneNode(true)
  const from = [bubble, ...bubble.querySelectorAll('*')]
  const to = [copy, ...copy.querySelectorAll('*')]
  from.forEach((el, i) => {
    const cs = getComputedStyle(el)
    for (const p of FROZEN) to[i].style.setProperty(p, cs.getPropertyValue(p))
    // Blocks inside keep their laid-out size too (photos, cards).
    if (i && el instanceof HTMLElement && cs.display !== 'inline') {
      to[i].style.width = `${el.offsetWidth}px`
      to[i].style.height = `${el.offsetHeight}px`
    }
  })
  copy.classList.remove('is-pressed', 'tail')
  Object.assign(copy.style, { boxSizing: 'border-box', width: `${width}px`, height: `${height}px`, maxWidth: 'none', margin: '0', transform: 'none', visibility: 'visible' })
  return copy
}

export function createThread(pane, { onBack, onInfo, onDraw, onCall, socketSend }) {
  pane.classList.add('pane-thread')
  // Back is a swipe from the leading edge only: across a message, a swipe
  // to the right answers it (as in Messages).
  pane.dataset.edgeSwipe = ''
  let current = null
  let editingId = null // the message whose words are in the field
  let newCount = 0
  let newIds = [] // the new messages behind newCount, oldest first
  let suppressClick = false
  const nodes = new Map()
  const seps = new Map()
  const retryFiles = new Map()
  const photoGroups = new Map()
  const expandedPhotos = new Set()
  const expandedCalls = new Set()
  const retrying = new Set()
  const ctx = { maxMedia: 240 }
  let readingAnchor = { bottom: true }

  // ------------------------------------------------------------ skeleton
  const olderEl = h('div', { class: 'load-older', 'aria-live': 'polite' })
  const meta = h('div', { class: 'm-meta' })
  const msgs = h('div', { class: 'msgs' }, olderEl)
  // Room for the floating bar is a real element at the foot of the log, not
  // the scroller's padding: Safari leaves a column-reverse scroller's bottom
  // padding out of what it scrolls, so the newest message ended up under the
  // field.
  const foot = h('div', { class: 'thread-foot', 'aria-hidden': 'true' })
  const scroller = h('div', { class: 'scroll thread-scroll', role: 'log', 'aria-label': 'Messages' }, foot, msgs)
  scroller.style.overflowAnchor = 'none'
  // While a conversation's first page loads with nothing kept from before: its
  // messages' skeleton, made by the real message builder (ui/skeleton.js), in
  // a box of its own beside the log so nothing mistakes it for messages.
  let ghostBox = null
  let ghostTimer = 0
  // Only when the page is slow to come: a quick one simply appears, with no skeleton flashing first.
  function showGhost() {
    hideGhost()
    ghostTimer = setTimeout(paintGhost, 250)
  }
  function paintGhost() {
    const me = state.me?.id
    const lines = [[3, false], [6, false], [2, true], [8, true], [4, false], [5, true], [3, true]]
    const nodes = lines.map(([n, out], i) => buildNode({ id: `sk-${i}`, chat: current, type: 'text', text: filler(n, i), out, from: out ? me : `sk-peer`, ts: Date.now(), status: 'read' }))
    ghostBox = h('div', { class: 'msgs-ghost' }, ghost(nodes))
    scroller.insertBefore(ghostBox, msgs)
  }
  // Once: holding a message is where reacting, replying and editing are (ui/guides.js).
  function tipHold() {
    if (!msgs.querySelector('.m.in')) return
    tip('hold', '.thread:not([hidden]) .msgs .m.in:last-of-type .bubble', { title: 'Hold a message', text: 'To react, reply or copy it — and to edit or unsend your own.' })
  }
  function hideGhost() {
    clearTimeout(ghostTimer)
    if (!ghostBox) return
    ghostBox.remove()
    ghostBox = null
    if (!reducedMotion()) { msgs.classList.remove('skeleton-gone'); void msgs.offsetWidth; msgs.classList.add('skeleton-gone') }
  }

  // The conversation's heading is content: it stays with the messages on
  // every display, and opens the chat's details.
  const titleName = h('span', { class: 'name' })
  const titleSub = h('span', { class: 'sub' })
  const titleAvatar = h('span', { class: 'thread-person' })
  const titleBtn = h('button', { class: 'glass glass-pill thread-title', type: 'button' }, titleAvatar, h('span', { class: 't' }, titleName, titleSub))
  const nav = h('header', { class: 'thread-nav' }, titleBtn)

  // The calls and the details sit in the heading, after the name; Back
  // leads the bar at the foot of the conversation, before the field, and the
  // field's own button (photos and drawing, or Send) follows it. Unfolded
  // there is no Back: beside the list the list is right there, and beside
  // the details their Close does the same (back to the list and the
  // conversation), so the one way out is in the column being left. Details open
  // in the next column, so their item shows whether it's open. Where the
  // system keeps its column on the right edge (the Duo) they all stand in a
  // rail there instead — Back, the calls, the details — and the heading and
  // the field keep to the content.
  const unreadBadge = () => {
    const n = current ? unreadTotal(current) : 0
    return n ? (n > 99 ? '99+' : String(n)) : ''
  }
  const bars = createBars({
    label: 'Chat actions',
    items: [
      { id: 'back', icon: 'chevron-left', title: 'Back to chats', primary: true, badge: unreadBadge, onSelect: () => onBack() },
      { id: 'audio', icon: 'phone', title: 'Voice call', priority: 6, onSelect: () => current && onCall?.(current, 'audio') },
      { id: 'video', icon: 'video', title: 'Video call', priority: 5, onSelect: () => current && onCall?.(current, 'video') },
      { id: 'info', icon: 'info', title: 'Chat info', priority: 2, toggle: true, onSelect: () => current && onInfo(current) },
    ],
    arrange: axis => {
      // Calls only where the server can carry them.
      const calls = state.calls?.enabled ? [['audio', 'video']] : []
      const back = pane.dataset.layout === 'single' ? [['back']] : []
      return axis === 'vertical' ? { top: [...back, ...calls, ['info']], bottom: [] } : { top: [...calls, ['info']], bottom: back }
    }
  })
  const rail = h('nav', { class: 'duo-rail thread-rail', 'aria-label': 'Chat actions' })

  const jumpBadge = h('span', { class: 'badge', hidden: true })
  const jump = h('button', { class: 'glass glass-btn jump', type: 'button', 'aria-label': 'Jump to latest' }, icon('chevron-down'), jumpBadge)

  // Mentions of me not yet seen in this conversation: a capsule jumps to each in turn.
  let mentionIds = []
  const mentionCount = h('span', { class: 'jump-pill-count' })
  const mentionPill = h('button', { class: 'jump-pill mention-jump', type: 'button', hidden: true }, h('span', { 'aria-hidden': 'true' }, '@'), mentionCount)
  mentionPill.addEventListener('click', () => {
    const id = mentionIds.shift()
    showMentions()
    if (id) jumpTo(id)
  })
  function showMentions() {
    mentionPill.hidden = !mentionIds.length
    mentionCount.textContent = String(mentionIds.length)
    mentionPill.setAttribute('aria-label', `${mentionIds.length} messages mention you, tap to view`)
    syncPills()
  }

  // Opened with unread messages: it opens at the first of them, and the
  // rest wait below behind "↓ N new messages" (to the latest; gone at the
  // bottom). Scrolled up when more arrive: they don't pull the conversation
  // down; "↓ New messages N" at the foot does. The foot has one capsule at a time:
  // a mention of me first, then new messages (the round button stays for
  // "back to the latest" with nothing new).
  let unreadSince = Infinity // messages after this were unread on arrival
  let unreadTotal0 = 0
  let unreadUpTo = Infinity // …and before this (what had arrived by the time it opened)
  let openedUnread = false // the capsule counts what was unread on arrival
  const downLabel = h('span', {}, 'New messages')
  const downCount = h('span', { class: 'jump-pill-count' })
  const downPill = h('button', { class: 'jump-pill down', type: 'button', hidden: true }, icon('chevron-down'), downLabel, downCount)
  downPill.addEventListener('click', () => scrollToBottom(true))
  function syncPills() {
    const down = newCount > 0 && !mentionIds.length
    downPill.hidden = !down
    const n = newCount > 99 ? '99+' : String(newCount)
    downLabel.textContent = openedUnread ? `${n} new messages` : 'New messages'
    downCount.textContent = n
    downCount.hidden = openedUnread
    downPill.setAttribute('aria-label', `${newCount} new messages, tap to jump to latest`)
    // The round button gives way to the capsule that says more.
    jump.hidden = down
  }
  /** The count is what's still below the foot: it goes down as they come into view. */
  function recountBelow() {
    if (!newIds.length) return
    const line = composer.el.getBoundingClientRect().top
    const topOf = id => {
      const group = nodes.has(id) ? null : [...photoGroups].find(([, photos]) => photos.some(p => p.id === id))
      const node = nodes.get(group ? group[0] : id)
      return node?.isConnected ? node.getBoundingClientRect().top : null
    }
    newIds = stillBelow(newIds, topOf, line)
    newCount = newIds.length
    if (!newCount) openedUnread = false
    jumpBadge.textContent = newCount > 99 ? '99+' : String(newCount)
    jumpBadge.hidden = !newCount
    syncPills()
  }
  // Counted the way the list counts its badge: the last N from others. The
  // cached read mark can lag behind the server's, so it only bounds the search.
  const unreadCandidates = () => current
    ? thread(current).list.filter(m => m.ts > unreadSince && m.ts <= unreadUpTo && !m.out && !isSys(m) && m.status !== 'revoked')
    : []
  const firstUnread = () => {
    const c = unreadCandidates()
    return c.length > unreadTotal0 ? c[c.length - unreadTotal0] : c[0]
  }
  /** Open at the first unread (loading older pages for it), or stay at the bottom when they all fit. */
  async function openAtFirstUnread(chat) {
    const t = thread(chat)
    for (let i = 0; i < 20 && t.hasMore && unreadCandidates().length < unreadTotal0 && (t.list[0]?.ts || 0) > unreadSince; i++) {
      if (t.loading) await new Promise(r => setTimeout(r, 120))
      else await loadOlder()
      if (current !== chat) return
    }
    // Not found within 20 pages: as far back as was loaded.
    const found = unreadCandidates().length >= unreadTotal0 || !t.hasMore
    const first = found ? firstUnread() : t.list.find(m => !isSys(m))
    if (!first) return
    // "New messages below" just above it, for as long as the conversation stays open.
    if (found) {
      dividerAt = first.id
      keepPosition(reconcile)
    }
    const node = nodes.get(first.id)
    if (!node?.isConnected) return
    // All of them on screen from the bottom: nothing to move.
    if (node.getBoundingClientRect().top >= nav.getBoundingClientRect().bottom) return
    await jumpTo(first.id, { flash: false, instant: true })
    if (current !== chat || atBottom()) return
    openedUnread = true
    newIds = unreadCandidates().slice(-unreadTotal0).map(m => m.id)
    newCount = newIds.length
    recountBelow()
  }
  let dividerAt = null
  let roomsFresh = !state.restored
  const freshWaiters = []
  on('chats', ids => {
    if (ids !== null) return
    roomsFresh = true
    for (const done of freshWaiters.splice(0)) done()
  })
  const unreadDivider = h('div', { class: 'ts unread-divider', role: 'separator', 'aria-label': 'New messages below' }, 'New messages below')

  // Read receipts follow the eyes: the newest message from others that has
  // actually been on screen (between the heading and the composer) is what
  // the read mark says, and the list's badge counts what's left below it.
  let seenIO = null
  let readUpTo = 0 // newest message seen
  let readSent = 0 // what the server was last told
  let readFloor = Infinity // older than this was read before opening
  function watchSeen() {
    seenIO?.disconnect()
    const top = Math.max(0, nav.getBoundingClientRect().bottom - scroller.getBoundingClientRect().top)
    const foot = Math.max(0, scroller.getBoundingClientRect().bottom - composer.el.getBoundingClientRect().top)
    seenIO = new IntersectionObserver(entries => {
      let moved = false
      for (const e of entries) {
        if (!e.isIntersecting) continue
        // Half of it, or half the screen for one taller than that.
        const enough = e.intersectionRatio >= 0.5 || e.intersectionRect.height >= (e.rootBounds?.height || Infinity) / 2
        if (!enough) continue
        const m = msgOf(e.target)
        if (m && m.ts > readUpTo && !String(m.id).startsWith('local:')) {
          readUpTo = m.ts
          moved = true
        }
      }
      if (moved) markReadSoon()
    }, { root: scroller, rootMargin: `-${Math.round(top)}px 0px -${Math.round(foot)}px 0px`, threshold: [0, 0.5, 1] })
    for (const el of nodes.values()) if (el.isConnected) seenIO.observe(el)
  }
  const mentionsMe = m => !m.out && m.status !== 'revoked' && Array.isArray(m.meta?.mentions) && m.meta.mentions.includes(state.me?.id)
  /** Whether a message's row is on screen, between the heading and the bar. */
  function onScreen(id) {
    const node = nodes.get(id)
    if (!node?.isConnected) return false
    const r = node.getBoundingClientRect()
    return r.bottom > nav.getBoundingClientRect().bottom && r.top < composer.el.getBoundingClientRect().top
  }

  const composer = createComposer({
    onSend: (text, { replyTo, mentions } = {}) => sendText(text, current, replyTo, mentions),
    // In a group, @ offers its members: whoever spoke last first.
    mentionable: () => {
      if (!current || !isGroup(current)) return null
      const members = [...(state.members.get(current)?.values() || [])].filter(u => u.id !== state.me?.id)
      const spoke = new Map()
      thread(current).list.forEach((m, i) => { if (m.from) spoke.set(m.from, i) })
      return members.sort((a, b) => (spoke.get(b.id) ?? -1) - (spoke.get(a.id) ?? -1) || a.display.localeCompare(b.display, 'zh'))
    },
    onImages: (files, options) => sendImages(files, options),
    onHeight: px => root.style.setProperty('--composer-h', `${px}px`),
    onType: text => sendTyping(text),
    // Photos and the drawing board come from the button after the field.
    tools: [
      { id: 'photo', icon: 'photo', title: 'Photo', onSelect: () => current && composer.openImages() },
      { id: 'sticker', icon: 'face', title: 'Sticker', onSelect: () => current && openStickers({ onPick: st => sendSticker(st, current, composer.takeReply()), origin: composer.el.querySelector('.composer-action') }) },
      { id: 'draw', icon: 'brush', title: 'Drawing', onSelect: () => current && onDraw(current) }
    ]
  })

  const edgeTop = edge('top')
  // What was chosen to sit behind this conversation (views/backdrops.js).
  const backdrop = backdropLayer('', 'thread-backdrop')
  // While the connection is down the conversation says so too, just above
  // the field (the list's .offline-banner, in this column); it goes by
  // itself once connected. A drop shorter than a second shows nothing.
  const offline = h('div', { class: 'offline-banner glass', role: 'status', hidden: true },
    icon('wifi'), h('div', { class: 'grow' }, h('b', {}, 'Connecting…')))
  let offlineEffect = null
  let offlineTimer = 0
  function setOffline(on) {
    clearTimeout(offlineTimer)
    if (!on) {
      offline.hidden = true
      offlineEffect?.stop()
      offlineEffect = null
      return
    }
    if (!offline.hidden) return
    offlineTimer = setTimeout(() => {
      offline.hidden = false
      // Capsules at the foot stack above it rather than under it.
      root.style.setProperty('--banner-h', `${offline.offsetHeight}px`)
      if (!reducedMotion()) offlineEffect = symbolEffect(offline.querySelector('.icon'), 'variable-color')
    }, 1000)
  }
  const root = h('div', { class: 'thread', hidden: true }, backdrop, scroller, edgeTop, nav, rail, composer.el, jump, downPill, mentionPill, offline)
  composer.el.classList.add('dock')

  // Bars follow the window: the rail where the system's column is, else the
  // heading and the foot. The name keeps at least 150px of the heading; the
  // field keeps at least 160px of the bar at the foot, and its 56pt button
  // after it.
  let barsFrame = 0
  function arrangeBars() {
    cancelAnimationFrame(barsFrame)
    barsFrame = requestAnimationFrame(() => {
      const vertical = railed(pane)
      root.dataset.bars = vertical ? 'vertical' : 'horizontal'
      if (vertical) {
        if (bars.top.parentElement !== rail) bars.move(() => { composer.dock(null); rail.append(bars.top, bars.bottom) })
        bars.layout('vertical', rail.clientHeight)
      } else {
        if (bars.top.parentElement !== nav) bars.move(() => { nav.append(bars.top); composer.dock(bars.bottom) })
        const cs = getComputedStyle(composer.el)
        const inner = composer.el.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight)
        bars.layout('horizontal', { top: Math.max(0, nav.clientWidth - 150), bottom: Math.max(0, inner - 160 - 8 - 56 - 8) })
      }
      // The bar buttons moved or changed: their glass follows.
      navGlass.sync()
      railGlass.sync()
      composer.refreshGlass()
    })
  }
  // The heading's and the rail's buttons are drawn as Liquid Glass too
  // (ui/liquid-glass), over the same backdrop.
  const navGlass = glassSurface(nav, () => barShapes(nav))
  const railGlass = glassSurface(rail, () => barShapes(rail))
  new ResizeObserver(arrangeBars).observe(rail)
  new ResizeObserver(arrangeBars).observe(nav)
  new ResizeObserver(arrangeBars).observe(composer.el)
  onBars(arrangeBars)
  bindImageDropTarget(root, { onFiles: files => composer.openImages(files), enabled: () => Boolean(current) })
  // No conversation open: the column is plain paper.
  const empty = h('div', { class: 'thread-empty' })
  pane.append(empty, root)

  titleBtn.addEventListener('click', () => current && onInfo(current))
  jump.addEventListener('click', () => scrollToBottom(true))

  let lastWidth = 0, lastHeight = 0
  new ResizeObserver(([e]) => {
    const { width, height } = e.contentRect
    if (width === lastWidth && height === lastHeight) return
    lastWidth = width; lastHeight = height
    ctx.maxMedia = Math.floor(Math.max(96, Math.min(280, width - 42)))
    if (!current) return
    const anchor = readingAnchor
    for (const [id, node] of nodes) {
      const message = thread(current).byId.get(id)
      const photos = photoGroups.get(id)
      if (photos) {
        const bubble = node.querySelector('.photo-stack')
        const [w, h] = stackSize(photos[0], ctx.maxMedia)
        bubble.style.setProperty('--w', `${w}px`)
        bubble.style.setProperty('--h', `${h}px`)
        bubble.style.setProperty('--photo-ratio', `${w} / ${h}`)
        continue
      }
      const bubble = node.querySelector('.bubble.media:not(.photo-stack)')
      if (!message || !bubble) continue
      const [w, h] = mediaSize(message.w, message.h, Math.max(64, ctx.maxMedia - (message.status === 'failed' && !message.lost ? 34 : 0)), message.type === 'video' ? 300 : 320)
      bubble.style.setProperty('--w', `${w}px`)
      bubble.style.setProperty('--h', `${h}px`)
    }
    restoreReadingAnchor(anchor)
    rememberReadingAnchor()
  }).observe(scroller)


  // ------------------------------------------------------------ rendering
  function sepFor(m) {
    let el = seps.get(m.id)
    if (!el) {
      const [day, time] = threadTime(m.ts)
      el = h('div', { class: 'ts', role: 'separator', 'aria-label': `${day} ${time}` }, h('b', {}, day), ` ${time}`)
      seps.set(m.id, el)
    }
    return el
  }

  // Who took it back, said where the bubble was.
  function revokedNote(m) {
    return m.out ? 'You unsent a message' : `${m.fromName || nameOf(m.from, current) || 'They'} unsent a message`
  }

  function buildNode(m) {
    if (isSys(m)) return h('div', { class: 'sys', dataset: { id: m.id } }, m.status === 'revoked' ? revokedNote(m) : m.text || '')
    const room = isGroup(current)
    const who = m.fromName || nameOf(m.from, current)
    // Its picture lost: Choose again sits in the cell itself, which keeps its size.
    const lost = m.status === 'failed' && m.lost
    const retryShown = (m.status === 'failed' && !lost) || (m.status === 'sending' && retrying.has(m.id))
    const bub = renderBubble(m, retryShown ? { ...ctx, maxMedia: Math.max(64, ctx.maxMedia - 78) } : ctx)
    const sender = room && !m.out ? h('div', { class: 'm-sender' }, who) : null
    const av = h('span', { class: 'm-avatar', 'aria-hidden': 'true' }, avatar(avatarOf(m.from, current), who))
    // Where it failed: a compact Retry beside the message itself, which turns
    // into Sending in place while it goes, and folds away once it's sent.
    const status = lost ? null : m.status === 'failed'
      ? h('button', { class: 'm-retry', type: 'button', 'aria-label': 'Send failed, retry' }, icon('refresh'), h('span', { 'aria-hidden': 'true' }, 'Retry'))
      : retryShown ? h('span', { class: 'm-retry busy', role: 'status', 'aria-label': 'Resending' }, h('span', { class: 'spinner' }), h('span', { 'aria-hidden': 'true' }, 'Sending'))
        : null
    // A reply carries the message it answers: inside a text bubble, above any other.
    const quote = quoteBlock(m)
    const inside = quote && bub.classList.contains('text')
    if (inside) bub.prepend(quote)
    // Time and ticks live in the bubble's corner (a lost picture's cell too:
    // CSS keeps it clear of Choose again).
    bub.append(bubbleMeta(m, isRead(m), isDm()))
    const el = h('div', {
      class: ['m', 'has-avatar', m.out ? 'out' : 'in', room ? (m.out ? 'room-out' : 'room-in') : 'dm'],
      dataset: { id: m.id }
    }, av, h('div', { class: 'm-col' }, sender, inside ? null : quote, bub, reactionChip(m), editedNote(m)), status)
    if (editingId === m.id) el.classList.add('editing')
    el.bodySig = bodySig(m)
    el.reactSig = reactSig(m)
    return el
  }

  /** The message a reply answers: who, and its first line; tapped, it scrolls there. */
  function quoteBlock(m) {
    const q = quoted(m)
    if (!q) return null
    const gone = q.missing || q.state === 'revoked'
    const who = gone && q.missing ? '' : q.sender === state.me?.id ? 'You' : nameOf(q.sender, m.chat) || 'them'
    const text = quotePreview(q)
    return h('button', {
      class: ['quote', gone && 'is-recalled'],
      type: 'button',
      'aria-label': gone ? `Reply: ${text}` : `Reply to ${who}: ${spokenMentions(text, state.threads.get(m.chat)?.byId.get(m.replyTo))}, tap to view original`,
      'aria-disabled': gone ? 'true' : null
    }, who ? h('span', { class: 'quote-name' }, who) : null, h('span', { class: 'quote-text' }, text))
  }

  /** Rewritten by its sender: says so under the bubble; tapped, shows each wording. */
  function editedNote(m) {
    if (!m.edited || isSys(m)) return null
    const b = h('button', { class: 'm-edited', type: 'button', 'aria-label': 'Edited, view edit history' }, 'Edited')
    b.addEventListener('click', () => showEdits(m.id))
    return b
  }

  /** Reactions hang off the bubble's lower edge, away from its tail (sketch 1). */
  function reactionChip(m) {
    const groups = m.reactions || []
    if (!groups.length) return null
    const total = groups.reduce((n, g) => n + g.users.length, 0)
    return h('button', {
      class: ['m-reactions', myReaction(m) && 'mine'],
      type: 'button',
      'aria-label': `Reactions: ${groups.map(g => `${REACTION_NAMES[g.emoji] || g.emoji} ${g.users.length}`).join(', ')}, tap to change`
    }, groups.map(g => h('span', { class: 'm-reaction', 'aria-hidden': 'true' }, g.emoji)),
    total > 1 ? h('span', { class: 'm-reaction-count tabular', 'aria-hidden': 'true' }, `${total}`) : null)
  }

  function updateReactions(node, m) {
    const sig = reactSig(m)
    if (node.reactSig === sig) return
    const grew = sig.length > (node.reactSig || '').length
    node.reactSig = sig
    const col = node.querySelector('.m-col')
    const next = reactionChip(m)
    const prev = col.querySelector('.m-reactions')
    if (prev && next) prev.replaceWith(next)
    else if (next) col.append(next)
    else prev?.remove()
    if (next && grew && !reducedMotion()) {
      next.classList.add('pop')
      next.addEventListener('animationend', () => next.classList.remove('pop'), { once: true })
    }
  }

  function nodeFor(m) {
    let el = nodes.get(m.id)
    if (!el || el.photoSignature || el.callSignature) {
      const old = el
      el = buildNode(m)
      old?.replaceWith(el)
      nodes.set(m.id, el)
    }
    return el
  }

  const groupablePhoto = m => m?.type === 'image' && m.url && !m.replyTo && !['sending', 'failed', 'revoked'].includes(m.status) && !String(m.id).startsWith('local:') && !expandedPhotos.has(m.id)
  function expandPhotos(photos) {
    const group = nodes.get(photos[photos.length - 1]?.id)
    const offset = group ? group.getBoundingClientRect().top - scroller.getBoundingClientRect().top : null
    for (const photo of photos) expandedPhotos.add(photo.id)
    keepPosition(reconcile)
    const first = nodes.get(photos[0]?.id)
    if (offset !== null) restoreReadingAnchor({ id: photos[0].id, offset })
    rememberReadingAnchor()
    first?.querySelector('.bubble')?.setAttribute('tabindex', '-1')
    first?.querySelector('.bubble')?.focus({ preventScroll: true })
  }
  function photoNode(photos) {
    const last = photos[photos.length - 1]
    const signature = photos.map(photo => `${photo.id}:${photo.url}`).join('|')
    let node = nodes.get(last.id)
    if (node?.photoSignature !== signature) {
      const fresh = buildNode(last)
      const who = last.out ? 'You' : last.fromName || nameOf(last.from, current)
      const sender = {
        avatar: avatar(avatarOf(last.from, current), who, { size: 30 }),
        label: `${who} · ${threadTime(photos[0].ts)[1]}`
      }
      const stack = renderPhotoStack(photos, ctx, { onExpand: expandPhotos, sender })
      stack.append(bubbleMeta({ ...last, type: 'image-stack' }, false, isDm()))
      fresh.querySelector('.bubble').replaceWith(stack)
      fresh.classList.add('has-stack')
      fresh.photoSignature = signature
      node?.replaceWith(fresh)
      node = fresh
      nodes.set(last.id, node)
    }
    photoGroups.set(last.id, photos)
    return node
  }

  // Unanswered calls one after another from the same side, with nothing said
  // between and within the hour, fold into one compact record that opens
  // upward, so what was tapped stays where it is; every call stays listed
  // inside. A call that went through always stands on its own.
  const groupableCall = m => m?.type === 'call' && m.status !== 'revoked' && !String(m.id).startsWith('local:') && (m.call?.result ? m.call.result !== 'completed' : Boolean(m.call?.missed))
  const CALL_SPAN = 60 * 60 * 1000
  function callGroupNode(calls) {
    const last = calls[calls.length - 1]
    const signature = calls.map(c => `${c.id}:${c.call?.result || ''}`).join('|')
    let node = nodes.get(last.id)
    if (node?.callSignature !== signature) {
      const fresh = buildNode(last)
      fresh.querySelector('.bubble').replaceWith(callGroup(calls))
      fresh.callSignature = signature
      fresh.callIds = calls.map(c => c.id)
      node?.replaceWith(fresh)
      node = fresh
      nodes.set(last.id, node)
    }
    return node
  }
  function callGroup(calls) {
    const key = calls[0].id
    const open = expandedCalls.has(key)
    const said = c => callSummary(c.call || {}, callMine(c))
    const glyph = s => icon(s.media === 'Video' ? 'video' : 'phone')
    const latest = said(calls[calls.length - 1])
    const listId = `calls-${String(key).replace(/[^\w-]/g, '')}`
    const items = h('div', { class: 'call-items', id: listId },
      h('div', { class: 'call-items-inner', role: 'list' }, calls.map(c => {
        const s = said(c)
        return h('div', { class: ['call-item', s.missed && 'missed'], role: 'listitem', 'aria-label': `${s.label}，${threadTime(c.ts)[1]}` },
          glyph(s), h('span', { class: 't', 'aria-hidden': 'true' }, s.text), h('span', { class: 'when tabular', 'aria-hidden': 'true' }, threadTime(c.ts)[1]))
      })))
    const toggle = h('button', {
      class: 'call-summary', type: 'button', 'aria-expanded': String(open), 'aria-controls': listId,
      'aria-label': `${latest.label}, ${calls.length} calls${open ? '' : ', tap to expand'}`
    }, glyph(latest), h('span', { class: 't', 'aria-hidden': 'true' }, latest.text),
    h('span', { class: 'call-count tabular', 'aria-hidden': 'true' }, `${calls.length}`), icon('chevron-down', 'call-chevron'))
    const group = h('div', { class: ['bubble call-log call-group', open && 'open', latest.missed && 'missed'], dataset: { kind: 'call-group' } }, items, toggle, bubbleMeta(calls[calls.length - 1], false, isDm()))
    toggle.addEventListener('click', () => {
      const on = !group.classList.contains('open')
      group.classList.toggle('open', on)
      toggle.setAttribute('aria-expanded', String(on))
      toggle.setAttribute('aria-label', `${latest.label}, ${calls.length} calls${on ? '' : ', tap to expand'}`)
      if (on) expandedCalls.add(key)
      else expandedCalls.delete(key)
    })
    return group
  }

  function decorate(list) {
    for (let i = 0; i < list.length; i++) {
      const m = list[i]
      const el = nodes.get(m.id)
      if (!el || isSys(m)) continue
      const prev = list[i - 1]
      const next = list[i + 1]
      const sepBefore = !prev || m.ts - prev.ts > TS_GAP
      const sepAfter = !next || next.ts - m.ts > TS_GAP
      const first = sepBefore || !sameRun(prev, m)
      const last = sepAfter || !sameRun(m, next)
      el.classList.toggle('first', first)
      el.classList.toggle('last', last)
      el.querySelector('.bubble')?.classList.toggle('tail', last && hasTail(m))
      const sender = el.querySelector('.m-sender')
      if (sender) sender.hidden = !first
    }
  }

  // Only a 1:1 chat (chatInfo kind 'dm') ever shows read; groups never.
  const isDm = () => chatInfo(current)?.kind === 'dm'

  // Read: the message itself says so, or (DMs) the peer read up to it.
  function isRead(m) {
    if (!m?.out) return false
    const c = chatInfo(current)
    if (!isDm()) return false
    return m.status === 'read' || Boolean(c.peerRead && m.ts <= c.peerRead && !String(m.id).startsWith('local:') && m.status !== 'sending' && m.status !== 'failed')
  }

  // Every bubble's corner follows its message (read receipts don't rebuild
  // a node); the Not sent line sits under the newest outgoing message's bubble,
  // in its column, so it lines up with the bubble's right edge.
  function placeMeta(list) {
    const t = thread(current)
    for (const [id, node] of nodes) {
      const m = t.byId.get(id)
      const corner = m && node.querySelector(':scope > .m-col > .bubble > .m-meta')
      if (!corner) continue
      // A folded group shows its last message's time and its weakest state.
      const dm = isDm()
      const group = photoGroups.get(id) || node.callIds?.map(x => t.byId.get(x)).filter(Boolean)
      const s = group ? groupState(group.map(x => sendState(x, isRead(x), dm))) : sendState(m, isRead(m), dm)
      const shown = photoGroups.has(id) ? { ...m, type: 'image-stack' } : m
      if (corner.metaSig !== `${s?.state || ''}|${m.ts}`) fillMeta(corner, shown, false, s)
    }
    const lastOut = [...list].reverse().find(m => m.out && !isSys(m))
    if (!lastOut || lastOut.status !== 'failed') {
      meta.remove()
      return
    }
    meta.className = 'm-meta failed'
    meta.textContent = 'Not sent'
    meta.setAttribute('aria-hidden', 'true')
    const col = nodes.get(lastOut.id)?.querySelector(':scope > .m-col')
    if (col && meta.parentNode !== col) col.append(meta)
  }

  /** Bring the DOM in line with the thread's message list, reusing nodes. */
  function reconcile() {
    const t = thread(current)
    const list = t.list
    const want = []
    const visible = []
    photoGroups.clear()
    let prev = null
    for (let i = 0; i < list.length; i++) {
      const first = list[i]
      const photos = [first]
      if (groupablePhoto(first)) {
        while (photos.length < 10 && i + 1 < list.length) {
          const next = list[i + 1]
          const last = photos[photos.length - 1]
          if (!groupablePhoto(next) || next.from !== first.from || next.out !== first.out || next.ts - last.ts > 60000) break
          photos.push(next)
          i++
        }
      }
      const calls = [first]
      if (photos.length === 1 && groupableCall(first)) {
        while (calls.length < 20 && i + 1 < list.length) {
          const next = list[i + 1]
          if (!groupableCall(next) || callMine(next) !== callMine(first) || next.ts - calls[calls.length - 1].ts > TS_GAP || next.ts - first.ts > CALL_SPAN) break
          calls.push(next)
          i++
        }
      }
      const run = calls.length > 1 ? calls : photos
      const last = run[run.length - 1]
      const message = run.length > 1 ? { ...last, ts: first.ts } : first
      if (!prev || first.ts - prev.ts > TS_GAP) want.push(sepFor(message))
      if (dividerAt && run.some(x => x.id === dividerAt)) want.push(unreadDivider)
      want.push(calls.length > 1 ? callGroupNode(calls) : photos.length > 1 ? photoNode(photos) : nodeFor(message))
      visible.push(message)
      prev = last
    }
    const keep = new Set(want)
    if (!keep.has(unreadDivider)) unreadDivider.remove()
    for (const [id, el] of nodes) {
      if (!keep.has(el)) {
        el.remove()
        nodes.delete(id)
      }
    }
    for (const [id, el] of seps) {
      if (!keep.has(el)) {
        el.remove()
        seps.delete(id)
      }
    }
    let cursor = olderEl.nextSibling
    for (const el of want) {
      if (cursor === meta) cursor = cursor.nextSibling
      if (cursor === el) {
        cursor = cursor.nextSibling
        continue
      }
      msgs.insertBefore(el, cursor)
    }
    decorate(visible)
    if (seenIO) for (const el of nodes.values()) seenIO.observe(el)
    placeMeta(list)
    mountStickers(msgs)
    if (t.loaded && !list.length) olderEl.textContent = ''
    else if (t.loaded && !t.hasMore) olderEl.textContent = ''
    else if (!t.loading) olderEl.textContent = ''
  }

  function refreshNode(m) {
    const old = nodes.get(m.id)
    if (!old) return
    if (!old.photoSignature && old.bodySig === bodySig(m)) return updateReactions(old, m)
    const fresh = buildNode(m)
    old.replaceWith(fresh)
    nodes.set(m.id, fresh)
  }

  // ------------------------------------------------------------ scrolling
  const atBottom = () => scroller.scrollTop > -40
  const distTop = () => scroller.scrollHeight - scroller.clientHeight + scroller.scrollTop

  function scrollToBottom(smooth = false) {
    newCount = 0
    newIds = []
    openedUnread = false
    jumpBadge.hidden = true
    syncPills()
    scroller.scrollTo({ top: 0, behavior: smooth && !reducedMotion() ? 'smooth' : 'auto' })
    readingAnchor = { bottom: true }
  }

  function readAnchor() {
    if (atBottom()) return { bottom: true }
    const bounds = scroller.getBoundingClientRect()
    const top = nav.getBoundingClientRect().bottom + 12
    for (const node of msgs.querySelectorAll('.m')) {
      const rect = node.getBoundingClientRect()
      if (rect.bottom > top && rect.top < bounds.bottom) return { id: node.dataset.id, offset: rect.top - bounds.top }
    }
    return null
  }
  function rememberReadingAnchor() { readingAnchor = readAnchor() }
  function restoreReadingAnchor(anchor) {
    if (anchor?.bottom) { scroller.scrollTop = 0; return }
    const group = [...photoGroups].find(([, photos]) => photos.some(photo => photo.id === anchor?.id))
    const node = nodes.get(anchor?.id) || nodes.get(group?.[0])
    if (!node?.isConnected) return
    const offset = node.getBoundingClientRect().top - scroller.getBoundingClientRect().top
    scroller.scrollTop += offset - anchor.offset
  }

  /** Apply a DOM change at the bottom without moving what the reader is looking at. */
  function keepPosition(change) {
    const wasBottom = atBottom()
    const anchor = readAnchor()
    change()
    restoreReadingAnchor(anchor)
    rememberReadingAnchor()
    return wasBottom
  }

  let ticking = false
  scroller.addEventListener('scroll', () => {
    if (ticking) return
    ticking = true
    requestAnimationFrame(() => {
      ticking = false
      rememberReadingAnchor()
      edgeTop.classList.toggle('on', distTop() > 2)
      jump.classList.toggle('on', scroller.scrollTop < -320)
      recountBelow()
      if (atBottom() && newCount) {
        newCount = 0
        newIds = []
    newIds = []
        openedUnread = false
        jumpBadge.hidden = true
        syncPills()
      }
      if (mentionIds.length && mentionIds.some(onScreen)) {
        mentionIds = mentionIds.filter(id => !onScreen(id))
        showMentions()
      }
      if (distTop() < 500) loadOlder()
    })
  }, { passive: true })

  async function loadOlder() {
    const chat = current
    const t = thread(chat)
    if (!t.loaded || !t.hasMore || t.loading || !t.list.length) return
    t.loading = true
    olderEl.replaceChildren(h('span', { class: 'spinner' }))
    try {
      const first = t.list[0]
      const r = await api.get(`/api/messages?room=${encodeURIComponent(chat)}&before=${first.ts}&limit=${PAGE}`)
      const added = mergeMessages(chat, r.messages.map(normMsg), { older: true })
      t.hasMore = r.messages.length >= PAGE && added.length > 0
    } catch {
      t.hasMore = true
    } finally {
      t.loading = false
      olderEl.replaceChildren()
      if (current === chat) reconcile()
    }
  }

  // ------------------------------------------------------------ open / close
  async function open(id) {
    if (current === id) return
    composer.flushDraft()
    stopVoice()
    current = id
    clearTimeout(typingTimer)
    typingTimer = 0
    titleSub.classList.remove('typing')
    clearGhost()
    hideGhost()
    newCount = 0
    newIds = []
    jumpBadge.hidden = true
    jump.classList.remove('on')
    // What was unread on arrival is settled once the list is the server's
    // (below); until then nothing is placed or read by it.
    unreadSince = Infinity
    unreadTotal0 = 0
    unreadUpTo = Infinity
    openedUnread = false
    dividerAt = null
    unreadDivider.remove()
    seenIO?.disconnect()
    seenIO = null
    readUpTo = 0
    readSent = 0
    readFloor = Infinity
    mentionIds = []
    showMentions()
    for (const el of [...msgs.children]) if (el !== olderEl) el.remove()
    // A page still loading for the last conversation isn't this one's.
    olderEl.replaceChildren()
    nodes.clear()
    seps.clear()
    photoGroups.clear()
    root.hidden = false
    empty.hidden = true
    applyBackdrop()
    renderHeader()
    composer.setChat(id, { readonly: false })
    composer.setToolShown('sticker', Boolean(state.stickers))
    ensureRoom(id)
    const t = thread(id)
    reconcile()
    scrollToBottom()
    // Side by side there is no push; the new conversation settles in place.
    if (pane.dataset.layout !== 'single' && !reducedMotion()) {
      for (const el of [msgs, titleBtn]) {
        el.classList.remove('swap')
        void el.offsetWidth
        el.classList.add('swap')
      }
    }
    try {
      if (!t.loaded) {
        if (t.list.length) olderEl.replaceChildren(h('span', { class: 'spinner' }))
        else showGhost()
        const r = await api.get(`/api/messages?room=${encodeURIComponent(id)}&limit=${PAGE}`)
        // Kept even if another conversation opened meanwhile: coming back is instant.
        if (!t.loaded) {
          mergeMessages(id, r.messages.map(normMsg))
          t.loaded = true
          t.hasMore = r.messages.length >= PAGE
        }
        if (current !== id) return
        olderEl.replaceChildren()
        hideGhost()
        reconcile()
        scrollToBottom()
        tipHold()
      } else {
        await catchUp(id)
      }
    } catch (err) {
      if (current === id) {
        olderEl.replaceChildren()
        hideGhost()
        toast(err.message, { type: 'error' })
      }
    }
    // Launched from the cached list: what's unread is only known once the
    // server's list is in (a moment; not longer than a few seconds).
    if (current === id && !roomsFresh) await new Promise(done => { freshWaiters.push(done); setTimeout(done, 4000) })
    if (current !== id) return
    const arrival = chatInfo(id) || {}
    // Marked unread by hand is a flag, not messages to find.
    const counted = arrival.marked ? 0 : arrival.unread || 0
    const since = counted ? arrival.lastRead || 0 : Infinity
    unreadSince = since
    unreadTotal0 = counted
    mentionIds = arrival.mention && counted ? [arrival.mention] : []
    // Every unread mention among what's loaded, oldest first, except what is already on screen.
    if (current === id) {
      const unseen = thread(id).list.filter(m => m.ts > since && mentionsMe(m)).map(m => m.id)
      mentionIds = [...new Set([...mentionIds, ...unseen])].filter(m => !onScreen(m))
      showMentions()
      const t = thread(id)
      if (unreadTotal0) {
        unreadUpTo = t.list.at(-1)?.ts ?? Infinity
        await openAtFirstUnread(id)
        if (current !== id) return
      }
      // Read is what has been on screen: from here on, as it scrolls into view.
      const first = dividerAt && thread(id).byId.get(dividerAt)
      readFloor = first ? first.ts - 1 : unreadTotal0 ? (arrival.lastRead || 0) : (t.list.at(-1)?.ts ?? 0)
      watchSeen()
    }
    // A hand-made unread mark goes on opening.
    markReadSoon(Boolean(arrival.marked))
  }

  /** Pull room metadata + members (names/avatars for group bubbles). */
  async function ensureRoom(id) {
    try {
      const r = await api.get(`/api/room/${encodeURIComponent(id)}`)
      if (r.room) upsertRoom(r.room)
      if (r.members) setMembers(id, r.members)
      if (current === id) { renderHeader(); reconcile(); composer.paintMentions() }
    } catch {}
  }

  /** Fetch anything we may have missed while the socket was down. */
  async function catchUp(id = current) {
    if (!id) return
    const t = thread(id)
    if (!t.loaded) return
    const last = t.list.filter(m => !String(m.id).startsWith('local:')).pop()
    const r = await api.get(`/api/messages?room=${encodeURIComponent(id)}&after=${Math.max(0, (last?.ts || 0) - 1)}&limit=200`)
    if (current !== id) return
    const added = mergeMessages(id, r.messages.map(normMsg))
    if (added.length) keepPosition(reconcile)
  }

  function close() {
    composer.flushDraft()
    composer.blur()
    stopVoice()
    hideGhost()
    clearTimeout(typingTimer)
    typingTimer = 0
    titleSub.classList.remove('typing')
    clearGhost()
    current = null
    composer.setChat(null)
  }

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && current) markReadSoon()
  })

  let typingTimer = 0
  function renderHeader() {
    if (!current) return
    const c = chatInfo(current) || { id: current, name: 'Chat' }
    const room = c.kind === 'group'
    titleAvatar.replaceChildren(avatar(c.avatar, c.name, { room, size: 40 }))
    titleName.textContent = c.name
    titleBtn.classList.toggle('is-online', !room && Boolean(c.online))
    if (!typingTimer) titleSub.textContent = room ? (c.count ? `${c.count} members` : '') : (c.online ? 'Online' : '')
    titleBtn.setAttribute('aria-label', `${c.name}, view chat info`)
    // The unread badge on Back is status: it changes what overflows first.
    bars.refresh()
    arrangeBars()
  }

  // ------------------------------------------------------------ read state
  // Messages count as read only while the conversation's column is on
  // screen; a read held back meanwhile goes out when it comes back.
  let readTimer = 0
  let readHeld = false
  // The app opens from its cached list before the server answers (main.js);
  // that copy has to know what was read here, or the next launch would open
  // this conversation at messages already read.
  function cacheRead(id, patch) {
    try {
      const boot = JSON.parse(storage('cache:boot') || 'null')
      const row = boot?.rooms?.find(r => r.id === id)
      if (!row) return
      Object.assign(row, patch)
      storage('cache:boot', JSON.stringify(boot))
    } catch {}
  }
  function markReadSoon(force = false) {
    clearTimeout(readTimer)
    readTimer = setTimeout(() => {
      if (!current || document.visibilityState !== 'visible') return
      if (pane.inert) {
        readHeld = true
        return
      }
      readHeld = false
      const c = state.chats.get(current)
      if (!c) return
      const t = thread(current)
      const upTo = Math.max(readFloor === Infinity ? 0 : readFloor, readUpTo)
      // Still unread: from others, after what has been seen (only once it's known where that starts).
      const left = readFloor === Infinity ? c.unread || 0
        : t.list.filter(m => !m.out && !isSys(m) && m.status !== 'revoked' && m.ts > upTo).length
      const mentionTs = c.mention && t.byId.get(c.mention)?.ts
      const patch = {}
      if (left !== (c.unread || 0) || c.marked) Object.assign(patch, { unread: left, marked: false })
      if (c.mention && (!left || (mentionTs && mentionTs <= upTo))) patch.mention = null
      // lastRead too: the cached list is what the next open measures "unread since" from.
      if (readUpTo > (c.lastRead || 0)) patch.lastRead = readUpTo
      if (Object.keys(patch).length) {
        patchRoom(current, patch)
        cacheRead(current, patch)
      }
      if (readUpTo > readSent || force) {
        readSent = Math.max(readSent, readUpTo)
        socketSend({ t: 'read', room: current, ts: readUpTo || c.lastRead || 0 })
      }
    }, 350)
  }


  // ------------------------------------------------------------ sending
  const previewText = m => ({ image: '[Photo]', drawing: '[Drawing]', voice: '[Voice]', video: '[Video]', file: '[File]' }[m.type] || m.text || '')
  function bumpList(m) {
    if (!state.chats.get(m.chat)) return
    patchRoom(m.chat, {
      ts: m.ts,
      unread: 0,
      last: { id: m.id, text: previewText(m), out: true, type: m.type, status: m.status, ts: m.ts }
    })
  }

  async function uploadMedia(kind, file, info = {}) {
    const qs = new URLSearchParams({ kind })
    for (const k of ['room', 'name', 'w', 'h', 'dur', 'localId']) if (info[k]) qs.set(k, info[k])
    let res
    try {
      res = await sendFile(`/api/media/upload?${qs}`, file, { signal: info.signal, onProgress: info.progressId ? p => setProgress(info.progressId, p) : null })
    } catch (err) {
      // No network, or it took too long: the outbox waits this out.
      if (err?.name === 'AbortError' || err?.name === 'TimeoutError') throw Object.assign(new Error('Upload timed out'), { name: 'AbortError' })
      throw new ApiError('Network connection unavailable', 0)
    }
    const data = res.data || {}
    if (!res.ok || !data.ok) throw new ApiError(data.error || 'Upload failed', res.status, data)
    return data
  }
  // A file to the server, saying how far it has got (fetch can't): { ok, status, data }.
  function sendFile(url, file, { signal, onProgress } = {}) {
    return new Promise((resolve, reject) => {
      const x = new XMLHttpRequest()
      x.open('POST', url)
      x.withCredentials = true
      x.setRequestHeader('content-type', file.type || 'application/octet-stream')
      x.responseType = 'json'
      if (onProgress) x.upload.addEventListener('progress', e => { if (e.lengthComputable) onProgress(e.loaded / e.total) })
      x.addEventListener('load', () => resolve({ ok: x.status >= 200 && x.status < 300, status: x.status, data: x.response }))
      x.addEventListener('error', () => reject(new TypeError('Network error')))
      x.addEventListener('timeout', () => reject(Object.assign(new Error('Timed out'), { name: 'TimeoutError' })))
      x.addEventListener('abort', () => reject(Object.assign(new Error('Aborted'), { name: signal?.reason?.name === 'TimeoutError' ? 'TimeoutError' : 'AbortError' })))
      if (signal) {
        if (signal.aborted) return x.abort()
        signal.addEventListener('abort', () => x.abort(), { once: true })
      }
      x.send(file)
    })
  }

  /** A reply's own record of what it answers, until the server's comes back. */
  function replyFields(chat, replyTo) {
    if (!replyTo) return {}
    const o = thread(chat).byId.get(replyTo)
    return { replyTo, reply: o ? { id: o.id, sender: o.from, type: o.type, state: o.status, body: o.text, url: o.url, emoji: o.meta?.emoji } : null }
  }

  async function sendText(text, chat = current, replyTo = null, mentions = undefined) {
    if (!chat) return
    const cid = newCid()
    const local = { id: `local:${cid}`, cid, localId: cid, chat, ts: Date.now(), out: true, from: state.me?.id, fromName: state.me?.display, type: 'text', text, status: 'sending', ...(mentions && { meta: { mentions } }), ...replyFields(chat, replyTo) }
    upsertMessage(local)
    bumpList(local)
    if (chat === current) scrollToBottom()
    outbox.add({ cid, chat, body: { room: chat, type: 'text', text, ...(replyTo && { replyTo }), ...(mentions && { mentions }) }, local })
  }

  // A sticker goes like a text: shown at once, then confirmed (or offered a retry).
  async function sendSticker(st, chat = current, replyTo = null) {
    if (!chat) return
    const cid = newCid()
    const meta = { id: st.id, kind: st.kind, emoji: st.emoji || '', ...(st.set && { set: st.set }) }
    const local = { id: `local:${cid}`, cid, localId: cid, chat, ts: Date.now(), out: true, from: state.me?.id, fromName: state.me?.display, type: 'sticker', text: '', meta, status: 'sending', ...replyFields(chat, replyTo) }
    upsertMessage(local)
    bumpList(local)
    if (chat === current) scrollToBottom()
    outbox.add({ cid, chat, body: { room: chat, type: 'sticker', meta, ...(replyTo && { replyTo }) }, local })
  }

  // Texts, stickers, photos and drawings leave through the outbox: one line,
  // in order, waiting out a lost connection, picked up again after a reload
  // (outbox.js). A picture's file waits on the device under the account's id.
  const files = blobStore()
  const fileKey = cid => `${state.me?.id || ''}:${cid}`
  const showFile = (cid, file) => {
    if (!file || state.previews.has(cid)) return
    state.previews.set(cid, URL.createObjectURL(file))
  }
  outbox.connect({
    post: body => api.post('/api/messages', body, { signal: AbortSignal.timeout?.(15000) }),
    blob: cid => files.get(fileKey(cid)),
    upload: (e, file) => uploadMedia('image', file, { room: e.chat, name: e.media.name, w: e.media.w, h: e.media.h, localId: e.media.key || e.cid, progressId: e.cid, signal: AbortSignal.timeout?.(60000) }),
    forget: cid => { files.del(fileKey(cid)) },
    onLanded: (e, r) => {
      retrying.delete(`local:${e.cid}`)
      retryFiles.delete(e.cid)
      setProgress(e.cid, null)
      if (!r?.msg) return
      const m = normMsg(r.msg)
      replaceMessage(`local:${e.cid}`, m)
      // A message that went while another conversation was open still updates its row.
      if (state.chats.get(e.chat)?.last?.id === `local:${e.cid}`) bumpList(m)
    },
    onFailed: (e, err) => {
      setProgress(e.cid, null, { sent: false })
      const t = thread(e.chat)
      const m = t.byId.get(`local:${e.cid}`) || (e.local && { ...e.local })
      retrying.delete(`local:${e.cid}`)
      // Its file is gone (a reload where it couldn't be kept): Choose again.
      if (m) upsertMessage({ ...m, status: 'failed', lost: Boolean(err.noFile) })
      toast(err.message || (e.media ? "Couldn't send photo" : 'Send failed'), { type: 'error' })
      announce('Send failed')
    },
    // Restored after a reload: the bubbles come back, still on their way; a
    // picture shows its kept file again (or, without one, fails visibly when
    // its turn comes).
    // A failed one comes back failed, in its place, with Retry (or, its file
    // gone, Choose again).
    onRestore: list => {
      for (const e of list) {
        if (!e.local) continue
        upsertMessage({ ...e.local, status: e.failed ? 'failed' : 'sending', lost: Boolean(e.failed && e.lost) })
        if (e.media) files.get(fileKey(e.cid)).then(file => {
          const m = thread(e.chat).byId.get(`local:${e.cid}`)
          if (!file) {
            // Failed and nothing kept to send again: say so where it is.
            if (m && e.failed && !e.uploaded) upsertMessage({ ...m, lost: true })
            return
          }
          retryFiles.set(e.cid, { file, w: e.media.w, h: e.media.h, kind: e.media.kind, replyTo: e.local.replyTo || null })
          showFile(e.cid, file)
          if (m) upsertMessage({ ...m, url: state.previews.get(e.cid) })
        })
      }
    },
    load: () => JSON.parse(storage(`outbox:${state.me?.id || ''}`) || '[]'),
    save: list => storage(`outbox:${state.me?.id || ''}`, list.length ? JSON.stringify(list) : null)
  })
  // Nothing waiting: any file still kept for this account belonged to a send
  // that ended while the page was closing.
  files.prune(fileKey(''), new Set(outbox.keptFiles().map(fileKey)))

  async function sendImages(files, { from = [] } = {}) {
    const chat = current
    if (!chat) return
    // A reply goes with the first photo of the batch.
    let replyTo = composer.takeReply()
    for (const [i, f] of files.entries()) {
      try {
        await sendPrepared(chat, await prepareImage(f), from[i], replyTo)
        replyTo = null
      } catch (err) {
        toast(err.message || 'Could not process this image', { type: 'error' })
      }
    }
  }

  // A photo sent from the attachment sheet carries on from where it was
  // seen there into its new message: same proportions, its crop easing
  // away. Only the look travels; the upload reports on its own.
  function carryIn(id, from) {
    if (!from?.width || reducedMotion()) return
    requestAnimationFrame(() => {
      const bubble = nodes.get(id)?.querySelector('.bubble.media')
      const to = bubble?.getBoundingClientRect()
      if (!to?.width || to.bottom < 0 || to.top > innerHeight) return
      const k = Math.max(from.width / to.width, from.height / to.height)
      const dx = from.left + from.width / 2 - to.left - (to.width * k) / 2
      const dy = from.top + from.height / 2 - to.top - (to.height * k) / 2
      const ix = Math.max(0, (to.width - from.width / k) / 2)
      const iy = Math.max(0, (to.height - from.height / k) / 2)
      const r = parseFloat(getComputedStyle(bubble).borderTopLeftRadius) || 0
      bubble.animate([
        { transformOrigin: '0 0', transform: `translate(${dx}px, ${dy}px) scale(${k})`, clipPath: `inset(${iy}px ${ix}px round ${14 / k}px)` },
        { transformOrigin: '0 0', transform: 'none', clipPath: `inset(0px 0px round ${r}px)` }
      ], { duration: 280, easing: 'cubic-bezier(0.22, 1, 0.36, 1)' })
    })
  }

  function sendPrepared(chat, { file, w, h: hh }, from, replyTo = null) {
    queuePicture(chat, { file, w, h: hh, kind: 'image', name: file.name || 'photo.jpg', replyTo, from })
  }

  /**
   * A photo or drawing: shown at once, then into the outbox behind whatever
   * was written before it. Its file is kept on the device first, so a reload
   * can still send it; where it can't be kept, this page still sends it, and
   * after a reload it comes back failed (please choose this photo again), never just gone.
   * A retry passes its own cid: the same message, never a second one.
   */
  function queuePicture(chat, { file, w, h: hh, kind, name, replyTo = null, from, cid = newCid(), local: again, key }) {
    showFile(cid, file)
    retryFiles.set(cid, { file, w, h: hh, kind, replyTo })
    if (again) retrying.add(again.id)
    const local = again
      ? { ...again, type: kind, w, h: hh, url: state.previews.get(cid), status: 'sending', lost: false }
      : { id: `local:${cid}`, cid, localId: cid, chat, ts: Date.now(), out: true, from: state.me?.id, type: kind, w, h: hh, url: state.previews.get(cid), status: 'sending', ...replyFields(chat, replyTo) }
    upsertMessage(local)
    if (!again) {
      bumpList(local)
      if (chat === current) {
        scrollToBottom()
        if (kind === 'image') carryIn(local.id, from)
      }
    }
    files.put(fileKey(cid), file)
    // The kept copy has no use for a page-only object URL.
    const { url, seq, lost, ...kept } = local
    outbox.add({ cid, chat, body: { room: chat, type: kind, ...(replyTo && { replyTo }) }, local: kept, media: { kind, name, w, h: hh, ...(key && { key }) } })
  }

  let typingSentAt = 0
  let typingLater = 0
  function sendTyping(text = '') {
    const now = Date.now()
    clearTimeout(typingLater)
    if (!current) return
    // Honk-style live typing: stream the in-progress text so the peer sees it
    // as it is typed. Throttled; empty text clears the peer's ghost bubble at
    // once. The last of a quick burst still goes, as soon as the throttle
    // allows, so the peer never sees it stopped a few characters short.
    const room = current
    const send = () => {
      typingSentAt = Date.now()
      socketSend({ t: 'typing', room, text: text.slice(0, 500) })
    }
    if (now - typingSentAt > 180 || !text) send()
    else typingLater = setTimeout(() => { if (current === room) send() }, 180 - (now - typingSentAt))
  }

  async function sendDrawing(blob, { w, h } = {}) {
    const chat = current
    if (!chat) return
    const file = new File([blob], 'drawing.png', { type: 'image/png' })
    queuePicture(chat, { file, w, h, kind: 'drawing', name: 'drawing.png', replyTo: composer.takeReply() })
  }

  let ghostEl = null
  function clearGhost() {
    ghostEl?.remove()
    ghostEl = null
  }
  function setTyping(room, uid, text = '') {
    if (room !== current) return
    clearTimeout(typingTimer)
    if (text) {
      // Live text: a ghost incoming bubble that updates as the peer types.
      if (!ghostEl) {
        const who = isGroup(current) ? h('div', { class: 'm-sender' }, nameOf(uid, current)) : null
        const bub = h('div', { class: 'bubble text ghost' })
        ghostEl = h('div', { class: 'm in ghost-row' }, h('span', { class: 'm-avatar' }), h('div', { class: 'm-col' }, who, bub))
        msgs.append(ghostEl)
      }
      ghostEl.querySelector('.bubble').textContent = text
      if (atBottom()) scrollToBottom()
    } else {
      clearGhost()
    }
    const who = isGroup(current) ? `${nameOf(uid, current)} ` : ''
    titleSub.textContent = `${who} is typing…`
    titleSub.classList.add('typing')
    typingTimer = setTimeout(() => { typingTimer = 0; titleSub.classList.remove('typing'); renderHeader(); clearGhost() }, 4500)
  }

  // A failed text is sent again in place, with the same localId (the server
  // answers a repeat with the message that already landed); a tap while it
  // is on its way does nothing.
  // Tapped, it says so at once: Sending where Retry was (retrying), until it
  // lands or fails again (onLanded/onFailed).
  async function retry(m) {
    if (m.lost) return pickAgain(m)
    if (m.cid && outbox.has(m.cid)) return
    // Kept by the outbox since it failed (text or picture, its file too).
    if (m.cid && outbox.isFailed(m.cid)) {
      retrying.add(m.id)
      upsertMessage({ ...m, status: 'sending' })
      const { seq, status, lost, url, ...local } = m
      outbox.retry(m.cid, { ...local, status: 'sending' })
      return
    }
    const again = m.type === 'text' && m.text ? { type: 'text', text: m.text, ...(m.meta?.mentions && { mentions: m.meta.mentions }) } : m.type === 'sticker' && m.meta?.id ? { type: 'sticker', meta: m.meta } : null
    if (again && m.cid) {
      retrying.add(m.id)
      upsertMessage({ ...m, status: 'sending' })
      const { id, status, seq, ...local } = m
      outbox.add({ cid: m.cid, chat: m.chat, body: { room: m.chat, ...again, ...(m.replyTo && { replyTo: m.replyTo }) }, local: { ...local, id, status: 'sending' } })
      return
    }
    // A photo or drawing goes again as the same message (same cid), from the
    // file still held here; without it, it asks for the picture again.
    if ((m.type === 'image' || m.type === 'drawing') && m.cid) {
      const f = retryFiles.get(m.cid)
      if (!f) return pickAgain(m)
      return queuePicture(m.chat, { ...f, kind: m.type, name: m.type === 'drawing' ? 'drawing.png' : (f.file.name || 'photo.jpg'), replyTo: m.replyTo || f.replyTo || null, cid: m.cid, local: m })
    }
    removeMessage(m.id, m.chat)
    if (m.text) await sendText(m.text, m.chat, m.replyTo, m.meta?.mentions)
  }

  // Its picture didn't survive a reload: Choose again opens the photo picker
  // straight away, and what's picked goes as that same message (same cid
  // and localId, still a reply if it was one), in place of the lost one.
  const repick = h('input', { type: 'file', accept: 'image/*', hidden: true, 'aria-hidden': 'true', tabindex: '-1' })
  root.append(repick)
  let repickFor = null
  function pickAgain(m) {
    repickFor = m
    repick.value = ''
    repick.click()
  }
  repick.addEventListener('change', async () => {
    const m = repickFor && thread(repickFor.chat).byId.get(repickFor.id)
    const file = repick.files?.[0]
    repickFor = null
    if (!m || !file || m.status !== 'failed') return
    try {
      const p = await prepareImage(file)
      // Its own upload key: the lost file may have landed under the cid.
      queuePicture(m.chat, { file: p.file, w: p.w, h: p.h, kind: 'image', name: p.file.name || 'photo.jpg', replyTo: m.replyTo || null, cid: m.cid, local: m, key: `${m.cid}-r${Date.now().toString(36)}` })
    } catch (err) {
      toast(err.message || 'Could not process this image', { type: 'error' })
    }
  })

  // Only this device forgets it, so say so and ask first; the answer
  // stays after a reload (store.js keeps the ids deleted here).
  async function deleteLocal(m, anchor) {
    const ok = await confirmAction(anchor?.isConnected ? anchor : nodes.get(m.id)?.querySelector('.bubble') || scroller, {
      title: 'Delete from this device?',
      message: 'They can still see this message.',
      confirm: 'Delete'
    })
    if (!ok) return
    // Still queued: it won't go. Already on its way: it can't be stopped here.
    // Failed (kept by the outbox, with its file): it goes, file and all.
    if (m.cid && outbox.has(m.cid) && !outbox.drop(m.cid)) return toast('Still sending, delete it in a moment')
    if (m.cid && outbox.isFailed(m.cid)) outbox.drop(m.cid)
    if (m.cid) retryFiles.delete(m.cid)
    retrying.delete(m.id)
    if (editingId === m.id) composer.endEdit()
    removeMessage(m.id, m.chat, { here: true })
    announce('Deleted')
  }

  // ------------------------------------------------------------ interactions
  const msgOf = node => thread(current).byId.get(node?.dataset.id)

  scroller.addEventListener('click', e => {
    if (suppressClick) {
      e.preventDefault()
      return
    }
    const node = e.target.closest('.m')
    const m = msgOf(node)
    if (!m) return
    if (e.target.closest('.m-retry')) return m.status === 'failed' ? retry(m) : undefined
    if (e.target.closest('.bubble.media .ph .text-button')) return m.status === 'failed' && m.lost ? pickAgain(m) : undefined
    if (e.target.closest('.m-reactions')) return messageMenu(node, m)
    const q = e.target.closest('.quote')
    if (q) return q.classList.contains('is-recalled') ? undefined : jumpTo(m.replyTo)
    if (e.target.closest('a')) return
    const bub = e.target.closest('.bubble')
    if (!bub) return
    switch (bub.dataset.kind) {
      case 'text': {
        // Double-tap a message to love it (or take the heart back).
        const now = performance.now()
        if (lastTap.id === m.id && now - lastTap.at < 340) {
          lastTap = {}
          if (reactable(m)) react(m, '❤️', { burst: true })
        } else lastTap = { id: m.id, at: now }
        break
      }
      case 'image': {
        const img = bub.querySelector('img')
        const preview = m.cid ? state.previews.get(m.cid) : null
        openViewer({
          thumb: img,
          src: img?.currentSrc || img?.src || preview,
          fullSrc: preview || m.url,
          w: m.w,
          h: m.h,
          findThumb: () => nodes.get(m.id)?.querySelector('.bubble img'),
          ...photoActions(m)
        })
        break
      }
      case 'video':
        openViewer({
          kind: 'video',
          thumb: bub.querySelector('img'),
          fullSrc: m.url,
          w: m.w || 720,
          h: m.h || 1280,
          label: 'Video',
          findThumb: () => nodes.get(m.id)?.querySelector('.bubble img')
        })
        break
      case 'voice':
        toggleVoice(m, bub)
        break
      case 'link': {
        const url = safeUrl(m.url)
        if (url) window.open(url, '_blank', 'noopener,noreferrer')
        else toast("Couldn't open this link", { type: 'error' })
        break
      }
      case 'file':
        if (m.url) window.open(m.url, '_blank', 'noopener')
        break
      case 'location':
        window.open(`https://maps.apple.com/?q=${encodeURIComponent(m.title || '')}`, '_blank', 'noopener')
        break
      case 'money':
        toast("Can't view this message yet", { iconName: 'info' })
        break
    }
  })

  let lastTap = {}

  // In the viewer, a chat's photo can be answered (a reply quoting it, from a
  // field under it) and loved, with how many have — like holding it would.
  function photoActions(m) {
    const now = () => thread(m.chat).byId.get(m.id) || m
    if (!reactable(now())) return {}
    const hearts = () => (now().reactions || []).find(g => g.emoji === '❤️')
    return {
      actions: [
        { id: 'reply', icon: 'bubble', label: 'Reply', onSelect: v => v.focusReply() },
        { id: 'like', icon: 'heart', label: 'Love', read: () => ({ count: hearts()?.users.length || 0, on: Boolean(hearts()?.users.includes(state.me?.id)) }), onSelect: () => react(now(), '❤️') }
      ],
      reply: { placeholder: 'Reply to this photo', sent: 'Replied', onSend: text => sendText(text, m.chat, m.id) }
    }
  }

  async function react(m, emoji, { burst = false } = {}) {
    const chat = m.chat
    const before = m.reactions || []
    const next = myReaction(m) === emoji ? '' : emoji
    upsertMessage({ ...m, reactions: withReaction(before, state.me?.id, next) })
    haptic()
    const node = nodes.get(m.id)
    if (burst && next && node && !reducedMotion()) {
      const heart = h('span', { class: 'reaction-burst', 'aria-hidden': 'true' }, next)
      node.querySelector('.m-col')?.append(heart)
      heart.addEventListener('animationend', () => heart.remove(), { once: true })
    }
    announce(next ? `Reacted ${REACTION_NAMES[next] || next}` : 'Reaction removed')
    try {
      const r = await api.post('/api/react', { id: m.id, emoji: next })
      const known = thread(chat).byId.get(m.id)
      if (r.msg && known) upsertMessage({ ...known, reactions: r.msg.reactions || [] })
    } catch (err) {
      if (thread(chat).byId.has(m.id)) upsertMessage({ ...thread(chat).byId.get(m.id), reactions: before })
      toast(err.message || 'Reaction failed', { type: 'error' })
    }
  }

  // Long press → context menu (bubbles shrink a touch while held).
  let press = null
  scroller.addEventListener('pointerdown', e => {
    suppressClick = false
    const bub = e.target.closest('.bubble')
    if (!bub || e.button > 0 || bub.dataset.selecting != null) return
    const node = bub.closest('.m')
    bub.classList.add('is-pressed')
    press = {
      x: e.clientX,
      y: e.clientY,
      bub,
      timer: setTimeout(() => {
        bub.classList.remove('is-pressed')
        const m = msgOf(node)
        press = null
        if (!m) return
        suppressClick = true
        cancelPress()
        haptic()
        messageMenu(node, m, { touch: true })
      }, 460)
    }
  }, { passive: true })
  const cancelLong = () => {
    if (!press) return
    clearTimeout(press.timer)
    press.bub.classList.remove('is-pressed')
    press = null
  }
  scroller.addEventListener('pointermove', e => {
    if (press && Math.hypot(e.clientX - press.x, e.clientY - press.y) > 8) cancelLong()
  }, { passive: true })
  scroller.addEventListener('pointerup', cancelLong)
  scroller.addEventListener('pointercancel', cancelLong)

  // Swipe a message to the right to answer it: the row follows the finger
  // (resisting past the threshold) and settles back; past 56px it replies.
  const SWIPE_REPLY = 56
  let swipe = null
  scroller.addEventListener('pointerdown', e => {
    if (e.pointerType === 'mouse' || e.button > 0) return
    const node = e.target.closest('.m')
    if (!node || !e.target.closest('.bubble') || e.target.closest('.bubble[data-selecting]')) return
    swipe = { id: e.pointerId, x: e.clientX, y: e.clientY, node, active: false, armed: false }
  }, { passive: true })
  scroller.addEventListener('pointermove', e => {
    if (!swipe || e.pointerId !== swipe.id) return
    const dx = e.clientX - swipe.x
    const dy = e.clientY - swipe.y
    if (!swipe.active) {
      if (Math.abs(dy) > 10 && Math.abs(dy) > Math.abs(dx)) { swipe = null; return }
      if (dx < 12 || dx < Math.abs(dy) * 1.5) return
      if (!reactable(msgOf(swipe.node))) { swipe = null; return }
      swipe.active = true
      cancelLong()
      swipe.node.style.transition = 'none'
    }
    const shift = dx <= SWIPE_REPLY ? Math.max(0, dx) : SWIPE_REPLY + (dx - SWIPE_REPLY) * 0.25
    swipe.node.style.transform = `translateX(${Math.min(shift, 84)}px)`
    const armed = dx >= SWIPE_REPLY
    if (armed && !swipe.armed) haptic()
    swipe.armed = armed
  }, { passive: true })
  const endSwipe = e => {
    if (!swipe || (e && e.pointerId !== swipe.id)) return
    const { node, active, armed } = swipe
    swipe = null
    if (!active) return
    suppressClick = true
    node.style.transition = reducedMotion() ? 'none' : 'transform 220ms var(--ease-out)'
    node.style.transform = ''
    setTimeout(() => { node.style.transition = '' }, 240)
    const m = msgOf(node)
    if (armed && e?.type === 'pointerup' && m) startReply(m)
  }
  scroller.addEventListener('pointerup', endSwipe)
  scroller.addEventListener('pointercancel', endSwipe)
  scroller.addEventListener('scroll', cancelLong, { passive: true })
  scroller.addEventListener('contextmenu', e => {
    // Selecting text: the system's own menu (Copy, Look Up…), not ours.
    if (e.target.closest('.bubble[data-selecting]')) return
    const node = e.target.closest('.m')
    const m = msgOf(node)
    if (!m) return
    e.preventDefault()
    cancelLong()
    // From the keyboard (the menu key) the first action takes focus.
    messageMenu(node, m, { touch: e.button === 2 || e.pointerType === 'mouse' || e.pointerType === 'touch' })
  })

  // Long-press: the conversation blurs away, the message lifts out as it is
  // (same size, same lines), the reactions stand above it and the actions in
  // a card below it, all moved just enough to fit the screen.
  function messageMenu(node, m, { touch = false } = {}) {
    const bub = node.querySelector('.bubble')
    if (!bub) return
    const layer = document.getElementById('overlays')
    const origin = layer.getBoundingClientRect()
    // The bubble may still be easing back from its press: its box, not its
    // drawn (scaled) rect, is its size; the drawn centre is still its centre.
    const drawn = bub.getBoundingClientRect()
    // Its exact laid-out size, unscaled: offsetWidth rounds, and a copy even
    // a fraction of a pixel narrower wraps its last character (“hello?”).
    const { w, ht } = layoutSize(bub)
    const x = drawn.left + (drawn.width - w) / 2 - origin.left
    const y = drawn.top + (drawn.height - ht) / 2 - origin.top
    const rect = new DOMRect(x + origin.left, y + origin.top, w, ht)
    const backdrop = h('div', { class: 'ctx-backdrop' })
    const preview = h('div', {
      class: ['ctx-preview', m.out ? 'out' : 'in'],
      'aria-hidden': 'true', inert: true,
      style: { left: `${x}px`, top: `${y}px`, width: `${w}px`, height: `${ht}px` }
    }, liftedCopy(bub, w, ht))
    layer.append(backdrop, preview)
    bub.style.visibility = 'hidden'
    requestAnimationFrame(() => requestAnimationFrame(() => backdrop.classList.add('on')))

    const items = []
    const main = []
    const photos = photoGroups.get(m.id)
    if (photos) {
      main.push({ label: `View ${photos.length} photos`, icon: 'photo', onSelect: () => openPhotoStack({ messages: photos, thumb: bub.querySelector('.photo-stack-cover img'), findThumb: () => nodes.get(m.id)?.querySelector('.photo-stack-cover img') }) })
      main.push({ label: 'Expand one by one', icon: 'photo', onSelect: () => expandPhotos(photos) })
    }
    if (!photos && reactable(m)) main.push({ label: 'Reply', icon: 'reply', onSelect: () => startReply(m) })
    if (m.status === 'failed') main.push(m.lost ? { label: 'Choose again', icon: 'photo', onSelect: () => pickAgain(m) } : { label: 'Resend', icon: 'refresh', onSelect: () => retry(m) })
    if (m.type === 'text' && m.text) {
      main.push({ label: 'Copy', icon: 'copy', onSelect: () => copy(m.text) })
      // Touch has no drag-select (the long press is the menu): this turns it on
      // for this one bubble, with the system's own handles.
      if (!finePointer.matches) main.push({ label: 'Select text', icon: 'doc', onSelect: () => selectText(m.id) })
    }
    if (!photos && editable(m)) main.push({ label: 'Edit', icon: 'compose', onSelect: () => startEdit(m) })
    if (!photos && m.edited && !isSys(m)) main.push({ label: 'Edit history', icon: 'doc', onSelect: () => showEdits(m.id) })
    if (m.type === 'link' && safeUrl(m.url)) {
      main.push({ label: 'Open link', icon: 'link', onSelect: () => window.open(safeUrl(m.url), '_blank', 'noopener,noreferrer') })
      main.push({ label: 'Copy link', icon: 'copy', onSelect: () => copy(m.url) })
    }
    if (m.type === 'image' && !photos) main.push({ label: 'View photo', icon: 'photo', onSelect: () => bub.click() })
    if (m.type === 'file') main.push({ label: 'Download file', icon: 'download', onSelect: () => m.url && window.open(m.url, '_blank', 'noopener') })
    items.push(main)
    const canRevoke = !photos && m.out && !String(m.id).startsWith('local:') && Date.now() - m.ts < 2 * 60 * 1000
    const danger = []
    if (canRevoke) danger.push({ label: 'Unsend', icon: 'undo', onSelect: () => revoke(m) })
    if (!photos) danger.push({ label: 'Delete from this device', icon: 'trash', destructive: true, onSelect: () => deleteLocal(m, bub) })
    items.push(danger)

    const header = !photos && reactable(m) ? choose => {
      const mine = myReaction(m)
      const buttons = REACTIONS.map((emoji, i) => {
        const b = h('button', {
          class: 'menu-reaction', type: 'button', role: 'menuitemradio', style: { '--i': i },
          'aria-checked': String(emoji === mine), 'aria-label': REACTION_NAMES[emoji]
        }, emoji)
        b.addEventListener('click', () => choose(() => react(m, emoji)))
        return b
      })
      const row = h('div', { class: 'menu-reactions ctx-reactions glass', role: 'group', 'aria-label': 'React' }, buttons)
      row.addEventListener('keydown', e => {
        if (!['ArrowLeft', 'ArrowRight'].includes(e.key)) return
        e.preventDefault()
        e.stopPropagation()
        const i = buttons.indexOf(document.activeElement)
        buttons[(i + (e.key === 'ArrowRight' ? 1 : -1) + buttons.length) % buttons.length]?.focus()
      })
      return row
    } : null

    // Where everything goes: the message stays put when it all fits, and
    // otherwise moves just enough (a very tall one shows its top, cut to fit).
    const GAP = 12
    const RAISE = 8
    const place = ({ width: mw, height: mh, frame }) => {
      const bar = layer.querySelector('.ctx-reactions')
      const above = bar ? bar.offsetHeight + RAISE : 0
      const shown = Math.max(44, Math.min(ht, frame.bottom - frame.top - above - GAP - mh))
      const top = Math.max(frame.top + above, Math.min(y, frame.bottom - mh - GAP - shown))
      preview.style.height = `${shown}px`
      preview.classList.toggle('cut', shown < ht)
      preview.style.transform = `translateY(${Math.round(top - y)}px)`
      // Everything lines up with the message's own side.
      const side = (width, at) => Math.max(frame.left, Math.min(m.out ? at + w - width : at, frame.right - width))
      if (bar) {
        bar.style.left = `${Math.round(side(bar.offsetWidth, x))}px`
        bar.style.top = `${Math.round(top - above)}px`
        bar.style.setProperty('--ox', m.out ? '100%' : '0%')
        // The conversation column's width, for the row's own sizing in CSS.
        bar.style.setProperty('--ctx-col-w', `${Math.round(msgs.getBoundingClientRect().width)}px`)
      }
      return { left: side(mw, x), top: top + shown + GAP, originX: m.out ? mw : 0 }
    }

    openMenu(rect, items, {
      header,
      apart: true,
      place,
      variant: 'ctx-menu',
      focusFirst: !touch,
      onClose: () => {
        backdrop.classList.remove('on')
        preview.style.transform = ''
        setTimeout(() => {
          backdrop.remove()
          preview.remove()
          bub.style.visibility = ''
        }, 220)
      }
    })
  }

  // Select text: the bubble's words (not its time and ticks) selected with the
  // system's handles; it ends when the selection goes or a touch lands elsewhere.
  let selecting = null
  function selectText(id) {
    endSelect()
    // After the menu has put the bubble back on screen.
    setTimeout(() => {
      const bub = nodes.get(id)?.querySelector('.bubble.text')
      if (!bub) return
      bub.dataset.selecting = ''
      // Focus goes to the selected bubble (before the selection is made, so it stays).
      bub.setAttribute('tabindex', '-1')
      bub.focus({ preventScroll: true })
      const range = document.createRange()
      range.selectNodeContents(bub)
      const meta = bub.querySelector(':scope > .m-meta')
      if (meta) range.setEndBefore(meta)
      const sel = getSelection()
      sel.removeAllRanges()
      sel.addRange(range)
      selecting = { bub, armed: false }
      // The selection just made fires one change itself; only later ones count.
      setTimeout(() => { if (selecting?.bub === bub) selecting.armed = true }, 300)
      announce('Text selected, drag the ends to adjust')
    }, 240)
  }
  function endSelect() {
    if (!selecting) return
    delete selecting.bub.dataset.selecting
    selecting = null
  }
  document.addEventListener('selectionchange', () => {
    if (!selecting?.armed) return
    const sel = getSelection()
    if (!sel.rangeCount || sel.isCollapsed || !selecting.bub.contains(sel.anchorNode)) endSelect()
  })
  document.addEventListener('pointerdown', e => {
    if (selecting && !selecting.bub.contains(e.target)) endSelect()
  }, { capture: true, passive: true })
  // Esc ends it as well: the selection goes, focus stays on the bubble.
  document.addEventListener('keydown', e => {
    if (!selecting || e.key !== 'Escape') return
    e.preventDefault()
    e.stopPropagation()
    getSelection().removeAllRanges()
    endSelect()
  }, { capture: true })

  async function copy(text) {
    try {
      await navigator.clipboard.writeText(text)
      toast('Copied', { type: 'ok' })
    } catch {
      toast("Couldn't copy", { type: 'error' })
    }
  }

  // ------------------------------------------------------------ replying
  function startReply(m) {
    if (!current || m.chat !== current || !reactable(m)) return
    const who = m.out ? 'You' : m.fromName || nameOf(m.from, current) || 'them'
    composer.reply({ id: m.id, name: who, text: quotePreview({ type: m.type, state: m.status, body: m.text, emoji: m.meta?.emoji }) })
    haptic()
  }

  /**
   * Bring a message into view (loading older pages until it's there) and
   * flash it once: from a quote, an unread or a mention capsule.
   */
  async function jumpTo(id, { flash = true, instant = false } = {}) {
    const chat = current
    if (!chat || !id) return false
    const t = thread(chat)
    const nodeOf = () => nodes.get(id) || nodes.get([...photoGroups].find(([, ps]) => ps.some(p => p.id === id))?.[0])
    for (let i = 0; i < 20 && !t.byId.has(id) && t.hasMore; i++) {
      if (t.loading) await new Promise(r => setTimeout(r, 120))
      else await loadOlder()
      if (current !== chat) return false
    }
    const node = nodeOf()
    if (!node?.isConnected) {
      toast("Can't find the original message", { iconName: 'info' })
      return false
    }
    // Into the upper third of what's on screen, below the heading.
    const top = nav.getBoundingClientRect().bottom + 12
    const room = scroller.getBoundingClientRect().bottom - top - (parseFloat(getComputedStyle(scroller).getPropertyValue('--foot')) || 90)
    const rect = node.getBoundingClientRect()
    const want = top + Math.max(0, Math.min(room / 3, room - rect.height))
    scroller.scrollBy({ top: rect.top - want, behavior: instant || reducedMotion() ? 'auto' : 'smooth' })
    if (flash) {
      node.classList.remove('is-flash', 'flash')
      void node.offsetWidth
      node.classList.add('is-flash', 'flash')
      setTimeout(() => node.classList.remove('is-flash', 'flash'), 900)
    }
    // A jump someone asked for takes focus there; opening in place doesn't.
    if (flash) {
      node.querySelector('.bubble')?.setAttribute('tabindex', '-1')
      node.querySelector('.bubble')?.focus({ preventScroll: true })
    }
    return true
  }

  // ------------------------------------------------------------ editing
  // Edit puts the message's words in the field (composer.js) with the
  // message marked; saving rewrites it in place at once, for everyone, and
  // puts it back if the server says no.
  function startEdit(m) {
    if (!current || m.chat !== current) return
    const chat = current
    const started = composer.edit({
      text: m.text,
      onSave: text => saveEdit(chat, m.id, text),
      onEnd: () => {
        nodes.get(editingId)?.classList.remove('editing')
        editingId = null
      }
    })
    if (!started) return
    editingId = m.id
    nodes.get(m.id)?.classList.add('editing')
  }

  async function saveEdit(chat, id, text) {
    const known = thread(chat).byId.get(id)
    if (!known) return
    const before = { text: known.text, meta: known.meta, edited: known.edited || 0 }
    const { keys, ...meta } = known.meta || {}
    show({ text, edited: before.edited + 1, meta: { ...meta, history: [...(meta.history || []), { text: before.text, ts: meta.editedAt || known.ts }], editedAt: Date.now() } })
    try {
      const r = await api.post('/api/edit', { id, text })
      if (r.msg) show({ text: r.msg.body, edited: r.msg.edited || 0, meta: r.msg.meta || {} })
    } catch (err) {
      show(before)
      toast(err.message || 'Edit failed', { type: 'error' })
    }
    function show(patch) {
      const m = thread(chat).byId.get(id)
      if (!m) return
      upsertMessage({ ...m, ...patch })
      // The list's preview follows when it's the last message.
      const room = chatInfo(chat)
      if (room?.last?.id === id) patchRoom(chat, { last: { ...room.last, text: listPreview({ type: 'text', body: patch.text, sender: state.me?.id, state: 'sent' }, room) } })
    }
  }

  /** Each wording a message has had, oldest first, with when it was written. */
  function showEdits(id) {
    const m = current && thread(current).byId.get(id)
    if (!m?.edited) return
    const versions = [...(m.meta?.history || []), { text: m.text, ts: m.meta?.editedAt || m.ts, now: true }]
    const list = h('ol', { class: 'edit-history' }, versions.map(v => {
      const [day, time] = threadTime(v.ts)
      return h('li', { class: ['edit-version', v.now && 'now'] },
        h('span', { class: 'edit-when' }, v.now ? `Now · ${day} ${time}` : `${day} ${time}`),
        h('span', { class: ['edit-text', m.out ? 'out' : 'in'] }, v.text))
    }))
    openSheet({ title: 'Edit history', content: h('div', { class: 'edit-history-wrap' }, list), side: 'thread' })
  }

  async function revoke(m) {
    if (editingId === m.id) composer.endEdit()
    try {
      const r = await api.post('/api/revoke', { id: m.id })
      if (r.msg) upsertMessage(normMsg(r.msg))
    } catch (err) {
      toast(err.message, { type: 'error' })
    }
  }

  // ------------------------------------------------------------ voice
  let audio = null
  let playing = null

  function stopVoice() {
    if (!audio) return
    audio.pause()
    const node = nodes.get(playing)
    replaceSymbol(node?.querySelector('.voice-btn .icon'), 'play')
    node?.querySelectorAll('.wave i').forEach(i => i.classList.remove('on'))
    audio = null
    playing = null
  }

  function toggleVoice(m, bub) {
    if (playing === m.id) return stopVoice()
    stopVoice()
    playing = m.id
    audio = new Audio(m.url)
    const bars = [...bub.querySelectorAll('.wave i')]
    replaceSymbol(bub.querySelector('.voice-btn .icon'), 'pause')
    audio.addEventListener('timeupdate', () => {
      const p = audio && audio.duration ? audio.currentTime / audio.duration : 0
      bars.forEach((b, i) => b.classList.toggle('on', i / bars.length < p))
    })
    audio.addEventListener('ended', stopVoice)
    audio.play().catch(() => {
      stopVoice()
      toast("Couldn't play this voice message", { type: 'error' })
    })
  }

  // ------------------------------------------------------------ live updates
  on('msg', (m, kind) => {
    if (m.chat !== current) return
    // A change to a message already there (a reaction, its key words) leaves
    // the others' live typing alone.
    if (!m.out && kind !== 'update') {
      clearGhost()
      clearTimeout(typingTimer)
      typingTimer = 0
      titleSub.classList.remove('typing')
      renderHeader()
    }
    if (kind === 'update') {
      // Taken back (here or on another device) while being edited: stop.
      if (m.id === editingId && m.status === 'revoked') composer.endEdit()
      if (m.status === 'revoked' && composer.replying?.id === m.id) composer.endReply()
      refreshNode(m)
      // Replies quoting it show what it is now (taken back, rewritten).
      for (const other of thread(current).list) if (other.replyTo === m.id) refreshNode(other)
      reconcile()
      return
    }
    const wasBottom = keepPosition(reconcile)
    const el = nodes.get(m.id)
    if (el && !reducedMotion()) {
      el.classList.add('enter')
      el.addEventListener('animationend', () => el.classList.remove('enter'), { once: true })
    }
    if (m.out) {
      // Sending is reading, on the server too: what's above it counts as read.
      if (!String(m.id).startsWith('local:') && m.ts > readUpTo) {
        readUpTo = m.ts
        markReadSoon()
      }
      return
    }
    composer.offerReply()
    if (mentionsMe(m) && !(wasBottom && document.visibilityState === 'visible')) {
      mentionIds.push(m.id)
      showMentions()
    }
    // Counted (or read) once it has been on screen.
    markReadSoon()
    if (!(wasBottom && document.visibilityState === 'visible')) {
      newIds.push(m.id)
      newCount = newIds.length
      jumpBadge.textContent = newCount > 99 ? '99+' : String(newCount)
      jumpBadge.hidden = false
      jump.classList.add('on')
      syncPills()
      symbolEffect(jump.querySelector('.icon'), 'bounce-down')
    }
    announce(`${m.fromName ? `${m.fromName}: ` : ''}${spokenMentions(m.text, m) || 'New message'}`)
  })

  on('replace', (fromId, m) => {
    if (m.chat !== current) return
    // Sent from here: the server took it as reading everything before it.
    if (m.out && m.ts > readUpTo) {
      readUpTo = m.ts
      markReadSoon()
    }
    const el = nodes.get(fromId)
    if (el) {
      nodes.delete(fromId)
      nodes.set(m.id, el)
      el.dataset.id = m.id
      if (seps.has(fromId)) {
        seps.set(m.id, seps.get(fromId))
        seps.delete(fromId)
      }
      el.querySelector('.bubble')?.classList.remove('sending')
      const pill = el.querySelector('.m-retry')
      if (pill) {
        pill.classList.add('gone')
        setTimeout(() => pill.remove(), reducedMotion() ? 0 : 200)
      }
      // The sent message keeps its local preview; the node is now current.
      el.bodySig = bodySig(m)
    }
    keepPosition(reconcile)
  })

  on('remove', (id, chat) => {
    if (chat !== current) return
    keepPosition(reconcile)
  })

  on('cleared', chat => {
    if (chat !== current) return
    reconcile()
  })

  on('chats', () => renderHeader())
  on('prefs', () => applyBackdrop())
  function applyBackdrop() {
    if (!current) return
    const value = chatBackdrop(current)
    paintBackdrop(backdrop, value)
    // Notes and times on it get a plate of their own to stay readable.
    root.classList.toggle('has-backdrop', Boolean(readBackdrop(value)))
  }

  return {
    open,
    close,
    catchUp,
    setTyping,
    /** Someone finished what they were typing without a new message (an edit saved). */
    typingDone(room) {
      if (room !== current) return
      clearTimeout(typingTimer)
      typingTimer = 0
      titleSub.classList.remove('typing')
      clearGhost()
      renderHeader()
    },
    get current() {
      return current
    },
    /** The connection's state, as the list shows it: { spinner } while connecting. */
    setStatus({ spinner = false } = {}) { setOffline(spinner) },
    showEmpty() {
      close()
      root.hidden = true
      empty.hidden = false
    },
    /** single | leading | trailing: the column's place in the window (see ui/strip.js). */
    setLayout(layout) {
      pane.dataset.layout = layout
      arrangeBars()
      if (readHeld && current) markReadSoon()
    },
    bars,
    setTool: (id, active) => composer.setTool(id, active),
    sendDrawing: (blob, size) => sendDrawing(blob, size),
    focusComposer() {
      composer.focus()
    },
    root
  }
}
