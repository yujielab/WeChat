// Search and explain: a word or a few, picked out of a message in the chat
// (double-tap a bubble and slide), looked up on the web and explained.
//
//   1. the question is planned into a few web searches     (GLM-4.7-Flash)
//   2. Tavily searches the web for each, live              (TAVILY_API_KEY)
//   3. the sources are gathered, deduplicated and numbered
//   4. the facts that bear on the question are drawn out
//      of them, and the sources compared                   (GLM-4.7-Flash)
//   5. the answer is written from those facts, streamed,
//      with [n] marking the source of each claim           (GLM-4.7-Flash)
//   6. source cards and a few questions to ask next
//
// Each step is reported as it happens, so the sheet can show where it is.
// What is sent: the words picked out, the message they came from, and the
// questions asked in the same sheet — nothing else from the conversation.
// Without a Tavily key the answer comes from the model alone, and says so.

import { assistConfigured } from './assist.js'

export const EXPLAIN_MODEL = '@cf/zai-org/glm-4.7-flash'
const TAVILY_URL = 'https://api.tavily.com/search'

export const LIMITS = { text: 300, context: 1200, question: 300, history: 3, answer: 2000 }
const QUERIES = 3 // searches per question
const PER_QUERY = 5 // results asked for per search
const SOURCES = 6 // kept for the answer
const SNIPPET = 700 // characters of each source read
const PER_MINUTE = 8 // questions per person
const SEARCH_TIMEOUT = 9000
const STEP_TIMEOUT = 15000
const ANSWER_TIMEOUT = 45000

const modelOf = env => String(env.AI_EXPLAIN_MODEL || EXPLAIN_MODEL).trim()
export const explainConfigured = env => assistConfigured(env)
export const searchConfigured = env => Boolean(String(env.TAVILY_API_KEY || '').trim())

const recent = new Map()
export function allowExplain(uid, now = Date.now()) {
  const times = (recent.get(uid) || []).filter(t => now - t < 60000)
  if (times.length >= PER_MINUTE) return false
  times.push(now)
  recent.set(uid, times)
  if (recent.size > 1000) recent.delete(recent.keys().next().value)
  return true
}

// ---------------------------------------------------------------- the model

// GLM-4.7-Flash thinks first by default; it's asked not to, and whatever
// thinking still comes back (a reasoning field, or <think> inline) is dropped.
const NO_THINKING = { chat_template_kwargs: { enable_thinking: false } }

export function stripThinking(text) {
  return String(text || '').replace(/<think>[\s\S]*?<\/think>/g, '').replace(/<think>[\s\S]*$/, '').trim()
}

function withTimeout(promise, ms, what) {
  let timer
  const late = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error(`${what} timeout`)), ms) })
  return Promise.race([promise, late]).finally(() => clearTimeout(timer))
}

/** One whole answer (not streamed). */
async function complete(env, messages, maxTokens) {
  const out = await withTimeout(env.AI.run(modelOf(env), { messages, max_tokens: maxTokens, temperature: 0.2, ...NO_THINKING }), STEP_TIMEOUT, 'model')
  const text = typeof out === 'string' ? out : out?.response ?? out?.choices?.[0]?.message?.content ?? out?.result?.response ?? ''
  return stripThinking(text)
}

/** The first JSON object or array in a model's answer. */
export function parseJson(text, fallback) {
  const s = stripThinking(text).replace(/^```(?:json)?\s*|\s*```$/g, '')
  for (const [open, close] of [['{', '}'], ['[', ']']]) {
    const a = s.indexOf(open), b = s.lastIndexOf(close)
    if (a >= 0 && b > a) {
      try { return JSON.parse(s.slice(a, b + 1)) } catch {}
    }
  }
  return fallback
}

/**
 * The text of a streamed answer, piece by piece. Workers AI streams server-
 * sent events: `data: {"response": "…"}` from its own models, OpenAI-style
 * `data: {"choices":[{"delta":{"content":"…"}}]}` from others; reasoning
 * (`reasoning_content`, or <think>…</think> inline) is left out.
 */
