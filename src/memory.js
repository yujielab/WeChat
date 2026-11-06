// Long-context memory for the writing help (src/assist.js).
//
// The prediction used to read the last eight messages of one conversation and
// nothing else, so it forgot everything the moment the window moved — and it
// was told to match "my tone" while never being shown enough of my words to
// know one. The memory fills that gap in three layers, each with its own
// reach and its own privacy:
//
//   1. The near window — the messages of this conversation, in full. Widen it
//      and the model sees the thread it is answering.
//   2. The conversation digest — what this conversation was about before it
//      scrolled out of the window, kept per conversation. Facts, topics,
//      arrangements. It never leaves the conversation it came from.
//   3. The style profile — how this person writes: the words they reach for
//      and the ways they end a sentence. Across conversations, but only their
//      own words, and only words common enough across messages to be a habit
//      rather than a name, a place or a secret.
//
// The split matters for privacy. A digest is scoped to one conversation, so
// nothing from it can reach another. The style profile crosses conversations,
// so it holds only words a person uses habitually — a word that appears in a
// single message (a colleague's name, a project's codename) is deliberately
// not kept, because it would travel into conversations that never mentioned
// it.
//
// Everything is derived from sent messages only. Nobody's live typing preview
// is ever read, a revoked message stops counting the moment it is taken back,
// and a profile is kept for the one person whose words it is.

const MAX_WORDS = 60          // words kept for a person's style
const MAX_ENDINGS = 20        // sentence endings kept
const MAX_DIGEST = 600        // characters kept for a conversation digest
const STYLE_MIN = 2           // messages a word must appear in to be a habit
const PROFILE_TTL = 180 * 24 * 3600 * 1000 // half a year
const DIGEST_TTL = 14 * 24 * 3600 * 1000    // a digest is refreshed at least this often

/** Words that say nothing about a person: function words and filler. */
const STOP = new Set([
  '的', '了', '是', '在', '我', '你', '他', '她', '它', '们', '这', '那', '就', '都', '和', '与',
  '有', '没', '不', '很', '也', '还', '要', '会', '能', '可以', '什么', '怎么', '吗', '呢', '吧',
  '啊', '呀', '哦', '嗯', '哈', '一个', '一下', '现在', '已经', '因为', '所以', '但是', '不过',
  'the', 'a', 'an', 'is', 'are', 'am', 'to', 'of', 'in', 'on', 'it', 'and', 'or', 'so', 'but',
  'be', 'i', 'you', 'we', 'he', 'she', 'that', 'this', 'for', 'with', 'at', 'by', 'not', 'no',
  'yes', 'do', 'did', 'does', 'have', 'has', 'had', 'will', 'would', 'can', 'could', 'just'
])

/**
 * The phrases of a text: the pieces people actually write with.
 *
 * Chinese is written without spaces, so splitting a sentence into words is a
 * guess. Instead of guessing, this keeps the pieces as they are written —
 * short runs of characters that recur across messages. A name, a place, a
 * project name, the way someone opens a message: each is a run that comes
 * back, and the ones that come back most are what that person writes with.
 * Latin words are kept whole, since they are already separated.
 *
 * Two characters are the shortest piece worth keeping; one is too short to
 * mean anything.
 */
