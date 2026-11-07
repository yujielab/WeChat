// Search and explain (src/explain.js): plan searches, search the web (Tavily),
// gather and compare sources, then stream an answer with [n] citations,
// source cards and follow-up questions. The model and the web are stubbed.
import test from 'node:test'
import assert from 'node:assert/strict'
import { explainEvents, explainResponse, streamText, gatherSources, keepCitations, parseJson, stripThinking, readInput, allowExplain, tavily, EXPLAIN_MODEL, LIMITS } from '../src/explain.js'

const encoder = new TextEncoder()
/** A Workers AI event stream of `pieces`, each as one or more SSE lines. */
function sse(pieces, { shape = 'response', split = false } = {}) {
  const lines = pieces.map(p => `data: ${JSON.stringify(shape === 'openai' ? { choices: [{ delta: typeof p === 'object' ? p : { content: p } }] } : { response: p })}\n\n`)
  lines.push('data: [DONE]\n\n')
  const chunks = split ? lines.join('').match(/[\s\S]{1,7}/g) : lines
  return new ReadableStream({ start(c) { for (const ch of chunks) c.enqueue(encoder.encode(ch)); c.close() } })
}

/** The model: answers each step by what its system prompt asks for. */
function model({ plan, facts, followups, answer, fail = {} } = {}) {
  const calls = []
  const run = async (name, input) => {
    calls.push({ name, input })
    const sys = input.messages[0].content
    const step = input.stream ? 'answer' : /plan web searches/.test(sys) ? 'plan' : /take the facts/.test(sys) ? 'facts' : /Suggest 3/.test(sys) ? 'followups' : '?'
    if (fail[step]) throw new Error(`${step} failed`)
    if (step === 'plan') return { response: plan ?? '{"lang":"en","queries":["Ghibli museum","Ghibli museum tickets"]}' }
    if (step === 'facts') return { response: facts ?? '{"facts":[{"text":"The museum is in Mitaka","sources":[1,2]}],"conflicts":[]}' }
    if (step === 'followups') return { response: followups ?? '["How do I get tickets?","Is it open on Tuesdays?","What is inside?"]' }
    return sse(answer ?? ['The Ghibli Museum ', 'is in Mitaka [1]', '[2].'])
  }
  return { calls, AI: { run } }
}

/** Tavily: results per query; records what was asked. */
function web(byQuery, { status = 200 } = {}) {
  const asked = []
  const fetchImpl = async (url, init) => {
    const body = JSON.parse(init.body)
    asked.push({ url, init, body })
    if (status !== 200) return new Response('no', { status })
    return Response.json({ results: byQuery[body.query] ?? [] })
  }
  return { asked, fetchImpl }
}

const RESULTS = {
  'Ghibli museum': [
    { title: 'Ghibli Museum, Mitaka', url: 'https://www.ghibli-museum.jp/en/', content: 'The Ghibli Museum is in Mitaka, Tokyo.', score: 0.9 },
    { title: 'Ghibli Museum - Wikipedia', url: 'https://en.wikipedia.org/wiki/Ghibli_Museum', content: 'A museum in Mitaka showcasing the work of Studio Ghibli.', score: 0.8 }
  ],
  'Ghibli museum tickets': [
    { title: 'Tickets', url: 'https://ghibli-museum.jp/en/#tickets', content: 'Same page again, a lower score.', score: 0.5 },
    { title: 'Tickets | Lawson', url: 'https://l-tike.com/ghibli', content: 'Buy tickets in advance.', score: 0.7 }
  ]
}
const collect = async gen => { const out = []; for await (const e of gen) out.push(e); return out }
const input = { text: 'Ghibli museum', context: 'Shall we go to the Ghibli museum on Saturday?', question: '', history: [] }

