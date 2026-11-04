// What the writing help remembers, and the way to forget it.
//
// The prediction keeps two things: how this person writes (the words they
// reach for, across conversations) and what each conversation was about
// before it scrolled out of view. Both are built from messages already
// sent, and both belong to the one they were made of.
//
// This is where that is shown, so it is never a surprise: what is
// remembered, when it was last read, and a way to clear it all.

import { h, icon } from '../ui/dom.js'
import { api } from '../api.js'
import { emit } from '../store.js'
import { openSheet, confirmAction, toast } from './overlay.js'
import { emptyMemory, summarize, confidenceLabel, when } from './memory-model.js'

export { emptyMemory, summarize, confidenceLabel, when }

/**
 * The memory of this account, as the server holds it. Empty when there is
 * nothing yet — which is not an error.
 */
export async function loadMemory() {
  try {
    const r = await api.get('/api/ai/memory')
    return r?.ok ? r : emptyMemory()
  } catch {
    return emptyMemory()
  }
}

/** Forget everything: the style, and every conversation's digest. */
export async function forgetMemory() {
  try {
    await api.del('/api/ai/memory')
    // What was suggested was made of the memory that is now gone, so the
    // suggestions made of it are dropped.
    emit('memory')
    return true
  } catch (err) {
    toast(err.message || '无法清除', { type: 'error' })
    return false
  }
}

/**
 * The sheet that shows what is remembered, with a way to clear it.
 * Opened from the settings.
 */
export async function openMemorySheet(anchor) {
  const content = h('div', { class: 'memory-sheet' })
  const sheet = openSheet({ title: '记忆', content, tall: true, origin: anchor })

  content.append(h('div', { class: 'memory-loading' }, '正在读取…'))
  const memory = await loadMemory()
  // The sheet may have been closed while the memory was being read; nothing
  // is put into a sheet that is no longer there.
  if (!sheet.el.isConnected) return sheet
  content.replaceChildren()

  const { words, endings, digests, messages, confidence } = summarize(memory)

  if (!messages && !digests.length) {
    content.append(
      h('div', { class: 'memory-empty' },
        h('div', { class: 'empty-art', 'aria-hidden': 'true' }, icon('bubble')),
        h('h2', {}, '还没有记住什么'),
        h('p', {}, '你写的消息多了以后，输入联想会记住你的用词和习惯。'))
    )
    return sheet
  }

  if (messages) {
    content.append(
      h('div', { class: 'memory-head' },
        h('span', {}, '你的用词'),
        h('span', { class: 'memory-note' }, `${confidenceLabel(confidence)} · 来自 ${messages} 条消息`)),
      words.length
        ? h('div', { class: 'memory-tags' }, words.map(w => h('span', { class: 'memory-tag' }, w)))
        : h('p', { class: 'group-foot' }, '还没有反复用到的词。'),
      endings.length
        ? h('div', { class: 'memory-head' }, h('span', {}, '你常把话说成'))
        : null,
      endings.length
        ? h('div', { class: 'memory-tags' }, endings.map(e => h('span', { class: 'memory-tag ending' }, `…${e}`)))
        : null
    )
  }

  if (digests.length) {
    content.append(
      h('div', { class: 'memory-head' }, h('span', {}, '各个聊天的早前内容')),
      ...digests.map(d => h('div', { class: 'memory-digest' },
        h('div', { class: 'memory-digest-text' }, d.text),
        h('div', { class: 'memory-note' }, when(d.at))))
    )
  }

  const clear = h('button', { class: 'btn btn-outline', type: 'button' }, '清除全部记忆')
  clear.addEventListener('click', async () => {
    if (!await confirmAction(clear, { title: '清除全部记忆？', confirm: '清除' })) return
    if (!await forgetMemory()) return
    toast('已清除', { type: 'ok' })
    sheet.close?.()
  })
  content.append(h('div', { class: 'memory-clear' }, clear))
  return sheet
}
