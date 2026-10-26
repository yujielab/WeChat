import { test } from 'node:test'
import assert from 'node:assert/strict'
import { webcrypto } from 'node:crypto'
import { hashPassword, verifyPassword, mintToken, readToken } from '../src/auth.js'

globalThis.crypto ??= webcrypto

test('password verification accepts the Workers-compatible 100k PBKDF2 format', async () => {
  // Independent PBKDF2-HMAC-SHA256 fixture: 16-byte salt, 100,000 iterations,
  // 32-byte output. Some local workerd versions accept higher counts than
  // production, so this also guards the persisted credential format.
  assert.equal(await verifyPassword(
    'format compatibility password',
    'ABEiM0RVZneImaq7zN3u_w',
    'kK57MOY6z19rUlEBIKhOYNtdKTFpwh__8Ij0RhjU8B0'
  ), true)
})

test('password hashing: verify round-trip, reject wrong, unique salt', async () => {
  const a = await hashPassword('correct horse')
  const b = await hashPassword('correct horse')
  assert.notEqual(a.salt, b.salt) // random salt
  assert.notEqual(a.hash, b.hash)
  assert.equal(await verifyPassword('correct horse', a.salt, a.hash), true)
  assert.equal(await verifyPassword('wrong', a.salt, a.hash), false)
  assert.equal(await verifyPassword('correct horse', a.salt, b.hash), false)
})

test('session token: mint and read, reject tampered, expired, wrong secret, epoch carried', async () => {
  const secret = crypto.getRandomValues(new Uint8Array(32))
  const other = crypto.getRandomValues(new Uint8Array(32))
  const token = await mintToken(secret, { uid: 'u1', epoch: 2 })
  const claims = await readToken(secret, token)
  assert.equal(claims.uid, 'u1')
  assert.equal(claims.epoch, 2)
  assert.equal(await readToken(other, token), null) // wrong secret
  assert.equal(await readToken(secret, token.slice(0, -2) + 'xy'), null) // tampered sig
  assert.equal(await readToken(secret, 'garbage'), null)
  const expired = await mintToken(secret, { uid: 'u1', epoch: 0, maxAge: -10 })
  assert.equal(await readToken(secret, expired), null)
})
