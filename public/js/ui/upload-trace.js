// A small waterfall of actual image-send stages. Bars show elapsed time,
// never an invented upload percentage or a claim of recipient delivery.
import { h, icon } from './dom.js'

const duration = ms => ms < 1000 ? `${Math.round(ms)} ms` : `${(ms / 1000).toFixed(1)} s`

export function createUploadTrace() {
  const jobs = new Map()
  let chat = null
  let timer = 0
  let expanded = false
  let dismissed = null
  let destroyed = false
  let connected = false
  const label = h('span', { class: 'upload-trace-label', 'aria-live': 'polite' })
  const time = h('span', { class: 'upload-trace-time' })
  const chevron = icon('chevron-down')
  const toggle = h('button', { class: 'upload-trace-toggle', type: 'button', 'aria-expanded': 'false' },
    icon('photo'), label, time, chevron)
  const close = h('button', { class: 'upload-trace-close', type: 'button', 'aria-label': '收起发送记录' }, icon('xmark'))
  const rows = h('div', { class: 'upload-trace-rows' })
  const detail = h('div', { class: 'upload-trace-detail', hidden: true }, rows)
  const el = h('section', { class: 'upload-trace', hidden: true, 'aria-label': '图片发送状态' },
    h('div', { class: 'upload-trace-head' }, toggle, close), detail)

  const current = () => jobs.get(chat)
  toggle.addEventListener('click', () => { expanded = !expanded; render() })
  close.addEventListener('click', () => {
    dismissed = current()
    el.hidden = true
    clearTimeout(timer)
  })
  function render() {
    clearTimeout(timer)
    if (destroyed) return
    const job = current()
    el.hidden = !job || dismissed === job
    if (el.hidden) return
    const now = job.end ?? performance.now()
    const total = Math.max(1, now - job.start)
    const active = job.stages.find(s => s.state === 'active')
    const failed = job.stages.find(s => s.state === 'failed')
    const status = failed ? '发送未完成' : job.end ? '已发送' : active?.name || '准备发送'
    // Keep the live region quiet while only the elapsed clock changes.
    if (label.textContent !== status) label.textContent = status
    toggle.title = job.title
    toggle.setAttribute('aria-expanded', String(expanded))
    toggle.setAttribute('aria-label', `${status}，${expanded ? '收起' : '查看'}发送详情`)
    time.textContent = duration(total)
    close.hidden = !job.end
    el.dataset.state = failed ? 'failed' : job.end ? 'done' : 'active'
    el.classList.toggle('expanded', expanded)
    detail.hidden = !expanded
    if (expanded) {
      rows.replaceChildren(...job.stages.map(s => {
        const elapsed = s.start === null ? null : (s.end ?? now) - s.start
        const left = s.start === null ? 0 : (s.start - job.start) / total * 100
        const width = elapsed === null ? 0 : elapsed / total * 100
        const state = { waiting: '等待', active: '进行中', done: '完成', failed: '失败' }[s.state]
        return h('div', { class: 'upload-trace-row', dataset: { state: s.state } },
          h('span', { class: 'upload-trace-step' }, icon(s.state === 'done' ? 'check' : s.state === 'failed' ? 'exclaim' : s.icon), s.name),
          h('span', { class: 'upload-trace-track', 'aria-hidden': 'true' }, h('i', { style: { left: `${left}%`, width: `${width}%` } })),
          h('span', { class: 'upload-trace-duration', 'aria-label': `${state}${elapsed === null ? '' : `，${duration(elapsed)}`}` }, elapsed === null ? '—' : duration(elapsed)))
      }))
      const caption = h('p', { class: 'upload-trace-caption' }, failed ? job.error : job.title)
      rows.append(caption)
    }
    // A hidden document needs no clock. Stage completion still updates state.
    if (!job.end && !document.hidden && el.isConnected) timer = setTimeout(render, 120)
  }
  document.addEventListener('visibilitychange', render)
  const lifecycle = new MutationObserver(() => {
    if (el.isConnected) connected = true
    else if (connected) destroy()
  })
  lifecycle.observe(document.documentElement, { childList: true, subtree: true })
  function destroy() {
    if (destroyed) return
    destroyed = true
    clearTimeout(timer)
    lifecycle.disconnect()
    document.removeEventListener('visibilitychange', render)
    jobs.clear()
  }
  return {
    el,
    destroy,
    setChat(id) { chat = id; expanded = false; render() },
    begin(id, title, { prepared = false } = {}) {
      const job = { title, start: performance.now(), end: null, stages: [
        ...(!prepared ? [{ name: '处理图片', icon: 'photo' }] : []),
        { name: '上传图片', icon: 'arrow-up' }, { name: '发送消息', icon: 'bubble' }
      ].map(s => ({ ...s, start: null, end: null, state: 'waiting' })) }
      jobs.set(id, job)
      if (jobs.size > 30) for (const [key, old] of jobs) { if (old.end && key !== chat) { jobs.delete(key); break } }
      function update() { if (current() === job) render() }
      return {
        stage(index) {
          const now = performance.now()
          for (const s of job.stages) if (s.state === 'active') { s.state = 'done'; s.end = now }
          const s = job.stages[index]
          if (s) { s.start = now; s.state = 'active' }
          update()
        },
        finish() {
          job.end = performance.now()
          for (const s of job.stages) if (s.state === 'active') { s.state = 'done'; s.end = job.end }
          update()
        },
        fail(error) {
          job.end = performance.now()
          job.error = error?.message || '发送失败，请重试。'
          for (const s of job.stages) if (s.state === 'active') { s.state = 'failed'; s.end = job.end }
          update()
        }
      }
    }
  }
}
