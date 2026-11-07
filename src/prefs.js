// What someone chose to see behind things: their conversations (one for all,
// and any conversation of its own), their calls, and — shown to everyone —
// their profile's cover. Each is one of the app's own backdrops
// ('preset:<name>'), a photo they uploaded themselves, or '' for the default.
// And whether friends see when they've read a message (read receipts; on
// unless turned off). Kept on the server, so each of their devices shows the
// same — and so a receipt turned off is never sent at all.

const PRESET = /^preset:[a-z0-9-]{1,24}$/
export const MAX_ROOMS = 300 // conversations with a backdrop of their own

/**
 * A backdrop as stored: '' (the default), a preset, or a photo this account
 * uploaded as `kind` — never an outside URL, which would have other devices
 * fetch it. undefined when it's none of those.
 */
export function backdrop(value, kind, uid) {
  if (value === '' || value === null) return ''
  if (typeof value !== 'string') return undefined
  if (PRESET.test(value)) return value
  const own = `/api/media/${kind}/${uid}/`
  return value.startsWith(own) && /^[\w-]+$/.test(value.slice(own.length)) ? value : undefined
}

/** Stored prefs in their current shape (whatever an older version saved). */
export function readPrefs(stored) {
  const p = stored && typeof stored === 'object' ? stored : {}
  const rooms = {}
  for (const [id, v] of Object.entries(p.rooms && typeof p.rooms === 'object' ? p.rooms : {})) {
    if (typeof v === 'string' && v) rooms[id] = v
  }
  return { chat: typeof p.chat === 'string' ? p.chat : '', call: typeof p.call === 'string' ? p.call : '', rooms, receipts: p.receipts !== false }
}

/** Do this person's friends see when they've read a message? */
export const sharesReceipts = stored => readPrefs(stored).receipts

/**
 * Apply a change: { chat?, call?, rooms?: { [roomId]: value }, receipts? },
 * '' putting a backdrop back to the default. isMember(roomId) says which
 * conversations are theirs. Returns { prefs } or { error }.
 */
export function patchPrefs(current, body, { uid, isMember }) {
  const next = readPrefs(current)
  if (body.receipts !== undefined) {
    if (typeof body.receipts !== 'boolean') return { error: 'Invalid setting' }
    next.receipts = body.receipts
  }
  for (const key of ['chat', 'call']) {
    if (body[key] === undefined) continue
    const v = backdrop(body[key], 'bg', uid)
    if (v === undefined) return { error: 'Invalid background' }
    next[key] = v
  }
  if (body.rooms !== undefined) {
    if (!body.rooms || typeof body.rooms !== 'object' || Array.isArray(body.rooms)) return { error: 'Invalid background' }
    for (const [id, value] of Object.entries(body.rooms)) {
      const v = backdrop(value, 'bg', uid)
      if (v === undefined || !isMember(id)) return { error: 'Invalid background' }
      if (v) next.rooms[id] = v
      else delete next.rooms[id]
    }
    if (Object.keys(next.rooms).length > MAX_ROOMS) return { error: `You can set a background for at most ${MAX_ROOMS} chats` }
  }
  return { prefs: next }
}
