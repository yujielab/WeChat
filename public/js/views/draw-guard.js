// A drawing that hasn't been sent is never thrown away without asking,
// whichever way the board is left: its Close (and Escape, the drawing tool
// again, the details, a swipe back), the browser's or system's Back, the
// conversation's own back, or another conversation opening (a notification,
// the list beside it unfolded). An empty board leaves at once. One question
// at a time: asked again while it's up, the second way just waits.

/**
 * unsaved(): null, or { anchor, canvas } while the board has ink on it.
 * ask(anchor): resolves true for Discard (views/overlay.js confirmAction).
 */
export function createDiscardGuard({ unsaved, ask }) {
  let asking = false

  /**
   * true when there's nothing to lose or the drawing may go; false when kept;
   * null while already asking. Kept: focus goes back to the board (the
   * canvas, or the Close it was asked from).
   */
  async function mayDiscard({ focus = 'anchor' } = {}) {
    const u = unsaved()
    if (!u) return true
    if (asking) return null
    asking = true
    let ok = false
    try { ok = Boolean(await ask(u.anchor)) } finally { asking = false }
    if (!ok) (focus === 'canvas' && u.canvas ? u.canvas : u.anchor)?.focus?.({ preventScroll: true })
    return ok
  }

  /**
   * The browser has already taken a step Back (popstate). With ink on the
   * board, that step is undone at once (restore(): the entry is put back, so
   * history, the address and the conversation stay as they were) and then it
   * asks; Discard takes the step for real (leave()). true when it held the step.
   */
  function holdPop({ leaving, restore, leave }) {
    if (!leaving || !unsaved()) return false
    restore()
    mayDiscard({ focus: 'canvas' }).then(ok => { if (ok) leave() })
    return true
  }

  /**
   * Something else wants the screen (another conversation): go() only once
   * the drawing may go; then focus is on what asked for it, when it's still there.
   */
  async function before(go, { trigger = null } = {}) {
    const ok = await mayDiscard({ focus: 'canvas' })
    if (!ok) return false
    go()
    if (trigger?.isConnected) trigger.focus?.({ preventScroll: true })
    return true
  }

  return { mayDiscard, holdPop, before, get asking() { return asking } }
}
