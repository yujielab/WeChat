#!/usr/bin/env node
// Generates a VAPID key pair for Web Push and prints the wrangler commands
// that store it as Worker secrets.  Run: npm run vapid

const pair = await crypto.subtle.generateKey({ name: 'ECDSA', namedCurve: 'P-256' }, true, ['sign', 'verify'])
const jwk = await crypto.subtle.exportKey('jwk', pair.privateKey)
const raw = new Uint8Array(await crypto.subtle.exportKey('raw', pair.publicKey))
const b64url = bytes => Buffer.from(bytes).toString('base64url')

const publicKey = b64url(raw)
const privateKey = jwk.d

console.log(`VAPID_PUBLIC_KEY=${publicKey}`)
console.log(`VAPID_PRIVATE_KEY=${privateKey}`)
console.log(`
Store them as secrets (paste each value when asked):
  npx wrangler secret put VAPID_PUBLIC_KEY
  npx wrangler secret put VAPID_PRIVATE_KEY
  npx wrangler secret put VAPID_SUBJECT     # e.g. mailto:you@example.com
`)
