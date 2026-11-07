// Search and explain (src/explain.js): words picked out of a message
// (views/explain-pick.js) looked up on the web and explained in a sheet.
// Each step shows as it happens — planning the searches, searching the web,
// comparing what was found, writing — then the answer streams in with [n]
// marking where each claim comes from, the sources stand as cards beneath,
// and a few questions to ask next wait as chips (or ask your own).

import { h, icon, announce } from '../ui/dom.js'
import { openSheet } from './overlay.js'

const STEPS = [
  ['plan', 'Understanding the question'],
  ['search', 'Searching the web'],
  ['compare', 'Comparing sources'],
  ['answer', 'Writing the answer']
]
const HISTORY = 3

// ------------------------------------------------------------ the answer's text

/** The answer as elements: paragraphs, "- " lists, **bold**, and [n] as
 *  citation marks that point at source n. Built as nodes, never as HTML. */
export function renderAnswer(text, { cite } = {}) {
  const blocks = []
  let list = null
  const inline = line => {
    const out = []
    // **bold**, and [n] citations (several in a row read as one group)
    const re = /\*\*([^*]+)\*\*|\[(\d{1,2})\]/g
    let last = 0
    for (const m of line.matchAll(re)) {
      if (m.index > last) out.push(line.slice(last, m.index))
      if (m[1] != null) out.push(h('b', {}, m[1]))
      else out.push(citeMark(Number(m[2]), cite))
      last = m.index + m[0].length
    }
    if (last < line.length) out.push(line.slice(last))
    return out
  }
  for (const raw of String(text).split('\n')) {
    const line = raw.trimEnd()
    const item = line.match(/^\s*(?:[-*•]|\d+[.)])\s+(.*)$/)
    if (item) {
      if (!list) { list = h('ul', { class: 'xp-list' }); blocks.push(list) }
      list.append(h('li', {}, ...inline(item[1])))
      continue
    }
    list = null
    if (!line.trim()) continue
    blocks.push(h('p', {}, ...inline(line.replace(/^#+\s*/, ''))))
  }
  return blocks
}

function citeMark(n, cite) {
  const el = h('button', { class: 'xp-cite', type: 'button', dataset: { n: String(n) }, 'aria-label': `Source ${n}` }, String(n))
  el.addEventListener('click', e => { e.stopPropagation(); cite?.(n) })
  return el
}

const siteMark = site => {
  const letter = (site.replace(/^(?:m|en|www)\./, '')[0] || '?').toUpperCase()
  let hue = 0
  for (const c of site) hue = (hue * 31 + c.charCodeAt(0)) % 360
  const el = h('span', { class: 'xp-site', 'aria-hidden': 'true' }, letter)
  el.style.setProperty('--hue', String(hue))
  return el
}

function sourceCard(s) {
  return h('a', { class: 'xp-source', href: s.url, target: '_blank', rel: 'noopener noreferrer', dataset: { n: String(s.id) }, title: s.title },
    h('span', { class: 'xp-source-top' }, siteMark(s.site), h('span', { class: 'xp-host' }, s.site), h('span', { class: 'xp-num' }, String(s.id))),
    h('span', { class: 'xp-source-title' }, s.title))
}

// ------------------------------------------------------------ the stream

/** POST /api/ai/explain and hand each event (a JSON line) to `onEvent`. */
export async function streamExplain(body, { signal, onEvent }) {
  const res = await fetch('/api/ai/explain', {
    method: 'POST',
    credentials: 'same-origin',
    headers: { 'content-type': 'application/json', 'x-tz': String(new Date().getTimezoneOffset()) },
    body: JSON.stringify(body),
    signal
  })
  if (!res.ok || !res.body) {
    let error = `Request failed (${res.status})`
    try { error = (await res.json()).error || error } catch {}
    throw new Error(error)
  }
  const reader = res.body.getReader()
  const decoder = new TextDecoder()
  let buf = ''
  for (;;) {
    const { value, done } = await reader.read()
    if (value) buf += decoder.decode(value, { stream: true })
    let nl
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl).trim()
      buf = buf.slice(nl + 1)
      if (!line) continue
      try { onEvent(JSON.parse(line)) } catch (err) { if (!(err instanceof SyntaxError)) throw err }
    }
    if (done) break
  }
  if (buf.trim()) try { onEvent(JSON.parse(buf)) } catch {}
}

// ------------------------------------------------------------ the sheet

/** Open the sheet for `text` picked out of the message `context`. */
export function openExplain({ text, context = '', origin, onClose } = {}) {
  const turns = h('div', { class: 'xp-turns' })
  const follow = h('div', { class: 'xp-follow', role: 'group', 'aria-label': 'Ask next' })
  const input = h('input', { class: 'xp-input', type: 'text', enterkeyhint: 'send', maxlength: '300', placeholder: 'Ask a follow-up', 'aria-label': 'Ask a follow-up' })
  const send = h('button', { class: 'xp-send', type: 'submit', 'aria-label': 'Ask' }, icon('arrow-up'))
  const form = h('form', { class: 'xp-ask' }, input, send)
  const shown = context && context.trim() !== text.trim()
  const content = h('div', { class: 'xp' },
    h('header', { class: 'xp-head' },
      h('p', { class: 'xp-pick' }, h('span', { class: 'xp-quote' }, text)),
      shown ? h('p', { class: 'xp-context' }, context.length > 160 ? `${context.slice(0, 158)}…` : context) : null),
    turns,
    follow,
    form,
    h('p', { class: 'xp-foot' }, 'Only these words and their message are sent to search.'))

  const history = []
  let busy = null
  const sheet = openSheet({ title: 'Explain', content, tall: true, origin, side: 'thread', onClose: () => { busy?.abort(); onClose?.() } })

  const setBusy = on => {
    input.disabled = on
    send.disabled = on
    for (const b of follow.querySelectorAll('button')) b.disabled = on
  }

  async function ask(question) {
    if (busy || sheet.closed) return
    const turn = h('section', { class: 'xp-turn', 'aria-busy': 'true' })
    if (question) turn.append(h('h3', { class: 'xp-q' }, question))
    const steps = h('ol', { class: 'xp-steps', 'aria-label': 'Progress' })
    const stepEls = new Map(STEPS.map(([id, label]) => {
      const li = h('li', { class: 'xp-step', dataset: { step: id } }, h('span', { class: 'xp-dot', 'aria-hidden': 'true' }, icon('check')), h('span', { class: 'xp-step-label' }, label))
      steps.append(li)
      return [id, li]
    }))
    const queries = h('div', { class: 'xp-queries' })
    stepEls.get('search').append(queries)
    const answer = h('div', { class: 'xp-answer', 'aria-live': 'polite' })
    const sources = h('div', { class: 'xp-sources', role: 'list', 'aria-label': 'Sources' })
    const notice = h('p', { class: 'xp-notice', hidden: true })
    turn.append(steps, answer, notice, sources)
    turns.append(turn)
    follow.replaceChildren()
    if (question) turn.scrollIntoView?.({ block: 'start', behavior: 'smooth' })

    let written = ''
    let found = []
    let searched = 0
    let frame = 0
    const cite = n => {
      const card = sources.querySelector(`.xp-source[data-n="${n}"]`)
      if (!card) return
      card.scrollIntoView?.({ block: 'nearest', inline: 'center', behavior: 'smooth' })
      card.classList.remove('is-flash'); void card.offsetWidth; card.classList.add('is-flash')
    }
    const draw = () => {
      frame = 0
      const blocks = renderAnswer(written, { cite })
      // while it writes, a caret at the end of the last line
      if (busy && blocks.length) {
        const last = blocks.at(-1)
        ;(last.lastElementChild?.tagName === 'LI' ? last.lastElementChild : last).append(h('span', { class: 'xp-caret', 'aria-hidden': 'true' }))
      }
      answer.replaceChildren(...blocks)
    }
    const stage = id => {
      let reached = false
      for (const [k, li] of stepEls) {
        if (k === id) { reached = true; li.dataset.state = 'doing'; li.hidden = false }
        else if (!reached && li.dataset.state === 'doing') li.dataset.state = 'done'
      }
    }

    const controller = new AbortController()
    busy = controller
    setBusy(true)
    const body = { text, context, question: question || '', history: history.slice(-HISTORY) }
    try {
      await streamExplain(body, {
        signal: controller.signal,
        onEvent: ev => {
          if (sheet.closed) return
          switch (ev.type) {
            case 'stage': stage(ev.stage); break
            case 'queries':
              searched = ev.queries?.length || 0
              queries.replaceChildren(...(ev.queries || []).map(q => h('span', { class: 'xp-query' }, icon('search'), q)))
              break
            case 'sources':
              found = Array.isArray(ev.sources) ? ev.sources : []
              sources.replaceChildren(...found.map(s => { const c = sourceCard(s); c.setAttribute('role', 'listitem'); return c }))
              break
            case 'notice':
              notice.hidden = false
              notice.textContent = ev.notice === 'no-search' ? 'Not checked against the web: answered from what the model knows.' : "Couldn't search the web just now, so this wasn't checked."
              stepEls.get('search').hidden = stepEls.get('compare').hidden = true
              break
            case 'delta':
              written += ev.text || ''
              if (!frame) frame = requestAnimationFrame(draw)
              break
            case 'followups':
              follow.replaceChildren(...(ev.questions || []).map(q => {
                const b = h('button', { class: 'xp-chip', type: 'button' }, q)
                b.addEventListener('click', () => ask(q))
                return b
              }))
              break
            case 'error': throw new Error(ev.error || 'Something went wrong')
          }
        }
      })
      if (!written.trim()) throw new Error("Couldn't write the answer")
      history.push({ q: question || `What does “${text}” mean here?`, a: written })
      // done: the steps fold into one line
      steps.replaceChildren(h('li', { class: 'xp-step xp-summary', dataset: { state: 'done' } },
        h('span', { class: 'xp-dot', 'aria-hidden': 'true' }, icon(found.length ? 'globe' : 'sparkles')),
        h('span', { class: 'xp-step-label' }, found.length ? `Searched the web · ${found.length} source${found.length === 1 ? '' : 's'}` : searched ? 'Answered without web sources' : 'Answered')))
      announce('Answer ready')
    } catch (err) {
      if (controller.signal.aborted || sheet.closed) return
      const retry = h('button', { class: 'xp-retry', type: 'button' }, icon('refresh'), 'Try again')
      retry.addEventListener('click', () => { turn.remove(); ask(question) })
      for (const li of stepEls.values()) if (li.dataset.state === 'doing') li.dataset.state = 'failed'
      turn.append(h('div', { class: 'xp-error', role: 'alert' }, h('span', {}, err.message || 'Something went wrong'), retry))
    } finally {
      if (busy === controller) busy = null
      cancelAnimationFrame(frame)
      if (!sheet.closed) { draw(); turn.removeAttribute('aria-busy'); setBusy(false) }
    }
  }

  form.addEventListener('submit', e => {
    e.preventDefault()
    const q = input.value.trim()
    if (!q || busy) return
    input.value = ''
    ask(q)
  })

  ask('')
  return sheet
}
