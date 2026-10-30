// Conversation view.

import { h, icon, clear, reducedMotion, announce, edge } from '../ui/dom.js'
import { symbolEffect, replaceSymbol } from '../ui/symbols.js'
import { threadTime } from '../ui/format.js'
import { haptic } from '../ui/haptics.js'
import { cancelPress } from '../ui/press.js'
import {
  state, on, thread, mergeMessages, upsertMessage, replaceMessage, removeMessage, chatInfo,
  unreadTotal, newCid, patchRoom, upsertRoom, normMsg, avatarOf, nameOf, setMembers
} from '../store.js'
import { api } from '../api.js'
import { avatar } from './avatar.js'
import { renderBubble, hasTail, mediaSize } from './bubbles.js'
import { createComposer, prepareImage } from './composer.js'
import { openViewer } from './viewer.js'
import { openMenu, toast } from './overlay.js'
import { bindImageDropTarget } from './attachments.js'
import { renderPhotoStack, openPhotoStack, stackSize } from './photo-stack.js'
import { createBars } from '../ui/bars.js'

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
const isSys = m => m.type === 'system'
const REACTIONS = ['❤️', '😂', '👍', '😮', '😢', '🙏']
const REACTION_NAMES = { '❤️': '喜欢', '😂': '大笑', '👍': '赞', '😮': '惊讶', '😢': '难过', '🙏': '感谢' }
const reactable = m => m && !isSys(m) && !String(m.id).startsWith('local:') && !['sending', 'failed', 'revoked'].includes(m.status)
const myReaction = m => m.reactions?.find(g => g.users.includes(state.me?.id))?.emoji || ''
// What a bubble shows, apart from its reactions: a reaction alone patches the
// chip in place rather than rebuilding (and re-fading) the whole message.
const bodySig = m => [m.type, m.text, m.url, m.status === 'read' ? 'sent' : m.status, m.w, m.h, m.dur, m.name].join('\u0001')
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