test('the whole flow: plan → search → sources → compare → streamed, cited answer → follow-ups', async () => {
  const m = model()
  const w = web(RESULTS)
  const events = await collect(explainEvents({ AI: m.AI, TAVILY_API_KEY: 'tvly-test' }, input, { fetchImpl: w.fetchImpl }))
  const types = events.map(e => e.type === 'stage' ? `stage:${e.stage}` : e.type)
  assert.deepEqual(types.filter((t, i) => t !== types[i - 1]), ['stage:plan', 'queries', 'stage:search', 'sources', 'stage:compare', 'stage:answer', 'delta', 'followups', 'done'])

  assert.deepEqual(events.find(e => e.type === 'queries').queries, ['Ghibli museum', 'Ghibli museum tickets'])
  // one Tavily call per query, with the key as a bearer token
  assert.equal(w.asked.length, 2)
  assert.equal(w.asked[0].url, 'https://api.tavily.com/search')
  assert.equal(w.asked[0].init.headers.authorization, 'Bearer tvly-test')
  assert.equal(w.asked[0].body.max_results, 5)

  // duplicates folded (www / hash), best score first, numbered from 1
  const { sources } = events.find(e => e.type === 'sources')
  assert.deepEqual(sources.map(s => [s.id, s.site]), [[1, 'ghibli-museum.jp'], [2, 'en.wikipedia.org'], [3, 'l-tike.com']])

  // the answer is built from the facts and the numbered sources
  const answerCall = m.calls.find(c => c.input.stream)
  const said = answerCall.input.messages.map(x => x.content).join('\n')
  assert.match(said, /Facts:\n- The museum is in Mitaka \[1\]\[2\]/)
  assert.match(said, /\[3\] Tickets \| Lawson \(l-tike\.com\)/)
  assert.equal(answerCall.name, EXPLAIN_MODEL)
  assert.deepEqual(answerCall.input.chat_template_kwargs, { enable_thinking: false })

  assert.equal(events.filter(e => e.type === 'delta').map(e => e.text).join(''), 'The Ghibli Museum is in Mitaka [1][2].')
  assert.deepEqual(events.find(e => e.type === 'followups').questions, ['How do I get tickets?', 'Is it open on Tuesdays?', 'What is inside?'])
})

test('citations to sources that do not exist are dropped, even when split across pieces', async () => {
  const m = model({ answer: ['Open daily [', '1', '] but not [', '9]. See [2', '].'] })
  const events = await collect(explainEvents({ AI: m.AI, TAVILY_API_KEY: 'k' }, input, { fetchImpl: web(RESULTS).fetchImpl }))
  assert.equal(events.filter(e => e.type === 'delta').map(e => e.text).join(''), 'Open daily [1] but not . See [2].')
})

test('without a Tavily key: no search, said so, and no citations', async () => {
  const m = model({ answer: ['It is a museum [1].'] })
  const w = web(RESULTS)
  const events = await collect(explainEvents({ AI: m.AI }, input, { fetchImpl: w.fetchImpl }))
  assert.equal(w.asked.length, 0)
  assert.ok(events.some(e => e.type === 'notice' && e.notice === 'no-search'))
  assert.ok(!events.some(e => e.type === 'sources' || (e.type === 'stage' && e.stage === 'search')))
  assert.equal(events.filter(e => e.type === 'delta').map(e => e.text).join(''), 'It is a museum .')
  assert.match(m.calls.find(c => c.input.stream).input.messages[0].content, /no web results/)
  assert.equal(events.at(-1).type, 'done')
})

test('a failing search still answers, and says the search failed', async () => {
  const m = model({ answer: ['From memory.'] })
  const events = await collect(explainEvents({ AI: m.AI, TAVILY_API_KEY: 'k' }, input, { fetchImpl: web(RESULTS, { status: 432 }).fetchImpl }))
  assert.ok(events.some(e => e.type === 'notice' && e.notice === 'search-failed'))
  assert.deepEqual(events.find(e => e.type === 'sources').sources, [])
  assert.ok(!events.some(e => e.type === 'stage' && e.stage === 'compare'), 'nothing to compare')
  assert.equal(events.at(-1).type, 'done')
})

test('a plan that is not JSON falls back to searching the words themselves', async () => {
  const m = model({ plan: 'Sure! I would search for it.' })
  const w = web(RESULTS)
  await collect(explainEvents({ AI: m.AI, TAVILY_API_KEY: 'k' }, input, { fetchImpl: w.fetchImpl }))
  assert.deepEqual(w.asked.map(a => a.body.query), ['Ghibli museum'])
})

