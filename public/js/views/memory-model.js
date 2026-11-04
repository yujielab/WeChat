// What the writing help remembers, and the way to forget it — the parts of
// it that are only about the memory, kept apart from the sheet that shows it
// so they can be read and tested on their own.
//
// The prediction keeps two things: how this person writes (the words they
// reach for, across conversations) and what each conversation was about
// before it scrolled out of view. Both are built from messages already
// sent, and both belong to the one they were made of.
//
// This is where that is shown, so it is never a surprise: what is
// remembered, when it was last read, and a way to clear it all.

/** How many words and endings are shown. */
export const SHOWN = 24

/** What the memory is worth, said in words rather than a number. */
const CONFIDENCE = {
  none: '还太少',
  low: '刚开始记住',
  medium: '已经记得一些',
  high: '已经熟悉'
}

/** How much of it there is, in words. */
export const confidenceLabel = level => CONFIDENCE[level] || CONFIDENCE.none

/** A date as it reads: how long ago, or the day it was. */
export function when(ts, now = Date.now()) {
  if (!ts) return ''
  const diff = now - ts
  const day = 24 * 3600 * 1000
  if (diff < 60 * 1000) return '刚刚'
  if (diff < 3600 * 1000) return `${Math.floor(diff / 60000)} 分钟前`
  if (diff < day) return `${Math.floor(diff / 3600000)} 小时前`
  if (diff < 30 * day) return `${Math.floor(diff / day)} 天前`
  return new Date(ts).toLocaleDateString('zh-CN')
}

/** Nothing remembered — which is not an error, just nothing yet. */
export const emptyMemory = () => ({
  style: { words: [], endings: [], messages: 0, at: 0 },
  confidence: 'none',
  digests: []
})

/**
 * The memory as the sheet shows it: what is kept, and how much of it there
 * is. A server that says nothing, or says something odd, is read as an
 * empty memory rather than as an error.
 */
export function summarize(memory) {
  const style = memory?.style || {}
  const words = Array.isArray(style.words) ? style.words.filter(w => typeof w === 'string') : []
  const endings = Array.isArray(style.endings) ? style.endings.filter(e => typeof e === 'string') : []
  const digests = Array.isArray(memory?.digests)
    ? memory.digests.filter(d => d && typeof d.text === 'string' && d.text).map(d => ({ room: String(d.room || ''), text: d.text, at: d.at || 0 }))
    : []
  const messages = Number(style.messages) || 0
  return {
    words: words.slice(0, SHOWN),
    endings: endings.slice(0, SHOWN),
    digests,
    messages,
    confidence: memory?.confidence || 'none',
    empty: !messages && !digests.length
  }
}