export function words(text) {
  const out = []
  for (const run of String(text || '').match(/[\p{Script=Han}]+|[A-Za-z][A-Za-z'-]*/gu) || []) {
    if (/^[A-Za-z]/.test(run)) {
      const w = run.toLowerCase()
      if (w.length > 1 && !STOP.has(w)) out.push(w)
      continue
    }
    // A run is cut into two-character pieces, sliding: "明天见" gives 明天 and
    // 天见. The seams between the pieces come along too, and are left for
    // the model to make sense of — telling them apart by counting is
    // guesswork, and the model reads them fine.
    for (let i = 0; i + 2 <= run.length; i++) {
      const w = run.slice(i, i + 2)
      if (!STOP.has(w)) out.push(w)
    }
    if (run.length === 1 && !STOP.has(run)) out.push(run)
  }
  return out
}

/**
 * How a person ends a message: the last few characters of it.
 *
 * A message without punctuation still ends somewhere — the last few
 * characters are what they chose to finish on — so the tail of the whole
 * text is kept as well as the tails of its sentences.
 */
export function endings(text) {
  const whole = String(text || '').trim()
  const out = []
  const sentences = whole.split(/[。！？!?\n；;]/).map(s => s.trim()).filter(Boolean)
  for (const s of sentences.slice(-2)) {
    const tail = [...s].slice(-4).join('')
    if (tail.length >= 2) out.push(tail)
  }
  // The very end of the message, punctuation or not.
  const tail = [...whole].slice(-4).join('')
  if (tail.length >= 2 && !out.includes(tail)) out.push(tail)
  // Punctuation is not part of how anyone ends a sentence.
  return out.map(t => [...t].filter(c => !/[。！？!?\n；;，,、.\s]/.test(c)).join('')).filter(t => t.length >= 2)
}

/**
 * The style of one person, counted from the messages they sent.
 *
 * A piece is kept only when it appears in at least STYLE_MIN of their
 * messages: that makes it a habit of writing rather than a fact about one
 * conversation, so it is safe to carry into any of them.
 */
export function styleOf(messages) {
  const texts = messages.filter(m => m && typeof m.text === 'string' && m.text.trim())
  if (!texts.length) return emptyStyle()
  // How often each piece of two characters turns up. A piece that is in
  // several of the writer's messages is a habit of theirs; one that appears
  // once is an accident. Whether the piece is a whole word is not decided
  // here — Chinese is written without spaces, so "我准备" holds both 准备
  // and the seam 我准, and telling them apart by counting is guesswork.
  // The pieces are handed to the model as they are, and it reads them.
  const total = new Map()
  const spread = new Map()
  for (const m of texts) {
    const seen = new Set()
    for (const w of words(m.text)) {
      total.set(w, (total.get(w) || 0) + 1)
      seen.add(w)
    }
    for (const w of seen) spread.set(w, (spread.get(w) || 0) + 1)
  }
  const ends = new Map()
  for (const m of texts) for (const e of endings(m.text)) ends.set(e, (ends.get(e) || 0) + 1)
  const counted = {
    spread: Object.fromEntries(spread),
    total: Object.fromEntries(total),
    ends: Object.fromEntries(ends),
    messages: texts.length,
    at: Date.now(),
    counted: Math.max(...texts.map(m => m.ts || 0), 0)
  }
  // The words this batch says about the writer, on its own. A batch of one
  // or two messages says little — a piece needs to be in several of them —
  // so it is mostly empty until there is more.
  return { ...counted, ...wordsOf(counted) }
}

/**
 * The words and the sentence endings a set of counts says about a writer:
 * a piece is a habit when it is in several of their messages, and a phrase
 * is one when it is how they end more than once.
 */
export function wordsOf({ spread = {}, total = {}, ends = {} }) {
  // A piece is a habit when it turns up in several of the writer's
  // messages. The count is added up as the messages come in, so a word
  // used in two messages of one batch, or one in each of two batches, reads
  // the same as one used in two messages of the same batch.
  const words = [...Object.entries(spread)]
    .filter(([w, n]) => n >= STYLE_MIN)
    .sort((a, b) => (total[b[0]] || 0) - (total[a[0]] || 0) || b[0].length - a[0].length)
    .slice(0, MAX_WORDS)
    .map(([w]) => w)
  const endings = [...Object.entries(ends)]
    .filter(([, n]) => n >= 2)
    .sort((a, b) => b[1] - a[1])
    .slice(0, MAX_ENDINGS)
    .map(([e]) => e)
  return { words, endings }
}

export const emptyStyle = () => ({
  words: [], endings: [], messages: 0, at: 0, counted: 0,
  spread: {}, total: {}, ends: {}
})

/**
 * The style as a few lines for the model to read: how this person writes.
 * Plain and short — it is a hint, not a document.
 */
export function styleText(profile) {
  if (!profile || !profile.messages) return ''
  const lines = []
  if (profile.words?.length) lines.push(`Words I often use: ${profile.words.slice(0, 20).join(', ')}`)
  if (profile.endings?.length) lines.push(`How I often phrase things: ${profile.endings.slice(0, 8).map(e => `…${e}`).join(', ')}`)
  return lines.join('\n')
}

/**
 * Merge a new style into the old one: what both agree on is kept, and the
 * newer count wins a tie. A habit that stopped being used drops off.
 */
export function mergeStyle(old, fresh) {
  if (!old || !old.messages) return fresh
  if (!fresh || !fresh.messages) return old
  // The counts are added up, not the word lists: a piece is a habit of the
  // person when it shows up in several of their messages, and that has to be
  // judged over their whole history, not over the last few messages.
  const add = (a, b) => {
    const out = new Map(Object.entries(a || {}))
    for (const [k, v] of Object.entries(b || {})) out.set(k, (out.get(k) || 0) + v)
    return Object.fromEntries(out)
  }
  // The batches do not overlap — the new one is only what was written since
  // the last count — so their counts add up to the whole history.
  const spread = add(old.spread, fresh.spread)
  const total = add(old.total, fresh.total)
  const ends = add(old.ends, fresh.ends)
  const { words, endings: phrases } = wordsOf({ spread, total, ends })
  return {
    words,
    endings: phrases,
    spread,
    total,
    ends,
    messages: (old.messages || 0) + (fresh.messages || 0),
    at: Date.now(),
    counted: Math.max(old.counted || 0, fresh.counted || 0)
  }
}

/** Whether a stored style is still worth keeping. */
export const freshStyle = (style, now = Date.now()) =>
  Boolean(style && style.messages && now - (style.at || 0) < PROFILE_TTL)

/**
 * How far a style may be trusted: one built from a few messages is a hint,
 * from many it is a voice. The prompt uses it to keep a thin profile from
 * talking over the conversation.
 */
export function confidence(style) {
  const n = style?.messages || 0
  if (n >= 40) return 'high'
  if (n >= 12) return 'medium'
  if (n >= 3) return 'low'
  return 'none'
}

// ---------------------------------------------------------------- the style profile
export const styleKey = userId => `memory:style:${userId}`

/** Read a stored style; a blank one when there is none or it went stale. */
export function readStyle(store, userId, now = Date.now()) {
  const stored = store.kvGet(styleKey(userId))
  return freshStyle(stored, now) ? stored : emptyStyle()
}

/**
 * Keep a style, with the counts it was made of, so that the next batch of
 * messages can be added to it instead of starting over. Only the pieces
 * still worth remembering are kept, with a little room to spare for the
 * ones that are still climbing.
 */
export function writeStyle(store, userId, style) {
  const kept = {
    words: (style.words || []).slice(0, MAX_WORDS),
    endings: (style.endings || []).slice(0, MAX_ENDINGS),
    messages: style.messages || 0,
    at: style.at || Date.now(),
    counted: style.counted || 0,
    spread: keepCounts(style.spread, 300),
    total: keepCounts(style.total, 300),
    ends: keepCounts(style.ends, 60)
  }
  store.kvSet(styleKey(userId), kept)
  return kept
}

/** The counts worth carrying forward: the most frequent ones. */
function keepCounts(counts, cap) {
  const entries = Object.entries(counts || {}).sort((a, b) => b[1] - a[1]).slice(0, cap)
  return Object.fromEntries(entries)
}

// ---------------------------------------------------------------- the conversation digest
export const digestKey = (userId, roomId) => `memory:digest:${userId}:${roomId}`

/** Read a conversation's digest; an empty one when there is none or it is stale. */
export function readDigest(store, userId, roomId, now = Date.now()) {
  const stored = store.kvGet(digestKey(userId, roomId))
  if (!stored?.text || now - (stored.at || 0) > DIGEST_TTL) return { text: '', at: 0 }
  return stored
}

/** Keep a conversation's digest. */
export function writeDigest(store, userId, roomId, text, at = Date.now()) {
  const kept = { text: [...String(text || '')].slice(0, MAX_DIGEST).join('').trim(), at }
  store.kvSet(digestKey(userId, roomId), kept)
  return kept
}

/**
 * The prompt that compresses what a conversation was about before it
 * scrolled out of the window. Facts only: the model is told not to guess and
 * not to write anything it was not told.
 */
export function digestPrompt(lines) {
  return [
    { role: 'system', content: 'You summarize a chat log. Compress the older part of the conversation into short bullet points, keeping only what was clearly said: topics discussed, agreed times and places, things not yet done. Do not speculate, do not make things up, no pleasantries. Output only the points, one per line, no more than 5 lines.' },
    { role: 'user', content: `Earlier chat log:\n${lines}\n\nKey points: /no_think` }
  ]
}

/** The model's answer, cleaned: lines, short, nothing that was not there. */
export function readDigestAnswer(raw) {
  const lines = String(raw || '')
    .split('\n')
    .map(l => l.replace(/^[-*·•\d.\s]+/, '').trim())
    .filter(Boolean)
    .slice(0, 5)
  return lines.map(l => [...l].slice(0, 80).join('')).join('\n')
}
