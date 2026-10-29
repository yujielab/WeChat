// Details column: the strip's fourth column, beside the conversation. It
// shows one thing at a time for the open conversation — its details, or the
// drawing board — and Close (Back, when it has the screen to itself) returns
// to the conversation.

import { h } from '../ui/dom.js'
import { createBars } from '../ui/bars.js'
import { getBars, onBars } from '../ui/viewport.js'
import { renderRoomInfo, roomInfoTitle } from './sheets.js'
import { createDrawing } from './draw.js'

export function createArtifact(pane, { onClose, onSend, loadContacts }) {
  pane.classList.add('pane-artifact')
  let current = null // { kind, chat, view, body }

  function show(kind, chat) {
    if (current?.kind === kind && current.chat === chat) return
    clear()
    const body = h('div', { class: 'art-body', dataset: { kind } })
    pane.append(body)
    const view = kind === 'draw'
      ? createDrawing(body, { onSend: (blob, size) => onSend(blob, size), onClose })
      : infoView(chat, body)
    current = { kind, chat, view, body }
    pane.setAttribute('aria-label', kind === 'draw' ? '画板' : roomInfoTitle(chat))
  }

  function clear() {
    current?.view.destroy()
    current?.body.remove()
    current = null
  }

  // Details need no heading — the profile at their top says whose they are.
  // Close (Back, folded, where the details replace the conversation) leads
  // the bars, on the trailing edge wherever the window's bars are vertical.
  function infoView(chat, body) {
    const bars = createBars({
      label: '详情操作',
      items: [
        { id: 'back', icon: 'chevron-left', title: '返回对话', primary: true, onSelect: () => onClose() },
        { id: 'close', icon: 'xmark', title: '关闭', primary: true, onSelect: () => onClose() }
      ],
      arrange: () => ({ top: [[pane.dataset.layout === 'single' ? 'back' : 'close']], bottom: [] })
    })
    const head = h('header', { class: 'art-head' })
    const content = h('div', { class: 'art-content' })
    const rail = h('nav', { class: 'duo-rail art-rail', 'aria-label': '详情操作' })
    body.append(h('div', { class: 'scroll art-scroll' }, content), head, rail)
    renderRoomInfo(chat, { body: content, host: { el: pane, close: onClose }, loadContacts })

    let frame = 0
    const arrange = () => {
      cancelAnimationFrame(frame)
      frame = requestAnimationFrame(() => {
        const axis = getBars() || 'vertical'
        body.dataset.bars = axis
        if (axis === 'vertical') {
          if (bars.top.parentElement !== rail) bars.move(() => rail.append(bars.top, bars.bottom))
          bars.layout('vertical', rail.clientHeight)
        } else {
          if (bars.top.parentElement !== head) bars.move(() => { head.prepend(bars.top); bars.bottom.remove() })
          bars.layout('horizontal', { top: Infinity, bottom: Infinity })
        }
      })
    }
    const ro = new ResizeObserver(arrange)
    ro.observe(rail)
    const off = onBars(arrange)
    return {
      relayout: arrange,
      destroy() {
        ro.disconnect()
        off()
        cancelAnimationFrame(frame)
      }
    }
  }

  return {
    show,
    clear,
    get current() {
      return current && { kind: current.kind, chat: current.chat }
    },
    setLayout(layout) {
      pane.dataset.layout = layout
      current?.view.relayout?.()
    }
  }
}
