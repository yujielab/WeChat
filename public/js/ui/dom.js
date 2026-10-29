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

/**
 * A symbol from the sprite in index.html, drawn inline so each layer can be
 * styled and animated (rendering modes, Draw On/Off; see ui/symbols.js).
 * "x-slash" draws x with its slash.
 */
export function icon(name, cls = '') {
  const svg = drawSymbol(svgEl('svg', { 'aria-hidden': 'true', viewBox: '0 0 24 24' }), name)
  if (cls) svg.classList.add(...cls.split(/\s+/).filter(Boolean))
  return svg
}

let maskId = 0
/**
 * (Re)draw a symbol into an icon in place, keeping its other classes:
 * <g class="sym"> (the whole symbol) holds <g class="sym-layers"> (one
 * element per layer, indexed --i) and, for symbols that take one, the slash.
 */
export function drawSymbol(svg, name) {
  const slashed = name.endsWith('-slash') && document.getElementById(`i-${name.slice(0, -6)}`)
  const base = slashed ? name.slice(0, -6) : name
  const symbol = document.getElementById(`i-${base}`)
  for (const c of [...svg.classList]) if (c.startsWith('i-')) svg.classList.remove(c)
  svg.classList.add('icon', `i-${name}`)
  svg.dataset.symbol = base
  const whole = svgEl('g', { class: 'sym' })
  const layers = svgEl('g', { class: 'sym-layers' })
  let i = 0
  for (const node of symbol?.children || []) {
    const layer = node.cloneNode(true)
    layer.style.setProperty('--i', String(i++))
    layers.append(layer)
  }
  whole.append(layers)
  const parts = [whole]
  if (symbol?.hasAttribute('data-slash')) {
    // The slash erases a gap in the base as it draws: a mask stroke that
    // follows it, wider by the gap on either side.
    const id = `sym-cut-${++maskId}`
    const mask = svgEl('mask', { id, maskUnits: 'userSpaceOnUse', x: 0, y: 0, width: 24, height: 24 })
    mask.append(svgEl('rect', { width: 24, height: 24, fill: '#fff' }), slashPath('sym-cut'))
    layers.setAttribute('mask', `url(#${id})`)
    whole.append(slashPath('sym-slash'))
    parts.unshift(mask)
  }
  svg.replaceChildren(...parts)
  svg.toggleAttribute('data-slashed', Boolean(slashed))
  return svg
}

function svgEl(tag, attrs) {
  const el = document.createElementNS(SVG, tag)
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, String(v))
  return el
}

const slashPath = cls => svgEl('path', { class: cls, d: 'M4 4l16 16', pathLength: 1 })

/** Scroll-edge wash (see glass.css): four stacked blur layers. */
export function edge(side, on = false) {
  return h('div', { class: ['edge', `edge-${side}`, on && 'on'], 'aria-hidden': 'true' }, h('span'), h('span'), h('span'), h('span'))
}

/** Give each element a --s index so CSS can stagger its entrance. */
export function stagger(els, from = 0) {
  els.forEach((el, i) => el?.style.setProperty('--s', String(from + i)))
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