export async function* streamText(stream) {
  const reader = stream.getReader()
  const decoder = new TextDecoder()
  let buf = ''
  let thinking = false
  let pending = '' // a possible '<think>' / '</think>' cut across pieces
  const visible = piece => {
    let s = pending + piece
    pending = ''
    let out = ''
    while (s) {
      if (thinking) {
        const end = s.indexOf('</think>')
        if (end < 0) { const keep = partialTag(s, '</think>'); pending = keep; return out }
        thinking = false
        s = s.slice(end + 8)
      } else {
        const start = s.indexOf('<think>')
        if (start < 0) {
          const keep = partialTag(s, '<think>')
          out += s.slice(0, s.length - keep.length)
          pending = keep
          return out
        }
        out += s.slice(0, start)
        thinking = true
        s = s.slice(start + 7)
      }
    }
    return out
  }
  for (;;) {
    const { value, done } = await reader.read()
    if (value) buf += typeof value === 'string' ? value : decoder.decode(value, { stream: true })
    let nl
    while ((nl = buf.indexOf('\n')) >= 0) {
      const line = buf.slice(0, nl).trim()
      buf = buf.slice(nl + 1)
      if (!line.startsWith('data:')) continue
      const data = line.slice(5).trim()
      if (data === '[DONE]') return
      let ev
      try { ev = JSON.parse(data) } catch { continue }
      const piece = ev.response ?? ev.choices?.[0]?.delta?.content ?? ev.choices?.[0]?.text ?? ''
      if (typeof piece === 'string' && piece) {
        const shown = visible(piece)
        if (shown) yield shown
      }
    }
    if (done) {
      if (pending && !thinking) yield pending
      return
    }
  }
}
function partialTag(s, tag) {
  for (let n = Math.min(tag.length - 1, s.length); n > 0; n--) if (tag.startsWith(s.slice(-n))) return s.slice(-n)
  return ''
}

// ---------------------------------------------------------------- the web

/** Live web results for one query (Tavily), or [] when it can't be reached. */
export async function tavily(env, query, fetchImpl = fetch) {
  const key = String(env.TAVILY_API_KEY || '').trim()
  const res = await withTimeout(fetchImpl(TAVILY_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/json', authorization: `Bearer ${key}` },
    body: JSON.stringify({ query, search_depth: 'basic', topic: 'general', max_results: PER_QUERY, include_answer: false, include_raw_content: false, include_images: false })
  }), SEARCH_TIMEOUT, 'search')
  if (!res.ok) throw new Error(`search ${res.status}`)
  const data = await res.json()
  return Array.isArray(data?.results) ? data.results : []
}

const siteOf = url => { try { return new URL(url).hostname.replace(/^www\./, '') } catch { return '' } }
const normal = url => { try { const u = new URL(url); u.hash = ''; return (u.hostname.replace(/^www\./, '') + u.pathname.replace(/\/$/, '') + u.search).toLowerCase() } catch { return String(url) } }

