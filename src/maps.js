// Apple Maps for shared places on the web: a small map of the spot, from
// Apple's Maps Web Snapshots, through a URL signed here with this server's
// MapKit key so the key never reaches a browser. The iOS app draws its own
// (MapKit on the device) and needs none of this.
//
// Optional: set MAPKIT_TEAM_ID, MAPKIT_KEY_ID and MAPKIT_PRIVATE_KEY (the .p8
// key's PEM text, from a Maps ID / MapKit JS key in the Apple Developer
// account) with `wrangler secret put`. Without them a place still shows, as
// a card with its name and address and a link to Apple Maps.

const SNAPSHOT_HOST = 'https://snapshot.apple-mapkit.com'

export function mapsConfigured(env) {
  return Boolean(env.MAPKIT_TEAM_ID && env.MAPKIT_KEY_ID && env.MAPKIT_PRIVATE_KEY)
}

let keyP = null
function signingKey(env) {
  keyP ||= (async () => {
    const pem = String(env.MAPKIT_PRIVATE_KEY).replace(/-----[^-]+-----/g, '').replace(/\s+/g, '')
    const der = Uint8Array.from(atob(pem), c => c.charCodeAt(0))
    return crypto.subtle.importKey('pkcs8', der, { name: 'ECDSA', namedCurve: 'P-256' }, false, ['sign'])
  })()
  keyP.catch(() => { keyP = null })
  return keyP
}

const b64url = bytes => btoa(String.fromCharCode(...bytes)).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '')

// WebCrypto signs ECDSA as raw r‖s; the signature Apple's sample produces is
// DER (Node's default), so it is wrapped the same way.
function derFromRaw(raw) {
  const int = b => {
    let i = 0
    while (i < b.length - 1 && b[i] === 0) i++
    let v = b.slice(i)
    if (v[0] & 0x80) v = Uint8Array.from([0, ...v])
    return Uint8Array.from([0x02, v.length, ...v])
  }
  const r = int(raw.slice(0, 32))
  const s = int(raw.slice(32))
  return Uint8Array.from([0x30, r.length + s.length, ...r, ...s])
}

/**
 * A signed snapshot URL for a place: centred on it, a red pin on it, light
 * or dark, at twice the size asked for (points → pixels).
 */
export async function snapshotURL(env, { lat, lng, w = 248, h = 140, dark = false }) {
  const center = `${lat.toFixed(6)},${lng.toFixed(6)}`
  const annotations = JSON.stringify([{ point: center, color: 'ff3b30', markerStyle: 'balloon' }])
  const q = new URLSearchParams({
    center,
    z: '15',
    size: `${w}x${h}`,
    scale: '2',
    colorScheme: dark ? 'dark' : 'light',
    poi: '1',
    annotations,
    teamId: env.MAPKIT_TEAM_ID,
    keyId: env.MAPKIT_KEY_ID
  })
  const path = `/api/v1/snapshot?${q}`
  const key = await signingKey(env)
  const raw = new Uint8Array(await crypto.subtle.sign({ name: 'ECDSA', hash: 'SHA-256' }, key, new TextEncoder().encode(path)))
  return `${SNAPSHOT_HOST}${path}&signature=${b64url(derFromRaw(raw))}`
}

/** A place in a message: a point, a name, an address; null when it won't do. */
export function cleanPlace(meta, clean) {
  const lat = Number(meta?.lat)
  const lng = Number(meta?.lng)
  if (!Number.isFinite(lat) || !Number.isFinite(lng) || Math.abs(lat) > 90 || Math.abs(lng) > 180) return null
  return {
    lat: Math.round(lat * 1e6) / 1e6,
    lng: Math.round(lng * 1e6) / 1e6,
    name: clean(meta.name, 100),
    address: clean(meta.address, 200)
  }
}
