import { test } from 'node:test'
import assert from 'node:assert/strict'
import { encryptPayload, b64urlDecode, b64urlEncode, generateVapid, vapidAuthorization } from '../src/push/webpush.js'

// RFC 8291, Appendix A.
const V = {
  plaintext: 'When I grow up, I want to be a watermelon',
  asPrivate: 'yfWPiYE-n46HLnH0KqZOF1fJJU3MYrct3AELtAQ-oRw',
  asPublic: 'BP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A8',
  uaPublic: 'BCVxsr7N_eNgVRqvHtD0zTZsEc6-VV-JvLexhqUzORcxaOzi6-AYWXvTBHm4bjyPjs7Vd8pZGH6SRpkNtoIAiw4',
  salt: 'DGv6ra1nlYgDCS1FRnbzlw',
  authSecret: 'BTBZMqHH6r4Tts7J_aSIgg',
  body:
    'DGv6ra1nlYgDCS1FRnbzlwAAEABBBP4z9KsN6nGRTbVYI_c7VJSPQTBtkgcy27mlmlMoZIIgDll6e3vCYLocInmYWAmS6TlzAC8wEqKK6PBru3jl7A_yl95bQpu6cVPTpK4Mqgkf1CXztLVBSt2Ks3oZwbuwXPXLWyouBWLVWGNWQexSgSxsj_Qulcy4a-fN'
}

test('aes128gcm encryption matches the RFC 8291 test vector', async () => {
  const body = await encryptPayload(
    new TextEncoder().encode(V.plaintext),
    b64urlDecode(V.uaPublic),
    b64urlDecode(V.authSecret),
    { salt: b64urlDecode(V.salt), serverKeys: { publicRaw: b64urlDecode(V.asPublic), d: V.asPrivate } }
  )
  assert.equal(b64urlEncode(body), V.body)
})

test('fresh encryption produces a well-formed header', async () => {
  const ua = await crypto.subtle.generateKey({ name: 'ECDH', namedCurve: 'P-256' }, true, ['deriveBits'])
  const uaRaw = new Uint8Array(await crypto.subtle.exportKey('raw', ua.publicKey))
  const body = await encryptPayload(new TextEncoder().encode('{"t":1}'), uaRaw, crypto.getRandomValues(new Uint8Array(16)))
  assert.equal(body[16] * 2 ** 24 + body[17] * 2 ** 16 + body[18] * 2 ** 8 + body[19], 4096)
  assert.equal(body[20], 65)
  assert.equal(body[21], 4)
  // salt + rs + idlen + key + (plaintext + delimiter) + tag
  assert.equal(body.length, 16 + 4 + 1 + 65 + 8 + 16)
})

test('a generated VAPID key signs a JWT the push service can verify, identified by the app', async () => {
  const keys = await generateVapid()
  assert.equal(b64urlDecode(keys.publicKey).length, 65)
  const auth = await vapidAuthorization({ ...keys, subject: 'https://wechat.cuven.us' }, 'https://web.push.apple.com/abc')
  const [, jwt, k] = auth.match(/^vapid t=([^,]+), k=(.+)$/)
  assert.equal(k, keys.publicKey)
  const [h, c, s] = jwt.split('.')
  const claims = JSON.parse(new TextDecoder().decode(b64urlDecode(c)))
  assert.equal(claims.aud, 'https://web.push.apple.com')
  assert.equal(claims.sub, 'https://wechat.cuven.us')
  const pub = await crypto.subtle.importKey('raw', b64urlDecode(keys.publicKey), { name: 'ECDSA', namedCurve: 'P-256' }, false, ['verify'])
  assert.ok(await crypto.subtle.verify({ name: 'ECDSA', hash: 'SHA-256' }, pub, b64urlDecode(s), new TextEncoder().encode(`${h}.${c}`)))
})