export function createThread(pane, { onBack, onInfo, onDraw, onCall, socketSend }) {
  pane.classList.add('pane-thread')
  let current = null
  let newCount = 0
  let suppressClick = false
  const nodes = new Map()
  const seps = new Map()
  const retryFiles = new Map()
  const photoGroups = new Map()
  const expandedPhotos = new Set()
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
  const scroller = h('div', { class: 'scroll thread-scroll', role: 'log', 'aria-label': '消息' }, foot, msgs)
  scroller.style.overflowAnchor = 'none'

  // The conversation's heading is content: it stays with the messages on
  // every display, and opens the chat's details.
  const titleName = h('span', { class: 'name' })
  const titleSub = h('span', { class: 'sub' })
  const titleAvatar = h('span', { class: 'thread-person' })
  const titleBtn = h('button', { class: 'glass glass-pill thread-title', type: 'button' }, titleAvatar, h('span', { class: 't' }, titleName, titleSub))
  const nav = h('header', { class: 'thread-nav' }, titleBtn)

  // The calls and the details sit in the heading, after the name; Back
  // leads the bar at the foot of the conversation, before the field, and the
  // field's own button (photos and drawing, or Send) follows it. Beside the
  // list (unfolded) there is no Back: the list is right there. Details open
  // in the next column, so their item shows whether it's open.
  const unreadBadge = () => {
    const n = current ? unreadTotal(current) : 0
    return n ? (n > 99 ? '99+' : String(n)) : ''
  }
  const bars = createBars({
    label: '聊天操作',
    items: [
      { id: 'back', icon: 'chevron-left', title: '返回聊天列表', primary: true, badge: unreadBadge, onSelect: () => onBack() },
      { id: 'audio', icon: 'phone', title: '语音通话', priority: 6, onSelect: () => current && onCall?.(current, 'audio') },
      { id: 'video', icon: 'video', title: '视频通话', priority: 5, onSelect: () => current && onCall?.(current, 'video') },
      { id: 'info', icon: 'info', title: '聊天信息', priority: 2, toggle: true, onSelect: () => current && onInfo(current) },
    ],
    arrange: () => {
      // Calls only where the server can carry them.
      const calls = state.calls?.enabled ? [['audio', 'video']] : []
      const back = pane.dataset.layout === 'trailing' ? [] : [['back']]
      return { top: [...calls, ['info']], bottom: back }
    }
  })

  const jumpBadge = h('span', { class: 'badge', hidden: true })
  const jump = h('button', { class: 'glass glass-btn jump', type: 'button', 'aria-label': '回到最新消息' }, icon('chevron-down'), jumpBadge)

  const composer = createComposer({
    onSend: text => sendText(text),
    onImages: files => sendImages(files),
    onHeight: px => root.style.setProperty('--composer-h', `${px}px`),
    onType: text => sendTyping(text),
    // Photos and the drawing board come from the button after the field.
    tools: [
      { id: 'photo', icon: 'photo', title: '照片', onSelect: () => current && composer.openImages() },
      { id: 'draw', icon: 'brush', title: '手绘', onSelect: () => current && onDraw(current) }
    ]
  })

  const edgeTop = edge('top')
  const root = h('div', { class: 'thread', hidden: true }, scroller, edgeTop, nav, composer.el, jump)
  nav.append(bars.top)
  composer.el.classList.add('dock')
  composer.dock(bars.bottom)

  // The name keeps at least 150px of the heading; the field keeps at least
  // 160px of the bar at the foot, and its 56pt button after it.
  let barsFrame = 0
  function arrangeBars() {
    cancelAnimationFrame(barsFrame)
    barsFrame = requestAnimationFrame(() => {
      const cs = getComputedStyle(composer.el)
      const inner = composer.el.clientWidth - parseFloat(cs.paddingLeft) - parseFloat(cs.paddingRight)
      bars.layout({ top: Math.max(0, nav.clientWidth - 150), bottom: Math.max(0, inner - 160 - 8 - 56 - 8) })
    })
  }
  new ResizeObserver(arrangeBars).observe(nav)
  new ResizeObserver(arrangeBars).observe(composer.el)
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
      const [w, h] = mediaSize(message.w, message.h, Math.max(64, ctx.maxMedia - (message.status === 'failed' ? 34 : 0)), message.type === 'video' ? 300 : 320)
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
      el = h('div', { class: 'ts', role: 'separator' }, h('b', {}, day), ` ${time}`)
      seps.set(m.id, el)
    }
    return el
  }

  function buildNode(m) {
    if (isSys(m)) return h('div', { class: 'sys', dataset: { id: m.id } }, m.recalled || m.text || '')
    const room = isGroup(current)
    const who = m.fromName || nameOf(m.from, current)
    const bub = renderBubble(m, m.status === 'failed' ? { ...ctx, maxMedia: Math.max(64, ctx.maxMedia - 34) } : ctx)
    const sender = room && !m.out ? h('div', { class: 'm-sender' }, who) : null
    const av = h('span', { class: 'm-avatar', 'aria-hidden': 'true' }, avatar(avatarOf(m.from, current), who))
    const status = m.status === 'failed'
      ? h('button', { class: 'm-status', type: 'button', 'aria-label': '发送失败，点按重试' }, icon('exclaim'))
      : null
    const el = h('div', {
      class: ['m', 'has-avatar', m.out ? 'out' : 'in', room ? (m.out ? 'room-out' : 'room-in') : 'dm'],
      dataset: { id: m.id }
    }, av, h('div', { class: 'm-col' }, sender, bub, reactionChip(m)), status)
    el.bodySig = bodySig(m)
    el.reactSig = reactSig(m)
    return el
  }

  /** Reactions hang off the bubble's lower edge, away from its tail (sketch 1). */
  function reactionChip(m) {
    const groups = m.reactions || []
    if (!groups.length) return null
    const total = groups.reduce((n, g) => n + g.users.length, 0)
    return h('button', {
      class: ['m-reactions', myReaction(m) && 'mine'],
      type: 'button',
      'aria-label': `回应：${groups.map(g => `${REACTION_NAMES[g.emoji] || g.emoji} ${g.users.length}`).join('，')}，点按更改`
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
    if (!el || el.photoSignature) {
      const old = el
      el = buildNode(m)
      old?.replaceWith(el)
      nodes.set(m.id, el)
    }
    return el
  }

  const groupablePhoto = m => m?.type === 'image' && m.url && !m.recalled && !['sending', 'failed'].includes(m.status) && !String(m.id).startsWith('local:') && !expandedPhotos.has(m.id)
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
      const who = last.out ? '我' : last.fromName || nameOf(last.from, current)
      const sender = {
        avatar: avatar(avatarOf(last.from, current), who, { size: 30 }),
        label: `${who} · ${threadTime(photos[0].ts)[1]}`
      }
      fresh.querySelector('.bubble').replaceWith(renderPhotoStack(photos, ctx, { onExpand: expandPhotos, sender }))
      fresh.classList.add('has-stack')
      fresh.photoSignature = signature
      node?.replaceWith(fresh)
      node = fresh
      nodes.set(last.id, node)
    }
    photoGroups.set(last.id, photos)
    return node
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

  function placeMeta(list) {
    const last = list[list.length - 1]
    const lastOut = [...list].reverse().find(m => m.out && !isSys(m))
    const show = lastOut && (lastOut === last || lastOut.status === 'sending' || lastOut.status === 'failed')
    if (!show) {
      meta.remove()
      return
    }
    const c = chatInfo(current)
    const read = c?.kind === 'dm' && (lastOut.status === 'read' || (c.peerRead && lastOut.ts <= c.peerRead))
    meta.className = `m-meta${lastOut.status === 'failed' ? ' failed' : ''}${read ? ' read' : ''}`
    meta.textContent = lastOut.status === 'sending' ? '发送中…' : lastOut.status === 'failed' ? '未发送' : read ? '已读' : '已发送'
    const node = nodes.get(lastOut.id)
    if (node && node.nextSibling !== meta) node.after(meta)
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
      const last = photos[photos.length - 1]
      const message = photos.length > 1 ? { ...last, ts: first.ts } : first
      if (!prev || first.ts - prev.ts > TS_GAP) want.push(sepFor(message))
      want.push(photos.length > 1 ? photoNode(photos) : nodeFor(message))
      visible.push(message)
      prev = last
    }
    const keep = new Set(want)
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
    placeMeta(list)
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
    jumpBadge.hidden = true
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
      if (atBottom() && newCount) {
        newCount = 0
        jumpBadge.hidden = true
        markReadSoon()
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
    newCount = 0
    jumpBadge.hidden = true
    jump.classList.remove('on')
    for (const el of [...msgs.children]) if (el !== olderEl) el.remove()
    // A page still loading for the last conversation isn't this one's.
    olderEl.replaceChildren()
    nodes.clear()
    seps.clear()
    photoGroups.clear()
    root.hidden = false
    empty.hidden = true
    renderHeader()
    composer.setChat(id, { readonly: false })
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
        olderEl.replaceChildren(h('span', { class: 'spinner' }))
        const r = await api.get(`/api/messages?room=${encodeURIComponent(id)}&limit=${PAGE}`)
        // Kept even if another conversation opened meanwhile: coming back is instant.
        if (!t.loaded) {
          mergeMessages(id, r.messages.map(normMsg))
          t.loaded = true
          t.hasMore = r.messages.length >= PAGE
        }
        if (current !== id) return
        olderEl.replaceChildren()
        reconcile()
        scrollToBottom()
      } else {
        await catchUp(id)
      }
    } catch (err) {
      if (current === id) {
        olderEl.replaceChildren()
        toast(err.message, { type: 'error' })
      }
    }
    markReadSoon(true)
  }

  /** Pull room metadata + members (names/avatars for group bubbles). */
  async function ensureRoom(id) {
    try {
      const r = await api.get(`/api/room/${encodeURIComponent(id)}`)
      if (r.room) upsertRoom(r.room)
      if (r.members) setMembers(id, r.members)
      if (current === id) { renderHeader(); reconcile() }
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
    const c = chatInfo(current) || { id: current, name: '聊天' }
    const room = c.kind === 'group'
    titleAvatar.replaceChildren(avatar(c.avatar, c.name, { room, size: 40 }))
    titleName.textContent = c.name
    titleBtn.classList.toggle('is-online', !room && Boolean(c.online))
    if (!typingTimer) titleSub.textContent = room ? (c.count ? `${c.count} 位成员` : '') : (c.online ? '在线' : '')
    titleBtn.setAttribute('aria-label', `${c.name}，查看聊天信息`)
    // The unread badge on Back is status: it changes what overflows first.
    bars.refresh()
    arrangeBars()
  }

  // ------------------------------------------------------------ read state
  // Messages count as read only while the conversation's column is on
  // screen; a read held back meanwhile goes out when it comes back.
  let readTimer = 0
  let readHeld = false
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
      if (!force && !c?.unread) return
      if (c?.unread) patchRoom(current, { unread: 0 })
      socketSend({ t: 'read', room: current, ts: Date.now() })
    }, 350)
  }

  // ------------------------------------------------------------ sending
  const previewText = m => ({ image: '[图片]', drawing: '[手绘]', voice: '[语音]', video: '[视频]', file: '[文件]' }[m.type] || m.text || '')
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
    for (const k of ['room', 'name', 'w', 'h', 'dur']) if (info[k]) qs.set(k, info[k])
    const res = await fetch(`/api/media/upload?${qs}`, {
      method: 'POST', credentials: 'same-origin',
      headers: { 'content-type': file.type || 'application/octet-stream' }, body: file
    })
    const data = await res.json().catch(() => ({}))
    if (!res.ok || !data.ok) throw new Error(data.error || '上传失败')
    return data
  }

  async function sendText(text, chat = current) {
    if (!chat) return
    const cid = newCid()
    const local = { id: `local:${cid}`, cid, localId: cid, chat, ts: Date.now(), out: true, from: state.me?.id, fromName: state.me?.display, type: 'text', text, status: 'sending' }
    upsertMessage(local)
    bumpList(local)
    if (chat === current) scrollToBottom()
    try {
      const r = await api.post('/api/messages', { room: chat, type: 'text', text, localId: cid })
      if (r.msg) replaceMessage(local.id, normMsg(r.msg))
    } catch (err) {
      upsertMessage({ ...local, status: 'failed' })
      toast(err.message || '发送失败', { type: 'error' })
    }
  }

  async function sendImages(files) {
    const chat = current
    if (!chat) return
    for (const f of files) {
      try {
        await sendPrepared(chat, await prepareImage(f))
      } catch (err) {
        toast(err.message || '无法处理这张图片', { type: 'error' })
      }
    }
  }

  async function sendPrepared(chat, { file, w, h: hh }) {
    const cid = newCid()
    const preview = URL.createObjectURL(file)
    state.previews.set(cid, preview)
    retryFiles.set(cid, { file, w, h: hh })
    const local = { id: `local:${cid}`, cid, localId: cid, chat, ts: Date.now(), out: true, from: state.me?.id, type: 'image', w, h: hh, url: preview, status: 'sending' }
    upsertMessage(local)
    bumpList(local)
    if (chat === current) scrollToBottom()
    try {
      const up = await uploadMedia('image', file, { room: chat, name: file.name || 'photo.jpg', w, h: hh })
      const r = await api.post('/api/messages', { room: chat, type: 'image', meta: { ...up.meta, url: up.url }, localId: cid })
      if (r.msg) replaceMessage(local.id, normMsg(r.msg))
      retryFiles.delete(cid)
    } catch (err) {
      upsertMessage({ ...local, status: 'failed' })
      toast(err.message || '图片发送失败', { type: 'error' })
    }
  }

  let typingSentAt = 0
  function sendTyping(text = '') {
    const now = Date.now()
    // Honk-style live typing: stream the in-progress text so the peer sees it
    // as it is typed. Throttled; empty text clears the peer's ghost bubble.
    if (current && (now - typingSentAt > 180 || !text)) {
      typingSentAt = now
      socketSend({ t: 'typing', room: current, text: text.slice(0, 500) })
    }
  }

  async function sendDrawing(blob, { w, h } = {}) {
    const chat = current
    if (!chat) return
    const file = new File([blob], 'drawing.png', { type: 'image/png' })
    const cid = newCid()
    const preview = URL.createObjectURL(file)
    state.previews.set(cid, preview)
    const local = { id: `local:${cid}`, cid, localId: cid, chat, ts: Date.now(), out: true, from: state.me?.id, type: 'drawing', w, h, url: preview, status: 'sending' }
    upsertMessage(local)
    bumpList(local)
    scrollToBottom()
    try {
      const up = await uploadMedia('image', file, { room: chat, name: 'drawing.png', w, h })
      const r = await api.post('/api/messages', { room: chat, type: 'drawing', meta: { ...up.meta, url: up.url }, localId: cid })
      if (r.msg) replaceMessage(local.id, normMsg(r.msg))
    } catch (err) {
      upsertMessage({ ...local, status: 'failed' })
      toast(err.message || '发送失败', { type: 'error' })
    }
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
    titleSub.textContent = `${who}正在输入…`
    titleSub.classList.add('typing')
    typingTimer = setTimeout(() => { typingTimer = 0; titleSub.classList.remove('typing'); renderHeader(); clearGhost() }, 4500)
  }

  async function retry(m) {
    removeMessage(m.id, m.chat)
    if (m.type === 'image') {
      const f = retryFiles.get(m.cid)
      if (f) return sendPrepared(m.chat, f)
      return toast('请重新选择这张图片', { type: 'error' })
    }
    if (m.text) await sendText(m.text, m.chat)
  }

  function deleteLocal(m) {
    removeMessage(m.id, m.chat)
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
    if (e.target.closest('.m-status, .m-reactions')) return messageMenu(node, m)
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
          findThumb: () => nodes.get(m.id)?.querySelector('.bubble img')
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
          label: '视频',
          findThumb: () => nodes.get(m.id)?.querySelector('.bubble img')
        })
        break
      case 'voice':
        toggleVoice(m, bub)
        break
      case 'link': {
        const url = safeUrl(m.url)
        if (url) window.open(url, '_blank', 'noopener,noreferrer')
        else toast('无法打开这个链接', { type: 'error' })
        break
      }
      case 'file':
        if (m.url) window.open(m.url, '_blank', 'noopener')
        break
      case 'location':
        window.open(`https://maps.apple.com/?q=${encodeURIComponent(m.title || '')}`, '_blank', 'noopener')
        break
      case 'money':
        toast('暂不支持查看这条消息', { iconName: 'info' })
        break
    }
  })

  let lastTap = {}

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
    announce(next ? `已回应${REACTION_NAMES[next] || next}` : '已取消回应')
    try {
      const r = await api.post('/api/react', { id: m.id, emoji: next })
      const known = thread(chat).byId.get(m.id)
      if (r.msg && known) upsertMessage({ ...known, reactions: r.msg.reactions || [] })
    } catch (err) {
      if (thread(chat).byId.has(m.id)) upsertMessage({ ...thread(chat).byId.get(m.id), reactions: before })
      toast(err.message || '回应失败', { type: 'error' })
    }
  }

  // Long press → context menu (bubbles shrink a touch while held).
  let press = null
  scroller.addEventListener('pointerdown', e => {
    suppressClick = false
    const bub = e.target.closest('.bubble')
    if (!bub || e.button > 0) return
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
        messageMenu(node, m)
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
  scroller.addEventListener('scroll', cancelLong, { passive: true })
  scroller.addEventListener('contextmenu', e => {
    const node = e.target.closest('.m')
    const m = msgOf(node)
    if (!m) return
    e.preventDefault()
    cancelLong()
    messageMenu(node, m)
  })

  function messageMenu(node, m) {
    const bub = node.querySelector('.bubble')
    if (!bub) return
    const layer = document.getElementById('overlays')
    const origin = layer.getBoundingClientRect()
    const rect = bub.getBoundingClientRect()
    const backdrop = h('div', { class: 'ctx-backdrop' })
    const clone = bub.cloneNode(true)
    clone.classList.remove('is-pressed', 'tail')
    const preview = h('div', {
      class: ['ctx-preview', 'm', m.out ? 'out' : 'in'],
      'aria-hidden': 'true', inert: true,
      style: { left: `${rect.left - origin.left}px`, top: `${rect.top - origin.top}px`, width: `${Math.ceil(rect.width) + 1}px`, padding: '0' }
    }, clone)
    layer.append(backdrop, preview)
    bub.style.visibility = 'hidden'
    requestAnimationFrame(() => requestAnimationFrame(() => {
      backdrop.classList.add('on')
      if (!reducedMotion()) preview.style.transform = 'scale(1.03)'
    }))

    const items = []
    const main = []
    const photos = photoGroups.get(m.id)
    if (photos) {
      main.push({ label: `查看 ${photos.length} 张照片`, icon: 'photo', onSelect: () => openPhotoStack({ messages: photos, thumb: bub.querySelector('.photo-stack-cover img'), findThumb: () => nodes.get(m.id)?.querySelector('.photo-stack-cover img') }) })
      main.push({ label: '逐张展开', icon: 'photo', onSelect: () => expandPhotos(photos) })
    }
    if (m.status === 'failed') main.push({ label: '重新发送', icon: 'refresh', onSelect: () => retry(m) })
    if (m.type === 'text' && m.text) {
      main.push({ label: '复制', icon: 'copy', onSelect: () => copy(m.text) })
    }
    if (m.type === 'link' && safeUrl(m.url)) {
      main.push({ label: '打开链接', icon: 'link', onSelect: () => window.open(safeUrl(m.url), '_blank', 'noopener,noreferrer') })
      main.push({ label: '复制链接', icon: 'copy', onSelect: () => copy(m.url) })
    }
    if (m.type === 'image' && !photos) main.push({ label: '查看图片', icon: 'photo', onSelect: () => bub.click() })
    if (m.type === 'file') main.push({ label: '下载文件', icon: 'download', onSelect: () => m.url && window.open(m.url, '_blank', 'noopener') })
    items.push(main)
    const canRevoke = !photos && m.out && !String(m.id).startsWith('local:') && Date.now() - m.ts < 2 * 60 * 1000
    const danger = []
    if (canRevoke) danger.push({ label: '撤回', icon: 'undo', onSelect: () => revoke(m) })
    if (!photos) danger.push({ label: '从本设备删除', icon: 'trash', destructive: true, onSelect: () => deleteLocal(m) })
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
      const row = h('div', { class: 'menu-reactions', role: 'group', 'aria-label': '回应' }, buttons)
      row.addEventListener('keydown', e => {
        if (!['ArrowLeft', 'ArrowRight'].includes(e.key)) return
        e.preventDefault()
        e.stopPropagation()
        const i = buttons.indexOf(document.activeElement)
        buttons[(i + (e.key === 'ArrowRight' ? 1 : -1) + buttons.length) % buttons.length]?.focus()
      })
      return row
    } : null

    openMenu(rect, items, {
      header,
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

  async function copy(text) {
    try {
      await navigator.clipboard.writeText(text)
      toast('已复制', { type: 'ok' })
    } catch {
      toast('无法复制', { type: 'error' })
    }
  }

  async function revoke(m) {
    try {
      const r = await api.post('/api/revoke', { id: m.id })
      if (r.msg) upsertMessage(r.msg)
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
      toast('无法播放这条语音', { type: 'error' })
    })
  }

  // ------------------------------------------------------------ live updates
  on('msg', (m, kind) => {
    if (m.chat !== current) return
    if (!m.out) {
      clearGhost()
      clearTimeout(typingTimer)
      typingTimer = 0
      titleSub.classList.remove('typing')
      renderHeader()
    }
    if (kind === 'update') {
      refreshNode(m)
      reconcile()
      return
    }
    const wasBottom = keepPosition(reconcile)
    const el = nodes.get(m.id)
    if (el && !reducedMotion()) {
      el.classList.add('enter')
      el.addEventListener('animationend', () => el.classList.remove('enter'), { once: true })
    }
    if (m.out) return
    if (wasBottom && document.visibilityState === 'visible') markReadSoon(true)
    else {
      newCount++
      jumpBadge.textContent = newCount > 99 ? '99+' : String(newCount)
      jumpBadge.hidden = false
      jump.classList.add('on')
      symbolEffect(jump.querySelector('.icon'), 'bounce-down')
    }
    announce(`${m.fromName ? `${m.fromName}：` : ''}${m.text || '新消息'}`)
  })

  on('replace', (fromId, m) => {
    if (m.chat !== current) return
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
      el.querySelector('.m-status')?.remove()
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

  return {
    open,
    close,
    catchUp,
    setTyping,
    get current() {
      return current
    },
    showEmpty() {
      close()
      root.hidden = true
      empty.hidden = false
    },
    /** single | leading | trailing: the column's place in the window (see ui/strip.js). */
    setLayout(layout) {
      pane.dataset.layout = layout
      arrangeBars()
      if (readHeld && current) markReadSoon(true)
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
