// Voice-to-text (src/assist.js transcribe): audio bytes → the words, via the
// AI binding's Whisper model. The hub route is a thin wrapper over this.
import test from 'node:test'
import assert from 'node:assert/strict'
import { transcribe, WHISPER_MODEL } from '../src/assist.js'

const envWith = (fn, vars = {}) => ({ AI: { run: fn }, ...vars })

test('sends the audio bytes to Whisper and returns the cleaned text', async () => {
  const calls = []
  const env = envWith(async (model, input) => { calls.push({ model, input }); return { text: '  hello   there \n' } })
  const text = await transcribe(env, new Uint8Array([1, 2, 3]))
  assert.equal(text, 'hello there')
  assert.equal(calls[0].model, WHISPER_MODEL)
  assert.deepEqual(calls[0].input.audio, [1, 2, 3], 'bytes passed as a plain array')
})

test('accepts a plain-string result and odd shapes', async () => {
  assert.equal(await transcribe(envWith(async () => 'just text'), new Uint8Array([0])), 'just text')
  assert.equal(await transcribe(envWith(async () => ({})), new Uint8Array([0])), '', 'nothing heard reads as empty')
  assert.equal(await transcribe(envWith(async () => ({ result: { text: 'x' } })), new Uint8Array([0])), 'x')
})

test('AI_TRANSCRIBE_MODEL overrides the model', async () => {
  let used = ''
  const env = envWith(async m => { used = m; return { text: 'ok' } }, { AI_TRANSCRIBE_MODEL: '@cf/custom/stt' })
  await transcribe(env, new Uint8Array([1]))
  assert.equal(used, '@cf/custom/stt')
})

test('a model that hangs is given up on', async () => {
  const env = envWith(() => new Promise(() => {})) // never resolves
  await assert.rejects(transcribe(env, new Uint8Array([1]), { timeout: 20 }), /timeout/)
})
