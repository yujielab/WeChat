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

export const DEFAULT_MODEL = '@cf/qwen/qwen3-30b-a3b-fp8'
const CONTEXT = 8           // messages read for a suggestion
const CONTEXT_CHARS = 200   // of each
const MAX_SUGGESTION = 24   // characters suggested
const PER_MINUTE = 30       // suggestions per person
const TIMEOUT_MS = 4000

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
 */
export async function suggest(env, { history, draft }) {
  const said = history.filter(m => m.text).slice(-CONTEXT)
  if (!draft && (!said.length || said.at(-1).mine)) return ''
  const lines = said.map(m => `${m.mine ? '我' : '对方'}：${m.text.slice(0, CONTEXT_CHARS)}`).join('\n')
  const task = draft
    ? `我正在输入：「${draft}」\n只输出接在后面的文字（不要重复已输入的部分，不超过15个字），让这句话自然地说完。不要解释，不要加引号。`
    : '替我写一句简短自然的回复（不超过15个字）。只输出这句话，不要解释，不要加引号。'
  const raw = await ask(env, [
    { role: 'system', content: '你是聊天输入法的联想功能：只输出要补上的文字，语气和我平时一样。' },
    { role: 'user', content: `聊天记录：\n${lines || '（无）'}\n\n${task} /no_think` }
  ], 40)
  return cleanSuggestion(raw, draft)
}

export function cleanSuggestion(raw, draft = '') {
  let s = String(raw || '').split('\n').map(l => l.trim()).find(Boolean) || ''
  s = s.replace(/^(我|回复|补全|输出)[:：]\s*/, '').replace(/^["'「『“]+|["'」』”]+$/g, '').trim()
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
    { role: 'system', content: '你从聊天消息里挑出关键信息。' },
    { role: 'user', content: `消息：「${text.slice(0, 600)}」\n挑出最多3个关键词或关键短语（时间、地点、人名、数字、要做的事），必须是消息原文中连续出现的片段，每个不超过12个字。只输出JSON数组，例如["明天下午3点","会议室"]；没有就输出[]。 /no_think` }
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
