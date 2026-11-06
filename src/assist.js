// Writing help from Workers AI (the AI binding): what you are likely to type
// next — the rest of the sentence you're writing, or a reply when the field
// is empty — and the key words of each text message, highlighted wherever it
// is shown.
//
// Kept apart from the live typing preview: only messages already sent are
// ever read. What someone is typing (relayed to the others, never stored)
// never reaches the model, and a suggestion lives only on the device it was
// made for — it becomes part of the draft, and so of what the others see
// being typed, only once its writer takes it.
//
// What the model reads is three layers (src/memory.js): the messages of this
// conversation, a digest of what this conversation was about before it
// scrolled out of that window, and how this person writes — the words they
// reach for. The last one is why a suggestion sounds like the writer rather
// than like a stranger.

export const DEFAULT_MODEL = '@cf/qwen/qwen3-30b-a3b-fp8'
export const WHISPER_MODEL = '@cf/openai/whisper'  // voice-to-text; AI_TRANSCRIBE_MODEL picks another
export const CONTEXT = 24   // messages read for a suggestion
const CONTEXT_CHARS = 200   // of each
const MAX_SUGGESTION = 24   // characters suggested
const PER_MINUTE = 30       // suggestions per person
const TIMEOUT_MS = 4000
const TRANSCRIBE_TIMEOUT_MS = 25000

export function assistConfigured(env) {
  return typeof env?.AI?.run === 'function'
}

const modelOf = env => String(env.AI_MODEL || DEFAULT_MODEL).trim()

/** One answer from the text model, its thinking left out. */
export async function ask(env, messages, maxTokens, { timeout = TIMEOUT_MS } = {}) {
  let timer
  const late = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('ai timeout')), timeout) })
  try {
    const out = await Promise.race([env.AI.run(modelOf(env), { messages, max_tokens: maxTokens, temperature: 0.3 }), late])
    const text = typeof out === 'string' ? out : out?.response ?? out?.choices?.[0]?.message?.content ?? out?.result?.response ?? ''
    // Some models think aloud first; only the answer counts.
    return String(text).replace(/<think>[\s\S]*?<\/think>/g, '').replace(/<think>[\s\S]*$/, '').trim()
  } finally {
    clearTimeout(timer)
  }
}

/**
 * Voice-to-text (the AI binding's Whisper model): spoken audio, as bytes, to
 * the words in it. Used only for dictation into the composer — the clip is
 * transcribed and dropped, never stored. Returns '' when there is nothing to
 * hear or the model can't make it out.
 */
export async function transcribe(env, bytes, { timeout = TRANSCRIBE_TIMEOUT_MS } = {}) {
  const model = String(env.AI_TRANSCRIBE_MODEL || WHISPER_MODEL).trim()
  let timer
  const late = new Promise((_, reject) => { timer = setTimeout(() => reject(new Error('transcribe timeout')), timeout) })
  try {
    const out = await Promise.race([env.AI.run(model, { audio: Array.from(bytes) }), late])
    const text = typeof out === 'string' ? out : out?.text ?? out?.transcription ?? out?.result?.text ?? ''
    return String(text).replace(/\s+/g, ' ').trim()
  } finally {
    clearTimeout(timer)
  }
}

const recent = new Map()

/** At most PER_MINUTE suggestions a minute for each person. */
export function allowSuggestion(uid, now = Date.now()) {
  const times = (recent.get(uid) || []).filter(t => now - t < 60000)
  if (times.length >= PER_MINUTE) return false
  times.push(now)
  recent.set(uid, times)
  if (recent.size > 1000) recent.delete(recent.keys().next().value)
  return true
}

/**
 * What the writer is likely to type next. history: the room's latest sent
 * messages, oldest first, as { mine, text }; draft: what is in the field.
 * With a draft, the rest of it; without, a short reply to the last message
 * when it came from someone else. '' when there is nothing good to offer.
 *
 * digest: what this conversation was about before it scrolled out of the
 * window. style: how this person writes, kept across conversations.
 */
