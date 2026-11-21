import test from 'node:test'
import assert from 'node:assert/strict'
import { cleanPlace, mapsConfigured, snapshotURL } from '../src/maps.js'
import { cleanText } from '../src/hub.js'

test('a place keeps its point, name and address; anything else is refused', () => {
  assert.deepEqual(cleanPlace({ lat: 31.2304123456, lng: 121.4737, name: ' The Bund ', address: 'Huangpu, Shanghai' }, cleanText),
    { lat: 31.230412, lng: 121.4737, name: 'The Bund', address: 'Huangpu, Shanghai' })
  assert.equal(cleanPlace({ lat: 91, lng: 0 }, cleanText), null)
  assert.equal(cleanPlace({ lat: 'x', lng: 0 }, cleanText), null)
  assert.equal(cleanPlace(null, cleanText), null)
  assert.equal(cleanPlace({ lat: 1, lng: 2, name: 'a'.repeat(300) }, cleanText).name.length, 100)
})

test('maps are only on with all three MapKit settings', () => {
  assert.equal(mapsConfigured({}), false)
  assert.equal(mapsConfigured({ MAPKIT_TEAM_ID: 't', MAPKIT_KEY_ID: 'k' }), false)
  assert.equal(mapsConfigured({ MAPKIT_TEAM_ID: 't', MAPKIT_KEY_ID: 'k', MAPKIT_PRIVATE_KEY: 'p' }), true)
})

test('a snapshot URL is Apple\'s, centred on the place, and signed (DER, base64url)', async () => {
  const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
  const pkcs8 = Buffer.from(await crypto.subtle.exportKey('pkcs8', pair.privateKey)).toString('base64')
  const env = { MAPKIT_TEAM_ID: 'TEAM123', MAPKIT_KEY_ID: 'KEY456', MAPKIT_PRIVATE_KEY: `-----BEGIN PRIVATE KEY-----\n${pkcs8}\n-----END PRIVATE KEY-----` }
  const url = new URL(await snapshotURL(env, { lat: 31.2304, lng: 121.4737, w: 248, h: 140, dark: true }))
  assert.equal(url.origin, 'https://snapshot.apple-mapkit.com')
  assert.equal(url.pathname, '/api/v1/snapshot')
  assert.equal(url.searchParams.get('center'), '31.230400,121.473700')
  assert.equal(url.searchParams.get('colorScheme'), 'dark')
  assert.equal(url.searchParams.get('teamId'), 'TEAM123')
  const sig = url.searchParams.get('signature')
  assert.match(sig, /^[A-Za-z0-9_-]+$/)
  const der = Buffer.from(sig.replace(/-/g, '+').replace(/_/g, '/'), 'base64')
  assert.equal(der[0], 0x30)
  // The signature verifies over the path and query before it.
  const signed = url.pathname + url.search.replace(/&signature=.*$/, '')
  const { createPublicKey, verify } = await import('node:crypto')
  const spki = Buffer.from(await crypto.subtle.exportKey('spki', pair.publicKey))
  const ok = verify('sha256', Buffer.from(signed), createPublicKey({ key: spki, format: 'der', type: 'spki' }), der)
  assert.equal(ok, true)
})