test('a broken planning or fact step does not stop the answer', async () => {
  const m = model({ fail: { plan: true, facts: true, followups: true } })
  const events = await collect(explainEvents({ AI: m.AI, TAVILY_API_KEY: 'k' }, input, { fetchImpl: web(RESULTS).fetchImpl }))
  assert.ok(events.some(e => e.type === 'delta'))
  assert.deepEqual(events.find(e => e.type === 'followups').questions, [])
  assert.equal(events.at(-1).type, 'done')
})

test('an answer that fails, or comes back empty, is an error', async () => {
  const failing = await collect(explainEvents({ AI: model({ fail: { answer: true } }).AI }, input))
  assert.equal(failing.at(-1).type, 'error')
  const empty = await collect(explainEvents({ AI: model({ answer: ['<think>hmm</think>', '  '] }).AI }, input))
  assert.equal(empty.at(-1).type, 'error')
})

test('the streamed text: both stream shapes, thinking left out, lines cut anywhere', async () => {
  const read = async s => { let t = ''; for await (const p of streamText(s)) t += p; return t }
  assert.equal(await read(sse(['Hel', 'lo'], { split: true })), 'Hello')
  assert.equal(await read(sse([{ reasoning_content: 'thinking…' }, { content: 'Hi' }, { content: ' there' }], { shape: 'openai' })), 'Hi there')
  assert.equal(await read(sse(['<thi', 'nk>plan it</th', 'ink>Answer', ' <b>ok</b>'])), 'Answer <b>ok</b>')
  assert.equal(await read(sse(['a < b'])), 'a < b', 'a lone < is not taken for a tag')
})

test('sources: only web links, folded, capped, snippets trimmed', () => {
  const long = 'x '.repeat(1000)
  const lists = [[{ url: 'javascript:alert(1)', title: 'bad' }, { url: 'https://a.com/p/', content: long, score: 0.1 }], [{ url: 'https://www.a.com/p', title: 'A', score: 0.6 }], Array.from({ length: 9 }, (_, i) => ({ url: `https://s${i}.org`, score: 0.5 - i / 100 }))]
  const s = gatherSources(lists)
  assert.equal(s.length, 6)
  assert.equal(s[0].url, 'https://www.a.com/p', 'the better-scored copy is kept')
  assert.ok(s.every(x => /^https:/.test(x.url)))
  assert.ok(gatherSources([[{ url: 'https://a.com', content: long }]])[0].snippet.length <= 700)
  assert.equal(keepCitations('a [1] b [4] c [0] d [12]', 3), 'a [1] b  c  d ')
})

test('helpers: JSON in prose, thinking stripped, input trimmed to the limits', () => {
  assert.deepEqual(parseJson('Here: ```json\n{"a":1}\n```', {}), { a: 1 })
  assert.deepEqual(parseJson('["x","y"] ok', null), ['x', 'y'])
  assert.equal(parseJson('nope', 7), 7)
  assert.equal(stripThinking('<think>a</think> b'), 'b')
  const r = readInput({ text: 'y'.repeat(999), context: 'c', history: [1, 2, 3, 4, 5].map(i => ({ q: `q${i}`, a: 'a' })) })
  assert.equal(r.text.length, LIMITS.text)
  assert.deepEqual(r.history.map(h => h.q), ['q3', 'q4', 'q5'])
  assert.equal(readInput({}).text, '')
})

test('a few questions a minute per person', () => {
  const t = 1_000_000
  for (let i = 0; i < 8; i++) assert.equal(allowExplain('u-limit', t + i), true)
  assert.equal(allowExplain('u-limit', t + 9), false)
  assert.equal(allowExplain('u-other', t + 9), true)
  assert.equal(allowExplain('u-limit', t + 61_000), true, 'a minute later')
})

test('Tavily errors and timeouts reject (and are caught by the flow)', async () => {
  await assert.rejects(tavily({ TAVILY_API_KEY: 'k' }, 'q', async () => new Response('', { status: 401 })), /search 401/)
})

test('the response streams the events as JSON lines', async () => {
  const res = explainResponse({ AI: model().AI, TAVILY_API_KEY: 'k' }, input, { fetchImpl: web(RESULTS).fetchImpl })
  assert.match(res.headers.get('content-type'), /application\/x-ndjson/)
  const lines = (await res.text()).trim().split('\n').map(l => JSON.parse(l))
  assert.equal(lines[0].type, 'stage')
  assert.equal(lines.at(-1).type, 'done')
})