/** Several searches' results as one numbered list: duplicates folded, best first. */
export function gatherSources(lists, max = SOURCES) {
  const byUrl = new Map()
  for (const list of lists) {
    for (const r of list || []) {
      const url = String(r?.url || '')
      if (!/^https?:\/\//i.test(url)) continue
      const key = normal(url)
      const score = Number(r.score) || 0
      const prev = byUrl.get(key)
      if (!prev || score > prev.score) byUrl.set(key, { url, title: String(r.title || siteOf(url)).trim().slice(0, 160), snippet: String(r.content || '').replace(/\s+/g, ' ').trim().slice(0, SNIPPET), score })
    }
  }
  return [...byUrl.values()]
    .sort((a, b) => b.score - a.score)
    .slice(0, max)
    .map((s, i) => ({ id: i + 1, title: s.title, url: s.url, site: siteOf(s.url), snippet: s.snippet }))
}

/** [n] markers in an answer only for sources that exist. */
export function keepCitations(text, count) {
  return String(text).replace(/\[(\d{1,2})\]/g, (m, n) => (Number(n) >= 1 && Number(n) <= count ? m : ''))
}

// ---------------------------------------------------------------- the steps

const clip = (s, n) => String(s || '').replace(/\s+/g, ' ').trim().slice(0, n)

function framing({ text, context, question }) {
  return [
    `Highlighted in a chat message: “${text}”`,
    context && context !== text ? `The whole message: “${context}”` : '',
    question ? `Question: ${question}` : `Question: what does the highlighted text mean here, and what is it?`
  ].filter(Boolean).join('\n')
}

async function plan(env, input) {
  const out = await complete(env, [
    { role: 'system', content: 'You plan web searches that answer a question about words highlighted in a chat message. Reply with JSON only: {"lang": "<the language the highlighted text and question are written in, as a BCP 47 tag>", "queries": ["<up to 3 short, specific search queries>"]}. Queries in the language most likely to find good sources.' },
    { role: 'user', content: framing(input) + (input.history?.length ? `\nAsked before in this sheet: ${input.history.map(h => h.q).join(' / ')}` : '') }
  ], 300)
  const p = parseJson(out, {})
  const queries = (Array.isArray(p.queries) ? p.queries : []).map(q => clip(q, 120)).filter(Boolean).slice(0, QUERIES)
  return { lang: clip(p.lang, 20) || 'en', queries: queries.length ? queries : [clip(input.question || input.text, 120)] }
}

async function extractFacts(env, input, sources) {
  const out = await complete(env, [
    { role: 'system', content: 'From the numbered sources, take the facts that bear on the question, and compare the sources. Reply with JSON only: {"facts": [{"text": "<one fact>", "sources": [<numbers of the sources that state it>]}], "conflicts": [{"text": "<where the sources disagree>", "sources": [<numbers>]}]}. At most 8 facts. Use only what the sources say.' },
    { role: 'user', content: `${framing(input)}\n\nSources:\n${sources.map(s => `[${s.id}] ${s.title} (${s.site}): ${s.snippet}`).join('\n')}` }
  ], 900)
  const p = parseJson(out, {})
  const ok = n => Number.isInteger(n) && n >= 1 && n <= sources.length
  const norm = list => (Array.isArray(list) ? list : []).map(f => ({ text: clip(f?.text, 300), sources: (Array.isArray(f?.sources) ? f.sources : []).map(Number).filter(ok) })).filter(f => f.text)
  return { facts: norm(p.facts).slice(0, 8), conflicts: norm(p.conflicts).slice(0, 4) }
}

function answerMessages(input, lang, sources, facts) {
  const searched = sources.length > 0
  const system = [
    'You explain words highlighted in a chat message, for the person reading the chat.',
    `Write in the language of the highlighted text and question (${lang}).`,
    'Be clear and brief: a direct explanation first, then what matters, in 2–5 short paragraphs or a few bullets. Plain text with light Markdown (**bold**, "- " bullets); no headings.',
    searched
      ? 'Use only the facts and sources given. After each claim, cite its source as [n] (several as [1][3]). Where sources disagree, say so. If they don\'t answer the question, say what is known and that it isn\'t certain.'
      : 'There are no web results: answer from what you know, without citations, and say in one short line at the end that this wasn\'t checked against the web.'
  ].join(' ')
  const parts = [framing(input)]
  if (input.history?.length) parts.push(`Earlier in this sheet:\n${input.history.map(h => `Q: ${h.q}\nA: ${clip(h.a, 600)}`).join('\n')}`)
  if (searched) {
    if (facts.facts.length) parts.push(`Facts:\n${facts.facts.map(f => `- ${f.text} ${f.sources.map(n => `[${n}]`).join('')}`).join('\n')}`)
    if (facts.conflicts.length) parts.push(`Where sources disagree:\n${facts.conflicts.map(f => `- ${f.text} ${f.sources.map(n => `[${n}]`).join('')}`).join('\n')}`)
    parts.push(`Sources:\n${sources.map(s => `[${s.id}] ${s.title} (${s.site}): ${s.snippet}`).join('\n')}`)
  }
  return [{ role: 'system', content: system }, { role: 'user', content: parts.join('\n\n') }]
}

async function followUps(env, input, lang, facts) {
  const out = await complete(env, [
    { role: 'system', content: `Suggest 3 short questions the reader might ask next about the highlighted text, in ${lang}. Reply with a JSON array of strings only, each under 60 characters.` },
    { role: 'user', content: framing(input) + (facts.facts.length ? `\nKnown: ${facts.facts.map(f => f.text).join(' ')}` : '') }
  ], 200)
  const list = parseJson(out, [])
  return (Array.isArray(list) ? list : []).map(q => clip(q, 80)).filter(Boolean).slice(0, 3)
}

/** The request, trimmed to what is read. */
export function readInput(body) {
  const history = (Array.isArray(body?.history) ? body.history : [])
    .slice(-LIMITS.history)
    .map(h => ({ q: clip(h?.q, LIMITS.question), a: clip(h?.a, LIMITS.answer) }))
    .filter(h => h.q)
  return { text: clip(body?.text, LIMITS.text), context: clip(body?.context, LIMITS.context), question: clip(body?.question, LIMITS.question), history }
}

/**
 * The whole answer, as events:
 *   { type: 'stage', stage: 'plan' | 'search' | 'compare' | 'answer' }
 *   { type: 'queries', queries, lang }
 *   { type: 'sources', sources: [{ id, title, url, site, snippet }] }
 *   { type: 'notice', notice: 'no-search' | 'search-failed' }
 *   { type: 'delta', text }   (the answer, piece by piece; [n] cites source n)
 *   { type: 'followups', questions }
 *   { type: 'done' } | { type: 'error', error }
 */
export async function* explainEvents(env, input, { fetchImpl = fetch } = {}) {
  yield { type: 'stage', stage: 'plan' }
  let planned
  try { planned = await plan(env, input) } catch { planned = { lang: 'en', queries: [clip(input.question || input.text, 120)] } }
  yield { type: 'queries', queries: planned.queries, lang: planned.lang }

  let sources = []
  if (searchConfigured(env)) {
    yield { type: 'stage', stage: 'search' }
    const lists = await Promise.all(planned.queries.map(q => tavily(env, q, fetchImpl).catch(err => { console.warn('explain search', err.message); return null })))
    sources = gatherSources(lists.filter(Boolean))
    if (!sources.length) yield { type: 'notice', notice: 'search-failed' }
    yield { type: 'sources', sources }
  } else {
    yield { type: 'notice', notice: 'no-search' }
  }

  let facts = { facts: [], conflicts: [] }
  if (sources.length) {
    yield { type: 'stage', stage: 'compare' }
    try { facts = await extractFacts(env, input, sources) } catch (err) { console.warn('explain facts', err.message) }
  }

  // The next questions are thought of while the answer is written.
  const next = followUps(env, input, planned.lang, facts).catch(() => [])

  yield { type: 'stage', stage: 'answer' }
  let written = ''
  try {
    const stream = await withTimeout(env.AI.run(modelOf(env), { messages: answerMessages(input, planned.lang, sources, facts), max_tokens: 900, temperature: 0.3, stream: true, ...NO_THINKING }), STEP_TIMEOUT, 'answer')
    if (stream && typeof stream.getReader === 'function') {
      const started = Date.now()
      let held = '' // a "[1" cut across pieces is checked once its "]" arrives
      for await (const piece of streamText(stream)) {
        if (Date.now() - started > ANSWER_TIMEOUT) break
        held += piece
        const cut = held.search(/\[\d{0,2}$/)
        const ready = cut >= 0 ? held.slice(0, cut) : held
        held = cut >= 0 ? held.slice(cut) : ''
        const text = keepCitations(ready, sources.length)
        if (text) { written += text; yield { type: 'delta', text } }
      }
      const rest = keepCitations(held, sources.length)
      if (rest) { written += rest; yield { type: 'delta', text: rest } }
    } else {
      // a model that answered in one piece
      const text = keepCitations(stripThinking(stream?.response ?? stream?.choices?.[0]?.message?.content ?? ''), sources.length)
      if (text) { written += text; yield { type: 'delta', text } }
    }
  } catch (err) {
    console.warn('explain answer', err.message)
    yield { type: 'error', error: "Couldn't write the answer" }
    return
  }
  if (!written.trim()) { yield { type: 'error', error: "Couldn't write the answer" }; return }
  yield { type: 'followups', questions: await next }
  yield { type: 'done' }
}

/** The events as a stream of JSON lines, for the response. */
export function explainResponse(env, input, opts) {
  const encoder = new TextEncoder()
  const events = explainEvents(env, input, opts)
  const body = new ReadableStream({
    async pull(controller) {
      try {
        const { value, done } = await events.next()
        if (done) { controller.close(); return }
        controller.enqueue(encoder.encode(JSON.stringify(value) + '\n'))
      } catch (err) {
        console.warn('explain', err.message)
        controller.enqueue(encoder.encode(JSON.stringify({ type: 'error', error: 'Something went wrong' }) + '\n'))
        controller.close()
      }
    },
    cancel() { events.return?.() }
  })
  return new Response(body, { headers: { 'content-type': 'application/x-ndjson; charset=utf-8', 'cache-control': 'no-store', 'x-content-type-options': 'nosniff' } })
}
