// "↓ N 条新消息" counts what is still to be read: of the new messages, those
// whose top is still below the line where the conversation ends (the top of
// the composer). One that has come above it has been on screen and stays
// counted out, even if scrolled back down past it.

/**
 * ids: the new messages, oldest first. topOf(id): its top on screen, or null
 * when it isn't drawn (still counted: nobody has seen it). line: the foot.
 */
export function stillBelow(ids, topOf, line) {
  return ids.filter(id => {
    const top = topOf(id)
    return top == null || top >= line
  })
}
