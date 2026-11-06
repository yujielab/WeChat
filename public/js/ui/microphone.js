// The microphone for dictation: open the mic, meter it for the VoiceBeam, and
// capture a clip that is handed back as 16 kHz mono WAV — the format Whisper
// reads everywhere (iOS MediaRecorder emits mp4/AAC, which the model may
// refuse, so we always decode and re-encode). No dependencies.
//
//   const mic = createMicrophone()
//   await mic.start()               // from a user gesture, secure context only
//   beam.setLevel(mic.level)        // 0..1 per frame, for the glow
//   const { wav } = await mic.stop() // Uint8Array, ready to POST
//
// state: 'idle' | 'live'. start() rejects with a readable message when the
// mic is blocked, missing or the page isn't secure.

export function microphoneSupported() {
  return !!(navigator.mediaDevices?.getUserMedia && window.MediaRecorder && window.isSecureContext)
}

const pickMime = () => ['audio/mp4', 'audio/webm;codecs=opus', 'audio/webm', 'audio/ogg;codecs=opus']
  .find(t => { try { return MediaRecorder.isTypeSupported(t) } catch { return false } }) || ''

export function createMicrophone() {
  let stream = null
  let ctx = null
  let analyser = null
  let buf = null
  let recorder = null
  let chunks = []
  let state = 'idle'

  return {
    get state() { return state },
    get stream() { return stream },

    /** Current amplitude 0..1 (RMS of the time-domain signal). */
    level() {
      if (!analyser) return 0
      analyser.getByteTimeDomainData(buf)
      let sum = 0
      for (let i = 0; i < buf.length; i++) {
        const x = (buf[i] - 128) / 128
        sum += x * x
      }
      return Math.min(1, Math.sqrt(sum / buf.length) * 3.2)
    },

    async start() {
      if (state === 'live') return
      if (!window.isSecureContext) throw new Error('Voice input needs a secure connection (https).')
      if (!navigator.mediaDevices?.getUserMedia) throw new Error('This device has no microphone access.')
      if (!window.MediaRecorder) throw new Error('This browser cannot record audio.')
      stream = await navigator.mediaDevices.getUserMedia({
        audio: { echoCancellation: true, noiseSuppression: true, autoGainControl: true }
      })
      const AudioCtx = window.AudioContext || window.webkitAudioContext
      ctx = new AudioCtx()
      // Some browsers open the context suspended until a gesture resumes it.
      if (ctx.state === 'suspended') ctx.resume().catch(() => {})
      analyser = ctx.createAnalyser()
      analyser.fftSize = 1024
      analyser.smoothingTimeConstant = 0.6
      ctx.createMediaStreamSource(stream).connect(analyser)
      buf = new Uint8Array(analyser.fftSize)
      chunks = []
      const mime = pickMime()
      recorder = new MediaRecorder(stream, mime ? { mimeType: mime } : undefined)
      recorder.addEventListener('dataavailable', e => { if (e.data && e.data.size) chunks.push(e.data) })
      recorder.start()
      state = 'live'
    },

    /** Stop and return { wav } (16 kHz mono), or { wav: null } if nothing was captured. */
    async stop() {
      if (state !== 'live') return { wav: null }
      state = 'idle'
      const blob = await new Promise(resolve => {
        recorder.addEventListener('stop', async () => resolve(new Blob(chunks, { type: recorder.mimeType || 'audio/webm' })), { once: true })
        try { recorder.stop() } catch { resolve(new Blob(chunks)) }
      })
      this.release()
      if (!blob.size) return { wav: null }
      try {
        const wav = await blobToWav(blob)
        return { wav }
      } catch {
        return { wav: null }
      }
    },

    /** Drop the mic and audio graph. */
    release() {
      try { recorder?.state === 'recording' && recorder.stop() } catch {}
      recorder = null
      stream?.getTracks().forEach(t => t.stop())
      stream = null
      ctx?.close().catch(() => {})
      ctx = analyser = buf = null
    }
  }
}

/** Bytes → base64 (chunked, so a large clip doesn't overflow the call stack). */
export function bytesToBase64(bytes) {
  let s = ''
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000))
  return btoa(s)
}

const TARGET_RATE = 16000

/** Decode any recorded blob, downmix to mono, resample to 16 kHz, encode WAV. */
async function blobToWav(blob) {
  const bytes = new Uint8Array(await blob.arrayBuffer())
  const AudioCtx = window.AudioContext || window.webkitAudioContext
  const decodeCtx = new AudioCtx()
  const decoded = await new Promise((resolve, reject) => {
    // Safari historically needs the callback form of decodeAudioData.
    const p = decodeCtx.decodeAudioData(bytes.buffer.slice(0), resolve, reject)
    if (p && typeof p.then === 'function') p.then(resolve, reject)
  })
  decodeCtx.close().catch(() => {})
  const frames = Math.ceil(decoded.duration * TARGET_RATE)
  const Offline = window.OfflineAudioContext || window.webkitOfflineAudioContext
  const off = new Offline(1, Math.max(1, frames), TARGET_RATE)
  const src = off.createBufferSource()
  src.buffer = decoded
  src.connect(off.destination)
  src.start(0)
  const rendered = await off.startRendering()
  return encodeWav(rendered.getChannelData(0), TARGET_RATE)
}

/** Float32 mono samples → 16-bit PCM WAV bytes. */
function encodeWav(samples, rate) {
  const n = samples.length
  const out = new DataView(new ArrayBuffer(44 + n * 2))
  const str = (off, s) => { for (let i = 0; i < s.length; i++) out.setUint8(off + i, s.charCodeAt(i)) }
  str(0, 'RIFF'); out.setUint32(4, 36 + n * 2, true); str(8, 'WAVE')
  str(12, 'fmt '); out.setUint32(16, 16, true); out.setUint16(20, 1, true); out.setUint16(22, 1, true)
  out.setUint32(24, rate, true); out.setUint32(28, rate * 2, true); out.setUint16(32, 2, true); out.setUint16(34, 16, true)
  str(36, 'data'); out.setUint32(40, n * 2, true)
  let p = 44
  for (let i = 0; i < n; i++) {
    const s = Math.max(-1, Math.min(1, samples[i]))
    out.setInt16(p, s < 0 ? s * 0x8000 : s * 0x7fff, true)
    p += 2
  }
  return new Uint8Array(out.buffer)
}
