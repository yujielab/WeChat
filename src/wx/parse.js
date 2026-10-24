// Parsers for the WeChat web protocol's non-JSON responses.
// wechat4u runs these through eval(); Workers forbid eval, and running remote
// code was never a good idea, so each shape is matched explicitly instead.

/** `window.QRLogin.code = 200; window.QRLogin.uuid = "xxx==";` */
export function parseJsLogin(text) {
  const code = /window\.QRLogin\.code\s*=\s*(\d+)/.exec(text)
  const uuid = /window\.QRLogin\.uuid\s*=\s*"([^"]*)"/.exec(text)
  return { code: code ? Number(code[1]) : 0, uuid: uuid ? uuid[1] : '' }
}

/**
 * Login poll result:
 *   408 still waiting · 201 scanned (with avatar) · 200 confirmed (with redirect) · 400/402 expired
 */
export function parseLoginCheck(text) {
  const code = /window\.code\s*=\s*(\d+)/.exec(text)
  const redirect = /window\.redirect_uri\s*=\s*"([^"]*)"/.exec(text)
  const avatar = /window\.userAvatar\s*=\s*'([^']*)'/.exec(text)
  return {
    code: code ? Number(code[1]) : 0,
    redirect: redirect ? redirect[1] : '',
    avatar: avatar ? avatar[1] : ''
  }
}

/** `window.synccheck={retcode:"0",selector:"2"}` */
export function parseSyncCheck(text) {
  const retcode = /retcode\s*:\s*"?(\d+)"?/.exec(text)
  const selector = /selector\s*:\s*"?(\d+)"?/.exec(text)
  if (!retcode) return null
  return { retcode: Number(retcode[1]), selector: selector ? Number(selector[1]) : 0 }
}

/** The XML body of webwxnewloginpage. */
export function parseLoginXml(text) {
  const get = name => {
    const m = new RegExp(`<${name}>([\\s\\S]*?)</${name}>`).exec(text)
    return m ? m[1] : ''
  }
  const ret = get('ret')
  return {
    ret: ret === '' ? NaN : Number(ret),
    message: decodeEntities(stripCdata(get('message'))),
    skey: get('skey'),
    wxsid: get('wxsid'),
    wxuin: get('wxuin'),
    passTicket: get('pass_ticket'),
    isGrayscale: get('isgrayscale')
  }
}

const NAMED = { lt: '<', gt: '>', amp: '&', quot: '"', apos: "'", nbsp: ' ' }

export function decodeEntities(s) {
  if (!s || s.indexOf('&') < 0) return s || ''
  return s.replace(/&(#x[0-9a-f]+|#\d+|[a-z]+);/gi, (all, body) => {
    if (body[0] === '#') {
      const cp = body[1] === 'x' || body[1] === 'X' ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10)
      if (!Number.isFinite(cp) || cp < 0 || cp > 0x10ffff) return all
      try {
        return String.fromCodePoint(cp)
      } catch {
        return all
      }
    }
    const v = NAMED[body.toLowerCase()]
    return v === undefined ? all : v
  })
}

export function stripCdata(s) {
  return (s || '').replace(/^\s*<!\[CDATA\[([\s\S]*?)\]\]>\s*$/, '$1')
}

/**
 * Web WeChat sends emoji as `<span class="emoji emoji1f604"></span>`.
 * Ported from wechat4u's convertEmoji, including its two remaps.
 */
export function convertEmoji(s) {
  if (!s) return ''
  return s.replace(/<span[^>]*?class="emoji emoji([0-9a-f]*)"[^>]*><\/span>/gi, (all, code) => {
    let b = code.toLowerCase()
    if (b === '1f639') b = '1f602'
    else if (b === '1f64d') b = '1f614'
    let parts
    if (b.length === 4 || b.length === 5) parts = [b]
    else if (b.length === 8) parts = [b.slice(0, 4), b.slice(4, 8)]
    else if (b.length === 10) parts = [b.slice(0, 5), b.slice(5, 10)]
    else return ''
    try {
      return String.fromCodePoint(...parts.map(p => parseInt(p, 16)))
    } catch {
      return ''
    }
  })
}

/** Raw message Content → plain text (newlines, emoji, entities). */
export function contentToText(raw) {
  return decodeEntities(convertEmoji((raw || '').replace(/<br\s*\/?>/gi, '\n')))
}

/** First `<name>…</name>` in an XML fragment, CDATA unwrapped and entities decoded. */
export function xmlText(xml, name) {
  if (!xml) return ''
  const m = new RegExp(`<${name}(?:\\s[^>]*)?>([\\s\\S]*?)</${name}>`).exec(xml)
  return m ? decodeEntities(stripCdata(m[1])).trim() : ''
}

/** Attribute of the first `<tag …>` in an XML fragment. */
export function xmlAttr(xml, tag, attr) {
  if (!xml) return ''
  const t = new RegExp(`<${tag}\\s[^>]*>`).exec(xml)
  if (!t) return ''
  const a = new RegExp(`\\s${attr}\\s*=\\s*("([^"]*)"|'([^']*)')`).exec(t[0])
  return a ? decodeEntities(a[2] ?? a[3] ?? '') : ''
}

/** Value of one cookie out of Set-Cookie header lines. */
export function cookiePairs(setCookieLines) {
  const out = []
  for (const line of setCookieLines || []) {
    const first = line.split(';', 1)[0]
    const eq = first.indexOf('=')
    if (eq <= 0) continue
    const name = first.slice(0, eq).trim()
    const value = first.slice(eq + 1).trim()
    const lower = line.toLowerCase()
    const expired =
      /max-age\s*=\s*0\b/.test(lower) ||
      (() => {
        const m = /expires\s*=\s*([^;]+)/.exec(lower)
        if (!m) return false
        const t = Date.parse(m[1])
        return Number.isFinite(t) && t < Date.now()
      })()
    out.push({ name, value, expired })
  }
  return out
}
