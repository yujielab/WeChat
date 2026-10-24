// Tiny DOM helpers. Everything user-provided goes in as text nodes.

export function h(tag, props, ...children) {
  const el = document.createElement(tag)
  if (props) {
    for (const [k, v] of Object.entries(props)) {
      if (v === undefined || v === null || v === false) continue
      if (k === 'class') el.className = Array.isArray(v) ? v.filter(Boolean).join(' ') : v
      else if (k === 'dataset') Object.assign(el.dataset, v)
      else if (k === 'style') {
        for (const [p, val] of Object.entries(v)) {
          if (p.startsWith('--')) el.style.setProperty(p, val)
          else el.style[p] = val
        }
      } else if (k === 'on') {
        for (const [ev, fn] of Object.entries(v)) el.addEventListener(ev, fn)
      } else if (k === 'text') el.textContent = v
      else if (k in el && typeof v !== 'string') el[k] = v
      else el.setAttribute(k, v === true ? '' : v)
    }
  }
  append(el, children)
  return el
}

export function append(el, children) {
  for (const c of children.flat(Infinity)) {
    if (c === null || c === undefined || c === false) continue
    el.append(c instanceof Node ? c : document.createTextNode(String(c)))
  }
  return el
}

const SVG = 'http://www.w3.org/2000/svg'

export function icon(name, cls = '') {
  const svg = document.createElementNS(SVG, 'svg')
  svg.setAttribute('class', `icon i-${name} ${cls}`.trim())
  svg.setAttribute('aria-hidden', 'true')
  const use = document.createElementNS(SVG, 'use')
  use.setAttribute('href', `#i-${name}`)
  svg.append(use)
  return svg
}

export function clear(el) {
  while (el.firstChild) el.firstChild.remove()
  return el
}

export const raf = () => new Promise(r => requestAnimationFrame(() => r()))
export const raf2 = () => new Promise(r => requestAnimationFrame(() => requestAnimationFrame(() => r())))

const reduceQuery = matchMedia('(prefers-reduced-motion: reduce)')
export function reducedMotion() {
  const pref = document.documentElement.dataset.motion
  if (pref === 'reduce') return true
  if (pref === 'full') return false
  return reduceQuery.matches
}

/** Resolves when the element's transition on `prop` ends (or after a timeout). */
export function transitionEnd(el, prop, timeout = 700) {
  return new Promise(resolve => {
    let done = false
    const finish = () => {
      if (done) return
      done = true
      el.removeEventListener('transitionend', onEnd)
      resolve()
    }
    const onEnd = e => {
      if (e.target === el && (!prop || e.propertyName === prop)) finish()
    }
    el.addEventListener('transitionend', onEnd)
    setTimeout(finish, timeout)
  })
}

export function announce(text) {
  const el = document.getElementById('announcer')
  if (!el) return
  el.textContent = ''
  setTimeout(() => { el.textContent = text }, 30)
}

export function storage(key, value) {
  try {
    if (value === undefined) return localStorage.getItem(key)
    if (value === null) localStorage.removeItem(key)
    else localStorage.setItem(key, value)
  } catch {
    // Private mode or storage disabled: settings just don't persist.
  }
  return null
}
