// Conversation view.

import { h, icon, clear, reducedMotion, announce, edge } from '../ui/dom.js'
import { threadTime } from '../ui/format.js'
import { haptic } from '../ui/haptics.js'
import { cancelPress } from '../ui/press.js'
import {
  state, on, thread, mergeMessages, upsertMessage, replaceMessage, removeMessage, chatInfo,
  unreadTotal, newCid, patchRoom, upsertRoom, normMsg, avatarOf, nameOf, setMembers
} from '../store.js'
import { api } from '../api.js'
import { avatar } from './avatar.js'
import { renderBubble, hasTail } from './bubbles.js'
import { createComposer, prepareImage } from './composer.js'
import { openDrawing } from './draw.js'
import { openViewer } from './viewer.js'
import { openMenu, toast } from './overlay.js'

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
const sameRun = (a, b) =>
  a && b && !isSys(a) && !isSys(b) && a.out === b.out && a.from === b.from && b.ts - a.ts < RUN_GAP

export function createThread(pane, { onBack, onInfo, onCall, socketSend }) {
  pane.classList.add('pane-thread')
  let current = null
  let newCount = 0
  let suppressClick = false
  const nodes = new Map()
  const seps = new Map()
  const retryFiles = new Map()
  const ctx = { maxMedia: 240 }

  // ------------------------------------------------------------ skeleton
  const olderEl = h('div', { class: 'load-older', 'aria-live': 'polite' })
  const meta = h('div', { class: 'm-meta' })
  const msgs = h('div', { class: 'msgs' }, olderEl)
  const scroller = h('div', { class: 'scroll thread-scroll', role: 'log', 'aria-label': '消息' }, msgs)
  scroller.style.overflowAnchor = 'none'

  const backCount = h('span', { class: 'count tabular' })
  const back = h('button', { class: 'glass glass-btn back', type: 'button', 'aria-label': '返回聊天列表' }, icon('chevron-left'), backCount)
  const titleName = h('span', { class: 'name' })
  const titleSub = h('span', { class: 'sub' })
  const titleAvatar = h('span')
  const titleBtn = h('button', { class: 'glass glass-pill thread-title', type: 'button' }, titleAvatar, h('span', { class: 't' }, titleName, titleSub))
  const audioCall = h('button', { class: 'glass glass-btn', type: 'button', 'aria-label': '语音通话' }, icon('phone'))
  const videoCall = h('button', { class: 'glass glass-btn', type: 'button', 'aria-label': '视频通话' }, icon('video'))
  const infoBtn = h('button', { class: 'glass glass-btn info', type: 'button', 'aria-label': '聊天信息' }, icon('info'))
  const navActions = h('div', { class: 'nav-actions' }, audioCall, videoCall, infoBtn)
  const nav = h('header', { class: 'thread-nav' }, back, titleBtn, navActions)

  const jumpBadge = h('span', { class: 'badge', hidden: true })
  const jump = h('button', { class: 'glass glass-btn jump', type: 'button', 'aria-label': '回到最新消息' }, icon('chevron-down'), jumpBadge)

  const composer = createComposer({
    onSend: text => sendText(text),
    onImages: files => sendImages(files),
    onHeight: px => root.style.setProperty('--composer-h', `${px}px`),
    onType: () => sendTyping(),
    onDraw: () => openDrawing({ onSend: (blob, size) => sendDrawing(blob, size) })
  })

  const edgeTop = edge('top')
  const edgeBottom = edge('bottom', true)
  const root = h('div', { class: 'thread', hidden: true }, scroller, edgeTop, nav, edgeBottom, composer.el, jump)
  const empty = h('div', { class: 'thread-empty' }, h('div', {}, icon('bubble'), h('p', {}, '选择一个聊天')))
  pane.append(empty, root)

  back.addEventListener('click', () => onBack())
  titleBtn.addEventListener('click', () => current && onInfo(current))
  infoBtn.addEventListener('click', () => current && onInfo(current))
  jump.addEventListener('click', () => scrollToBottom(true))
  audioCall.addEventListener('click', () => current && onCall?.(current, 'audio'))
  videoCall.addEventListener('click', () => current && onCall?.(current, 'video'))

  new ResizeObserver(([e]) => {
    ctx.maxMedia = Math.round(Math.min(280, Math.max(180, e.contentRect.width * 0.6)))
  }).observe(pane)


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
    const bub = renderBubble(m, ctx)
    const sender = room && !m.out ? h('div', { class: 'm-sender' }, who) : null
    const av = h('span', { class: 'm-avatar' }, room && !m.out ? avatar(avatarOf(m.from, current), who, { size: 28 }) : null)
    const status = m.status === 'failed'
      ? h('button', { class: 'm-status', type: 'button', 'aria-label': '发送失败，点按重试' }, icon('exclaim'))
      : null
    return h('div', {
      class: ['m', m.out ? 'out' : 'in', room ? (m.out ? 'room-out' : 'room-in') : 'dm'],
      dataset: { id: m.id }
    }, av, h('div', { class: 'm-col' }, sender, bub), status)
  }

  function nodeFor(m) {
    let el = nodes.get(m.id)
    if (!el) {
      el = buildNode(m)
      nodes.set(m.id, el)
    }
    return el
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
    meta.className = `m-meta${lastOut.status === 'failed' ? ' failed' : ''}`
    meta.textContent = lastOut.status === 'sending' ? '发送中…' : lastOut.status === 'failed' ? '未发送' : '已发送'
    const node = nodes.get(lastOut.id)
    if (node && node.nextSibling !== meta) node.after(meta)
  }

  /** Bring the DOM in line with the thread's message list, reusing nodes. */
  function reconcile() {
    const t = thread(current)
    const list = t.list
    const want = []
    let prev = null
    for (const m of list) {
      if (!prev || m.ts - prev.ts > TS_GAP) want.push(sepFor(m))
      want.push(nodeFor(m))
      prev = m
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
    decorate(list)
    placeMeta(list)
    if (t.loaded && !list.length) olderEl.textContent = '还没有消息，打个招呼吧'
    else if (t.loaded && !t.hasMore) olderEl.textContent = '没有更早的消息了'
    else if (!t.loading) olderEl.textContent = ''
  }

  function refreshNode(m) {
    const old = nodes.get(m.id)
    if (!old) return
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
  }

  /** Apply a DOM change at the bottom without moving what the reader is looking at. */
  function keepPosition(change) {
    const wasBottom = atBottom()
    const h0 = scroller.scrollHeight
    const top0 = scroller.scrollTop
    change()
    if (!wasBottom) scroller.scrollTop = top0 - (scroller.scrollHeight - h0)
    return wasBottom
  }

  let ticking = false
  scroller.addEventListener('scroll', () => {
    if (ticking) return
    ticking = true
    requestAnimationFrame(() => {
      ticking = false
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
    newCount = 0
    jumpBadge.hidden = true
    jump.classList.remove('on')
    for (const el of [...msgs.children]) if (el !== olderEl) el.remove()
    nodes.clear()
    seps.clear()
    root.hidden = false
    empty.hidden = true
    renderHeader()
    composer.setChat(id, { readonly: false })
    ensureRoom(id)
    const t = thread(id)
    reconcile()
    scrollToBottom()
    // Side by side there is no push; the new conversation settles in place.
    if (pane.dataset.layout === 'split' && !reducedMotion()) {
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
        if (current !== id) return
        mergeMessages(id, r.messages.map(normMsg))
        t.loaded = true
        t.hasMore = r.messages.length >= PAGE
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
    current = null
  }

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible' && current) markReadSoon()
  })

  let typingTimer = 0
  function renderHeader() {
    if (!current) return
    const c = chatInfo(current) || { id: current, name: '聊天' }
    const room = c.kind === 'group'
    titleAvatar.replaceChildren(avatar(c.avatar, c.name, { room, size: 32 }))
    titleName.textContent = c.name
    if (!typingTimer) titleSub.textContent = room ? (c.count ? `${c.count} 位成员` : '') : (c.online ? '在线' : '')
    titleBtn.setAttribute('aria-label', `${c.name}，查看聊天信息`)
    const n = unreadTotal(current)
    backCount.textContent = n ? (n > 99 ? '99+' : String(n)) : ''
    back.setAttribute('aria-label', n ? `返回聊天列表，${n} 条未读` : '返回聊天列表')
  }

  // ------------------------------------------------------------ read state
  let readTimer = 0
  function markReadSoon(force = false) {
    clearTimeout(readTimer)
    readTimer = setTimeout(() => {
      if (!current || document.visibilityState !== 'visible') return
      const c = state.chats.get(current)
      if (!force && !c?.unread) return
      if (c?.unread) patchRoom(current, { unread: 0 })
      socketSend({ t: 'read', room: current, ts: Date.now() })
    }, 350)
  }

  // ------------------------------------------------------------ sending
  const previewText = m => ({ image: '[图片]', voice: '[语音]', video: '[视频]', file: '[文件]' }[m.type] || m.text || '')
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
      const prepared = await prepareImage(f)
      await sendPrepared(chat, prepared)
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
    scrollToBottom()
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
  function sendTyping() {
    const now = Date.now()
    if (current && now - typingSentAt > 2500) { typingSentAt = now; socketSend({ t: 'typing', room: current }) }
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

  function setTyping(room, uid) {
    if (room !== current) return
    clearTimeout(typingTimer)
    const who = isGroup(current) ? `${nameOf(uid, current)} ` : ''
    titleSub.textContent = `${who}正在输入…`
    titleSub.classList.add('typing')
    typingTimer = setTimeout(() => { typingTimer = 0; titleSub.classList.remove('typing'); renderHeader() }, 4000)
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
    if (e.target.closest('.m-status')) return messageMenu(node, m)
    if (e.target.closest('a')) return
    const bub = e.target.closest('.bubble')
    if (!bub) return
    switch (bub.dataset.kind) {
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
        else toast('请在手机上查看', { iconName: 'info' })
        break
      }
      case 'file':
        if (m.url) window.open(m.url, '_blank', 'noopener')
        break
      case 'location':
        window.open(`https://maps.apple.com/?q=${encodeURIComponent(m.title || '')}`, '_blank', 'noopener')
        break
      case 'money':
        toast('请在手机上查看', { iconName: 'info' })
        break
    }
  })

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
    if (m.status === 'failed') main.push({ label: '重新发送', icon: 'refresh', onSelect: () => retry(m) })
    if (m.type === 'text' && m.text) {
      main.push({ label: '复制', icon: 'copy', onSelect: () => copy(m.text) })
    }
    if (m.type === 'link' && safeUrl(m.url)) {
      main.push({ label: '打开链接', icon: 'link', onSelect: () => window.open(safeUrl(m.url), '_blank', 'noopener,noreferrer') })
      main.push({ label: '复制链接', icon: 'copy', onSelect: () => copy(m.url) })
    }
    if (m.type === 'image') main.push({ label: '查看图片', icon: 'photo', onSelect: () => bub.click() })
    if (m.type === 'file') main.push({ label: '下载文件', icon: 'download', onSelect: () => m.url && window.open(m.url, '_blank', 'noopener') })
    items.push(main)
    const canRevoke = m.out && !String(m.id).startsWith('local:') && Date.now() - m.ts < 2 * 60 * 1000
    const danger = []
    if (canRevoke) danger.push({ label: '撤回', icon: 'undo', onSelect: () => revoke(m) })
    danger.push({ label: '从本设备删除', icon: 'trash', destructive: true, onSelect: () => deleteLocal(m) })
    items.push(danger)

    openMenu(rect, items, {
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
    node?.querySelector('.voice-btn')?.replaceChildren(icon('play'))
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
    bub.querySelector('.voice-btn').replaceChildren(icon('pause'))
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
    }
    reconcile()
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
    setLayout(layout) {
      pane.dataset.layout = layout
    },
    focusComposer() {
      composer.focus()
    },
    root
  }
}
