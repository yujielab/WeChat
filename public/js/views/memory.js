// What the writing help remembers, and the way to forget it.
//
// The prediction keeps three things: how this person writes (the words they
// reach for, across conversations), what each conversation was about before
// it scrolled out of view, and their routine and habits — when they are
// usually up, their busiest hours, how they answer, what they send. All are
// built from their own use, and all belong to the one they were made of.
//
// This is where that is shown, so it is never a surprise: what is
// remembered, when it was last read, and a way to clear it all.

import { h, icon } from '../ui/dom.js'
import { api } from '../api.js'
import { emit } from '../store.js'
import { openSheet, confirmAction, toast } from './overlay.js'
import {
  emptyMemory, summarize, confidenceLabel, when, routineConfidenceLabel, sleepText, hoursText, inHours,
  replyText, lengthText, kindsText, peersText
} from './memory-model.js'

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

/** Forget everything: the style, every conversation's digest, and the routine (learning stays as it was set). */
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

/** Learning the routine and habits, on or off: the routine as it now stands, or null when that didn't go through. */
export async function setRoutineLearning(on) {
  try {
    const r = await api.post('/api/ai/memory/routine', { learn: on })
    emit('memory')
    return r?.routine || null
  } catch (err) {
    toast(err.message || '无法更改', { type: 'error' })
    return null
  }
}

/** The day's shape: how busy each hour is, the quiet hours shaded, this hour marked. */
function hoursChart(routine, now = new Date()) {
  const hour = now.getHours()
  const bars = routine.hours.map((v, hr) => h('span', {
    class: ['routine-bar', routine.quiet && inHours(hr, routine.quiet) && 'quiet', hr === hour && 'now'],
    style: { '--v': String(v) }
  }))
  const label = ['一天中各个小时的活跃程度', routine.peak ? `最常在 ${hoursText(routine.peak)}` : '', routine.quiet ? `${hoursText(routine.quiet)} 很少上线` : '']
    .filter(Boolean).join('，')
  return h('div', { class: 'routine-chart', role: 'img', 'aria-label': label },
    h('div', { class: 'routine-bars' }, bars),
    h('div', { class: 'routine-axis', 'aria-hidden': 'true' }, ['0', '6', '12', '18', '24'].map(t => h('span', {}, t))))
}

/** One line of a habit: what it is, and how it goes. */
const habit = (label, value) => h('div', { class: 'memory-row' }, h('span', { class: 'memory-row-label' }, label), h('span', { class: 'memory-row-value' }, value))

function routineSection(routine) {
  if (!routine.learning) {
    return [h('div', { class: 'memory-head' }, h('span', {}, '作息和习惯')), h('p', { class: 'group-foot' }, '学习已关闭：不再记录，也没有保留之前学到的。')]
  }
  const out = [h('div', { class: 'memory-head' },
    h('span', {}, '作息'),
    h('span', { class: 'memory-note' }, `${routineConfidenceLabel(routine.confidence)}${routine.days ? ` · ${routine.days} 天` : ''}`))]
  if (!routine.days) {
    out.push(h('p', { class: 'group-foot' }, '还没有记录。用几天以后，这里会显示你通常几点起、几点睡，什么时候最常聊天。'))
    return out
  }
  const sleep = sleepText(routine)
  if (sleep) out.push(h('p', { class: 'routine-line' }, sleep))
  out.push(hoursChart(routine))
  const notes = [routine.peak ? `最常在 ${hoursText(routine.peak)}` : '', routine.quiet ? `${hoursText(routine.quiet)} 很少上线` : ''].filter(Boolean)
  if (notes.length) out.push(h('p', { class: 'memory-note routine-note' }, notes.join(' · ')))
  if (routine.days < 2) out.push(h('p', { class: 'memory-note routine-note' }, '再用几天会更准。'))

  const habits = [
    routine.reply !== null ? habit('回复', replyText(routine.reply)) : null,
    routine.length !== null ? habit('消息', lengthText(routine.length)) : null,
    routine.kinds.length ? habit('常发', kindsText(routine.kinds)) : null,
    routine.emoji.length ? habit('常用表情', h('span', { class: 'memory-emoji' }, routine.emoji.join(' '))) : null,
    routine.peers.length ? habit('时段', peersText(routine.peers)) : null
  ].filter(Boolean)
  out.push(h('div', { class: 'memory-head' }, h('span', {}, '习惯')))
  out.push(habits.length ? h('div', { class: 'memory-rows' }, habits) : h('p', { class: 'group-foot' }, '还看不出来，多聊几次再看。'))
  return out
}

/** The switch for learning the routine and habits, with what it reads. */
function learningSwitch(routine, onChange) {
  const sw = h('button', { class: 'switch', type: 'button', role: 'switch', 'aria-checked': String(routine.learning), 'aria-label': '学习作息和习惯' })
  sw.addEventListener('click', async () => {
    const next = sw.getAttribute('aria-checked') !== 'true'
    if (!next && !await confirmAction(sw, { title: '关闭并忘掉学到的作息和习惯？', confirm: '关闭' })) return
    sw.setAttribute('aria-checked', String(next))
    const updated = await setRoutineLearning(next)
    if (!updated) sw.setAttribute('aria-checked', String(!next))
    else onChange(updated)
  })
  return [
    h('div', { class: 'memory-switch' }, h('span', {}, '学习作息和习惯'), sw),
    h('p', { class: 'memory-note memory-switch-foot' }, '只来自你自己的使用：发消息、打开 Cuven、看消息的时间，发了什么类型、多长、用了哪些表情——不记内容。关闭后会忘掉已学到的。')
  ]
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

  const render = () => {
    content.replaceChildren()
    const { words, endings, digests, messages, confidence, routine, empty } = summarize(memory)
    const relearned = updated => { memory.routine = updated; render() }

    if (empty) {
      content.append(
        h('div', { class: 'memory-empty' },
          h('div', { class: 'empty-art', 'aria-hidden': 'true' }, icon('bubble')),
          h('h2', {}, '还没有记住什么'),
          h('p', {}, routine.learning ? '你用得多了以后，输入联想会记住你的用词、作息和聊天习惯。' : '你写的消息多了以后，输入联想会记住你的用词。')),
        ...learningSwitch(routine, relearned)
      )
      return
    }

    content.append(...routineSection(routine))

    if (messages) {
      // (Only what is there: a missing part is left out, not written as "null".)
      content.append(...[
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
      ].filter(Boolean))
    }

    if (digests.length) {
      content.append(
        h('div', { class: 'memory-head' }, h('span', {}, '各个聊天的早前内容')),
        ...digests.map(d => h('div', { class: 'memory-digest' },
          h('div', { class: 'memory-digest-text' }, d.text),
          h('div', { class: 'memory-note' }, when(d.at))))
      )
    }

    content.append(...learningSwitch(routine, relearned))

    const clear = h('button', { class: 'btn btn-outline', type: 'button' }, '清除全部记忆')
    clear.addEventListener('click', async () => {
      if (!await confirmAction(clear, { title: '清除全部记忆？', confirm: '清除' })) return
      if (!await forgetMemory()) return
      toast('已清除', { type: 'ok' })
      sheet.close?.()
    })
    content.append(h('div', { class: 'memory-clear' }, clear))
  }
  render()
  return sheet
}
