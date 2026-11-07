// Picking words out of a message's text (views/explain-pick.js): what a
// double-tap takes, how far a slide reaches, and where a dragged handle
// leaves the selection. The double-tap takes the word under the finger;
// sliding takes whole words where words are spaced, and single characters
// in Chinese and Japanese, so a phrase of either can be picked exactly.
// Plain text offsets only — no DOM here.

const CJK = /[\p{Script=Han}\p{Script=Hiragana}\p{Script=Katakana}]/u
const EDGE = /^[\s\p{P}]+|[\s\p{P}]+$/gu
const WORDISH = /[\p{L}\p{N}\p{M}_'’-]+|\s+|[\s\S]/gu

/** The text cut into words, spaces and marks: [{ start, end, word, cjk }]. */
export function segmentsOf(text, locale) {
  const out = []
  if (typeof Intl !== 'undefined' && Intl.Segmenter) {
    for (const s of new Intl.Segmenter(locale, { granularity: 'word' }).segment(text)) {
      out.push({ start: s.index, end: s.index + s.segment.length, word: Boolean(s.isWordLike), cjk: CJK.test(s.segment) })
    }
    return out
  }
  for (const m of text.matchAll(WORDISH)) {
    const seg = m[0]
    if (CJK.test(seg) && seg.length > 1) {
      // without a segmenter, Chinese and Japanese go a character at a time
      let i = m.index
      for (const ch of seg) { out.push({ start: i, end: i + ch.length, word: true, cjk: true }); i += ch.length }
    } else {
      out.push({ start: m.index, end: m.index + seg.length, word: /[\p{L}\p{N}]/u.test(seg), cjk: CJK.test(seg) })
    }
  }
  return out
}

const segAt = (segs, i) => segs.find(s => i >= s.start && i < s.end) || segs.at(-1)

/** The character (code point) of `text` at `i`, as [start, end). */
function charAt(text, i) {
  let start = i
  const c = text.charCodeAt(i)
  if (c >= 0xdc00 && c <= 0xdfff && i > 0) start = i - 1 // the second half of a pair
  const cp = text.codePointAt(start)
  return { start, end: start + (cp > 0xffff ? 2 : 1) }
}

/** What a double-tap at `i` takes: the word there, or the nearest one when
 *  it lands on a space or a mark. Null when there is no word at all. */
export function wordAt(segs, i) {
  if (!segs.length) return null
  const s = segAt(segs, i)
  if (s.word) return { start: s.start, end: s.end }
  const at = segs.indexOf(s)
  let best = null
  for (const k of [at - 1, at + 1]) {
    const n = segs[k]
    if (!n?.word) continue
    const d = k < at ? i - n.end : n.start - i
    if (!best || d < best.d) best = { start: n.start, end: n.end, d }
  }
  return best && { start: best.start, end: best.end }
}

/** What a slide reaches at `i`: the word there, or one character in Chinese
 *  and Japanese (and of spaces and marks). */
export function unitAt(text, segs, i) {
  if (!segs.length) return null
  const s = segAt(segs, Math.min(i, text.length - 1))
  if (s.word && !s.cjk) return { start: s.start, end: s.end }
  return charAt(text, Math.max(s.start, Math.min(i, s.end - 1)))
}

/**
 * The span picked: the word under the double-tap until the finger moves,
 * then everything from where it started to where it is now, whichever way.
 */
export function pickSpan(text, segs, anchor, focus, moved) {
  if (!moved) return wordAt(segs, anchor)
  const a = unitAt(text, segs, anchor)
  const f = unitAt(text, segs, focus)
  if (!a || !f) return a || f
  return { start: Math.min(a.start, f.start), end: Math.max(a.end, f.end) }
}

/** One end of a span dragged by its handle: the other end (`fixed`, a
 *  boundary) stays put, this one follows the finger a word or a character
 *  at a time, and may cross over to the other side. */
export function dragEdge(text, segs, fixed, focus) {
  const u = unitAt(text, segs, focus)
  if (!u) return null
  if (u.start >= fixed) return { start: fixed, end: u.end }
  if (u.end <= fixed) return { start: u.start, end: fixed }
  return { start: Math.min(u.start, fixed), end: Math.max(u.end, fixed) }
}

/** The words of a span, without the spaces and punctuation at its ends. */
export function pickedText(text, span) {
  if (!span) return ''
  const raw = text.slice(span.start, span.end)
  const tidy = raw.replace(EDGE, '')
  return tidy || raw.trim()
}
