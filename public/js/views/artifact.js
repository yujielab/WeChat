// Details column: the strip's fourth column, beside the conversation. It
// shows one thing at a time for the open conversation — its details, or the
// drawing board — and Close (Back, when it has the screen to itself) returns
// to the conversation.

import { h } from '../ui/dom.js'
import { createBars, railed } from '../ui/bars.js'
import { onBars } from '../ui/viewport.js'
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
    pane.setAttribute('aria-label', kind === 'draw' ? 'Drawing board' : roomInfoTitle(chat))
  }

  function clear() {
    current?.view.destroy()
    current?.body.remove()
    current = null
  }

  // Details need no heading — the profile at their top says whose they are.
  // Close (Back, folded, where the details replace the conversation) leads
  // the bar at their foot — or the rail, where the system keeps its column on
  // the right edge (the Duo).
  function infoView(chat, body) {
    const bars = createBars({
      label: 'Details actions',
      items: [
        { id: 'back', icon: 'chevron-left', title: 'Back to conversation', primary: true, onSelect: () => onClose() },
        { id: 'close', icon: 'xmark', title: 'Close', primary: true, onSelect: () => onClose() }
      ],
      arrange: axis => {
        const lead = [[pane.dataset.layout === 'single' ? 'back' : 'close']]
        return axis === 'vertical' ? { top: lead, bottom: [] } : { top: [], bottom: lead }
      }
    })
    const content = h('div', { class: 'art-content' })
    const bottombar = h('nav', { class: 'art-bottombar dock', 'aria-label': 'Details actions' }, bars.bottom)
    const rail = h('nav', { class: 'duo-rail art-rail', 'aria-label': 'Details actions' })
    body.append(h('div', { class: 'scroll art-scroll' }, content), bottombar, rail)
    renderRoomInfo(chat, { body: content, host: { el: pane, close: onClose }, loadContacts })

    let frame = 0
    const arrange = () => {
      cancelAnimationFrame(frame)
      frame = requestAnimationFrame(() => {
        const vertical = railed(pane)
        body.dataset.bars = vertical ? 'vertical' : 'horizontal'
        if (vertical) {
          if (bars.top.parentElement !== rail) bars.move(() => rail.append(bars.top, bars.bottom))
          bars.layout('vertical', rail.clientHeight)
        } else {
          if (bars.bottom.parentElement !== bottombar) bars.move(() => { bottombar.append(bars.bottom); bars.top.remove() })
          bars.layout('horizontal', { bottom: bottombar.clientWidth })
        }
      })
    }
    const ro = new ResizeObserver(arrange)
    ro.observe(bottombar)
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
    /** An unsent drawing would be lost by leaving: { anchor } to ask from, or null. */
    get unsaved() {
      return current?.kind === 'draw' && current.view.dirty ? { anchor: current.view.closeButton, canvas: current.view.canvas } : null
    },
    get current() {
      return current && { kind: current.kind, chat: current.chat }
    },
    /** The drawing board's canvas, to give focus to, or null. */
    get canvas() {
      return current?.kind === 'draw' ? current.view.canvas || null : null
    },
    setLayout(layout) {
      pane.dataset.layout = layout
      current?.view.relayout?.()
    }
  }
}
