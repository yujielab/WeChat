// Call sounds, drawn with Web Audio so there is nothing to download: the
// ringback a caller hears while the other side rings (450 Hz, one second in
// five, as phones in China ring back), a soft chime for a call coming in, and
// a short fall when a call ends. Browsers only let a page make sound once it
// has been touched; placing a call primes it from that tap. Where the page
// can't make sound yet, a call still shows and taps as before. Nothing here
// throws.

let ctx = null
let closer = 0

function audio() {
  clearTimeout(closer)
  try {
    const AC = window.AudioContext || window.webkitAudioContext
    if (!AC) return null
    if (!ctx || ctx.state === 'closed') ctx = new AC()
    if (ctx.state === 'suspended') ctx.resume?.().catch(() => {})
    return ctx
  } catch {
    return null
  }
}

/** Inside a tap: lets this page make the sounds of the call it is starting. */
export function primeTones() {
  audio()
}

/** Let the audio hardware go a moment after the last sound (the end tone has played by then). */
export function releaseTones() {
  clearTimeout(closer)
  closer = setTimeout(() => {
    const c = ctx
    ctx = null
    c?.close?.().catch(() => {})
  }, 1500)
}

// A steady tone with soft edges, so it never clicks.
function beep(ac, out, freq, at, dur, gain) {
  const env = ac.createGain()
  env.gain.setValueAtTime(0, at)
  env.gain.linearRampToValueAtTime(gain, at + 0.025)
  env.gain.setValueAtTime(gain, at + dur - 0.05)
  env.gain.linearRampToValueAtTime(0, at + dur)
  env.connect(out)
  const o = ac.createOscillator()
  o.type = 'sine'
  o.frequency.value = freq
  o.connect(env)
  o.start(at)
  o.stop(at + dur + 0.02)
}

// A struck note that dies away, with a quiet octave above for a bell's ring.
function pluck(ac, out, freq, at, gain) {
  for (const [mult, share] of [[1, 1], [2, 0.18]]) {
    const env = ac.createGain()
    env.gain.setValueAtTime(0.0001, at)
    env.gain.exponentialRampToValueAtTime(gain * share, at + 0.012)
    env.gain.exponentialRampToValueAtTime(0.0001, at + 0.9)
    env.connect(out)
    const o = ac.createOscillator()
    o.type = 'sine'
    o.frequency.value = freq * mult
    o.connect(env)
    o.start(at)
    o.stop(at + 0.95)
  }
}

// Play `pattern(ac, out, at)` every `period` seconds until stopped. Each run
// has its own volume, so stopping silences what is already scheduled too.
function repeat(pattern, period) {
  const ac = audio()
  if (!ac) return { stop() {} }
  const out = ac.createGain()
  out.connect(ac.destination)
  let next = ac.currentTime + 0.05
  let stopped = false
  const schedule = () => {
    if (stopped || ac.state === 'closed') return
    while (next < ac.currentTime + period + 0.2) {
      pattern(ac, out, next)
      next += period
    }
  }
  schedule()
  const timer = setInterval(schedule, (period * 1000) / 2)
  return {
    stop() {
      if (stopped) return
      stopped = true
      clearInterval(timer)
      try {
        out.gain.setTargetAtTime(0, ac.currentTime, 0.02)
        setTimeout(() => out.disconnect(), 200)
      } catch {}
    }
  }
}

/** What the caller hears while it rings. */
export function ringback() {
  return repeat((ac, out, at) => beep(ac, out, 450, at, 1, 0.12), 5)
}

/** A call coming in: three rising notes, twice, every few seconds. */
export function ringtone() {
  return repeat((ac, out, at) => {
    const notes = [659.25, 783.99, 987.77]
    for (let round = 0; round < 2; round++) {
      notes.forEach((f, i) => pluck(ac, out, f, at + round * 0.62 + i * 0.13, 0.16))
    }
  }, 3)
}

/** A call has ended: two notes falling. */
export function endTone() {
  const ac = audio()
  if (!ac) return
  try {
    const out = ac.createGain()
    out.connect(ac.destination)
    const at = ac.currentTime + 0.03
    pluck(ac, out, 659.25, at, 0.12)
    pluck(ac, out, 440, at + 0.16, 0.12)
  } catch {}
  releaseTones()
}
