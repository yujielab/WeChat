import test from 'node:test'
import assert from 'node:assert/strict'
import { createDiscardGuard } from '../public/js/views/draw-guard.js'

const tick = () => new Promise(r => setImmediate(r))

// A browser's history, enough of it: entries, an index, popstate after back().
function fakeHistory(onPop) {
  const h = {
    entries: [{ duo: 2, chat: 'a' }],
    i: 0,
    get state() { return h.entries[h.i] },
    pushState(s) { h.entries = h.entries.slice(0, h.i + 1); h.entries.push(s); h.i++ },
    back() { if (h.i > 0) { h.i--; setImmediate(() => onPop({ state: h.state })) } }
  }
  return h
}

// The shell, as far as leaving the board goes (views/shell.js): the board
// opens with an entry of its own; Back pops it; another conversation opens
// from a notification. Each answer is scripted.
function app({ ink = true, answers = [], ask = null } = {}) {
  const asked = []
  const focused = []
  const ui = { chat: 'a', board: false, ink, skip: 0 }
  const canvas = { focus: () => focused.push('canvas') }
  const anchor = { focus: () => focused.push('close') }
  const guard = createDiscardGuard({
    unsaved: () => (ui.board && ui.ink ? { anchor, canvas } : null),
    ask: ask ? a => { asked.push(a); return ask(a) } : async a => { asked.push(a); return answers.shift() ?? false }
  })
  const history = fakeHistory(e => {
    if (ui.skip) { ui.skip--; return }
    const held = guard.holdPop({
      leaving: ui.board && e.state.duo < 3,
      restore: () => history.pushState({ duo: 3, chat: ui.chat }),
      leave: () => { ui.skip++; history.back(); ui.board = false }
    })
    if (held) return
    ui.board = e.state.duo === 3
    ui.chat = e.state.chat
  })
  const openBoard = () => { ui.board = true; history.pushState({ duo: 3, chat: ui.chat }) }
  const openChat = id => guard.before(() => { ui.board = false; ui.chat = id; history.pushState({ duo: 2, chat: id }) })
  return { ui, history, asked, focused, openBoard, openChat, guard }
}

test('Back with ink asks; 取消 keeps the board, the conversation and the same history', async () => {
  const { ui, history, asked, focused, openBoard } = app({ answers: [false] })
  openBoard()
  const before = JSON.stringify({ entries: history.entries, i: history.i })
  history.back()
  await tick(); await tick()
  assert.equal(asked.length, 1, 'asked once')
  assert.equal(ui.board, true, 'the board stays')
  assert.equal(ui.chat, 'a')
  assert.equal(JSON.stringify({ entries: history.entries, i: history.i }), before, 'the step back was put back')
  assert.deepEqual(focused, ['canvas'], 'focus back on the board')
})

test('Back with ink, 放弃: the board goes and history steps back for real', async () => {
  const { ui, history, asked, openBoard } = app({ answers: [true] })
  openBoard()
  history.back()
  await tick(); await tick(); await tick()
  assert.equal(asked.length, 1)
  assert.equal(ui.board, false)
  assert.equal(history.i, 0, 'back on the conversation\'s entry')
  assert.deepEqual(history.state, { duo: 2, chat: 'a' })
  assert.equal(ui.skip, 0, 'the extra step was the guard\'s own, and was taken')
})

test('an empty board leaves on Back without asking', async () => {
  const { ui, history, asked, openBoard } = app({ ink: false })
  openBoard()
  history.back()
  await tick()
  assert.equal(asked.length, 0)
  assert.equal(ui.board, false)
  assert.equal(history.i, 0)
})

test('Back again while it is asking just holds again: one question, history unchanged', async () => {
  let answer
  const { ui, history, asked, openBoard } = app({ ask: () => new Promise(r => { answer = r }) })
  openBoard()
  const depth = history.entries.length
  history.back(); await tick()
  history.back(); await tick()
  assert.equal(asked.length, 1, 'one question')
  assert.equal(ui.board, true)
  assert.equal(history.entries.length, depth)
  assert.equal(history.i, depth - 1)
  answer(false); await tick()
  assert.equal(ui.board, true)
  assert.equal(history.i, depth - 1)
})

test('another conversation (a notification) while drawing asks; 取消 stays put, 放弃 switches', async () => {
  const kept = app({ answers: [false] })
  kept.openBoard()
  const entries = kept.history.entries.length
  assert.equal(await kept.openChat('b'), false)
  assert.equal(kept.ui.chat, 'a', 'still this conversation')
  assert.equal(kept.ui.board, true, 'drawing kept')
  assert.equal(kept.history.entries.length, entries, 'no navigation')
  assert.deepEqual(kept.focused, ['canvas'])

  const gone = app({ answers: [true] })
  gone.openBoard()
  assert.equal(await gone.openChat('b'), true)
  assert.equal(gone.ui.chat, 'b')
  assert.equal(gone.ui.board, false)
  assert.equal(gone.asked.length, 1)

  const empty = app({ ink: false })
  empty.openBoard()
  assert.equal(await empty.openChat('b'), true)
  assert.equal(empty.asked.length, 0, 'an empty board doesn\'t ask')
})

test('Close with ink keeps focus on Close when kept; a second ask while one is up gets null', async () => {
  let answer
  const focused = []
  const guard = createDiscardGuard({
    unsaved: () => ({ anchor: { focus: () => focused.push('close') }, canvas: { focus: () => focused.push('canvas') } }),
    ask: () => new Promise(r => { answer = r })
  })
  const first = guard.mayDiscard()
  assert.equal(guard.asking, true)
  assert.equal(await guard.mayDiscard(), null)
  answer(false)
  assert.equal(await first, false)
  assert.deepEqual(focused, ['close'])
  assert.equal(guard.asking, false)
})

test('a pop that keeps the board (or with nothing on it) is not held: no question, no entry put back', () => {
  let restored = 0
  const asked = []
  const guard = createDiscardGuard({ unsaved: () => ({ anchor: {}, canvas: {} }), ask: async a => { asked.push(a); return false } })
  assert.equal(guard.holdPop({ leaving: false, restore: () => restored++, leave: () => {} }), false)
  const empty = createDiscardGuard({ unsaved: () => null, ask: async a => { asked.push(a); return false } })
  assert.equal(empty.holdPop({ leaving: true, restore: () => restored++, leave: () => {} }), false)
  assert.equal(restored, 0)
  assert.equal(asked.length, 0)
})

test('the offline shell caches draw-guard.js', async () => {
  const { readFile } = await import('node:fs/promises')
  const sw = await readFile(new URL('../public/sw.js', import.meta.url), 'utf8')
  assert.match(sw, /'\/js\/views\/draw-guard\.js'/)
})

test('放弃 for another conversation: focus goes to what asked for it, when it is still there', async () => {
  const focused = []
  const guard = createDiscardGuard({ unsaved: () => ({ anchor: {}, canvas: { focus: () => focused.push('canvas') } }), ask: async () => true })
  const row = { isConnected: true, focus: () => focused.push('row') }
  let went = 0
  assert.equal(await guard.before(() => went++, { trigger: row }), true)
  assert.equal(went, 1)
  assert.deepEqual(focused, ['row'])
  const gone = { isConnected: false, focus: () => focused.push('gone') }
  await guard.before(() => went++, { trigger: gone })
  assert.deepEqual(focused, ['row'], 'a trigger that went with the board is left alone')
})