export async function suggest(env, { history, draft, digest = '', style = '', routine = '' }) {
  const said = history.filter(m => m.text).slice(-CONTEXT)
  if (!draft && (!said.length || said.at(-1).mine)) return ''
  const lines = said.map(m => `${m.mine ? 'Me' : 'Them'}: ${m.text.slice(0, CONTEXT_CHARS)}`).join('\n')
  const task = draft
    ? `I'm typing: "${draft}"\nOutput only the text that comes next (do not repeat what I've already typed, no more than 15 characters) so the sentence finishes naturally. No explanation, no quotes.`
    : 'Write a short, natural reply for me (no more than 15 characters). Output only the reply, no explanation, no quotes.'
  const raw = await ask(env, [
    { role: 'system', content: 'You are a chat typing-suggestion feature: output only the text to add, in my usual tone.' },
    { role: 'user', content: contextText(lines, digest, style, routine) + `\n\n${task} /no_think` }
  ], 40)
  return cleanSuggestion(raw, draft)
}

/**
 * The layers, in the order the model should weigh them: this
 * conversation's own words first, then what this conversation was about
 * before, then how this person writes, then their day and habits (what time
 * it is for them, how they usually answer). The last two are the weakest —
 * they colour the wording and the timing, never the content.
 */
export function contextText(lines, digest = '', style = '', routine = '') {
  const parts = [`Conversation:\n${lines || '(none)'}`]
  if (digest) parts.push(`Earlier in this chat:\n${digest}`)
  if (style) parts.push(`How I usually write and my tone:\n${style}`)
  if (routine) parts.push(`My routine and habits:\n${routine}`)
  return parts.join('\n\n')
}

export function cleanSuggestion(raw, draft = '') {
  let s = String(raw || '').split('\n').map(l => l.trim()).find(Boolean) || ''
  s = s.replace(/^(me|reply|completion|output|我|回复|补全|输出)\s*[:：]?\s*/i, '').replace(/^["'「『“]+|["'」』”]+$/g, '').trim()
  // A model that repeats the draft: keep what comes after it.
  if (draft && s.startsWith(draft)) s = s.slice(draft.length)
  if (!s || s === draft) return ''
  // Two words in a Latin script keep their space.
  if (/[A-Za-z0-9]$/.test(draft) && /^[A-Za-z0-9]/.test(s)) s = ` ${s}`
  return [...s].slice(0, MAX_SUGGESTION).join('')
}

/** The key words of a text message (up to three), each exactly as it appears in it. */
export async function keywords(env, text) {
  if ([...String(text || '').trim()].length < 6) return []
  const raw = await ask(env, [
    { role: 'system', content: 'You pick out the key information from a chat message.' },
    { role: 'user', content: `Message: "${text.slice(0, 600)}"\nPick up to 3 keywords or key phrases (times, places, names, numbers, things to do). Each must be a contiguous fragment that appears verbatim in the message, no more than 12 characters each. Output only a JSON array, e.g. ["3pm tomorrow","meeting room"]; output [] if there are none. /no_think` }
  ], 80)
  let list = []
  try { list = JSON.parse(raw.match(/\[[\s\S]*\]/)?.[0] ?? '[]') } catch {}
  return keysIn(text, Array.isArray(list) ? list : [])
}

/** Keys that really are in the text: 2–12 characters, not the whole of it, not overlapping. */
export function keysIn(text, list) {
  const keys = []
  for (const k of list) {
    if (typeof k !== 'string') continue
    const key = k.trim()
    const n = [...key].length
    if (n < 2 || n > 12 || key === text.trim() || !text.includes(key)) continue
    if (keys.some(o => o.includes(key) || key.includes(o))) continue
    keys.push(key)
    if (keys.length === 3) break
  }
  return keys
}
