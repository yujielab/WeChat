import { test } from 'node:test'
import assert from 'node:assert/strict'
import { suggest, keywords, keysIn, cleanSuggestion, allowSuggestion, assistConfigured, DEFAULT_MODEL } from '../src/assist.js'

/** Workers AI as the binding gives it: run(model, input), answering with { response }. */
function ai(answer) {
  const calls = []
  return {
    calls,
    env: {
      AI: {
        async run(model, input) {
          calls.push({ model, input })
          return typeof answer === 'function' ? answer(input) : { response: answer }
        }
      }
    }
  }
}
const prompt = call => call.input.messages.map(m => m.content).join('\n')

test('only offered where the AI binding is', () => {
  assert.equal(assistConfigured({}), false)
  assert.equal(assistConfigured({ AI: {} }), false)
  assert.equal(assistConfigured(ai('').env), true)
})

test('a suggestion continues the draft from sent messages only, and is cleaned', async () => {
  const { env, calls } = ai('<think>let me see</think>明天下午三点见')
  const history = [{ mine: false, text: '我们什么时候见？' }, { mine: true, text: '我看看' }]
  assert.equal(await suggest(env, { history, draft: '明天' }), '下午三点见', 'the draft is not repeated; thinking is dropped')
  assert.equal(calls[0].model, DEFAULT_MODEL)
  const said = prompt(calls[0])
  assert.match(said, /对方：我们什么时候见？/)
  assert.match(said, /我：我看看/)
  assert.match(said, /「明天」/)
  assert.equal(calls[0].input.max_tokens, 40)
})

test('a reply is offered only when the last message is someone else\'s', async () => {
  const { env, calls } = ai('“好的，马上到”')
  assert.equal(await suggest(env, { history: [{ mine: false, text: '你到了吗' }], draft: '' }), '好的，马上到')
  assert.equal(await suggest(env, { history: [{ mine: false, text: '你到了吗' }, { mine: true, text: '快了' }], draft: '' }), '')
  assert.equal(await suggest(env, { history: [], draft: '' }), '')
  assert.equal(calls.length, 1, 'no call when there is nothing to answer')
})

test('suggestions are short, single-line and never the draft itself', () => {
  assert.equal(cleanSuggestion('回复：好的\n第二行'), '好的')
  assert.equal(cleanSuggestion('明天', '明天'), '')
  assert.equal(cleanSuggestion('see you', 'ok'), ' see you', 'Latin words keep their space')
  assert.equal([...cleanSuggestion('一'.repeat(60))].length, 24)
})

test('key words are exact pieces of the message, at most three, not overlapping', async () => {
  const text = '明天下午3点在会议室A开会，记得带电脑'
  const { env } = ai('关键词：["明天下午3点","会议室A","会议","带电脑","不存在的词","记得带电脑"]')
  assert.deepEqual(await keywords(env, text), ['明天下午3点', '会议室A', '带电脑'])
  assert.deepEqual(keysIn(text, [text, 'x', 42, '在会']), ['在会'], 'not the whole message, not a single character')
  assert.deepEqual(await keywords(ai('[]').env, text), [])
  assert.deepEqual(await keywords(ai('not json').env, text), [])
  const short = ai('["好"]')
  assert.deepEqual(await keywords(short.env, '好的'), [], 'too short to bother')
  assert.equal(short.calls.length, 0)
})

test('each person gets a limited number of suggestions a minute', () => {
  let ok = 0
  for (let i = 0; i < 40; i++) if (allowSuggestion('u-limit', 1000)) ok++
  assert.equal(ok, 30)
  assert.equal(allowSuggestion('u-limit', 1000 + 61000), true, 'a minute later, again')
  assert.equal(allowSuggestion('someone-else', 1000), true)
})

test('another model can be chosen; an OpenAI-shaped answer reads too', async () => {
  const { env, calls } = ai(() => ({ choices: [{ message: { content: '好的' } }] }))
  env.AI_MODEL = '@cf/zai-org/glm-4.7-flash'
  assert.equal(await suggest(env, { history: [{ mine: false, text: '收到吗' }], draft: '' }), '好的')
  assert.equal(calls[0].model, '@cf/zai-org/glm-4.7-flash')
})
