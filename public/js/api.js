// HTTP + WebSocket access to the Worker.

const listeners = new Set()

export class ApiError extends Error {
  constructor(message, status, data) {
    super(message)
    this.status = status
    this.data = data
  }
}

/** Called with 'unauthorized' when the app password session has expired. */
export function onApiEvent(fn) {
  listeners.add(fn)
  return () => listeners.delete(fn)
}

async function request(method, path, body) {
  const init = { method, credentials: 'same-origin', headers: {} }
  if (body instanceof FormData) init.body = body
  else if (body !== undefined) {
    init.headers['content-type'] = 'application/json'
    init.body = JSON.stringify(body)
  }
  let res
  try {
    res = await fetch(path, init)
  } catch {
    throw new ApiError('网络连接不可用', 0)
  }
  let data = null
  try {
    data = await res.json()
  } catch {
    // Non-JSON response; handled below.
  }
  if (res.status === 401 && path.startsWith('/api/')) for (const fn of listeners) fn('unauthorized')
  if (!res.ok || data?.ok === false) throw new ApiError(data?.error || `请求失败（${res.status}）`, res.status, data)
  return data
}

export const api = {
  get: path => request('GET', path),
  post: (path, body = {}) => request('POST', path, body),
  put: (path, body = {}) => request('PUT', path, body)
}

/**
 * Self-healing WebSocket. Reconnects with backoff, immediately when the app
 * returns to the foreground or the network comes back, and keeps itself
 * alive with pings (iOS suspends sockets in the background).
 */
export function connectSocket({ onMessage, onOpen, onClose }) {
  let ws = null
  let retry = 0
  let timer = 0
  let ping = 0
  let stopped = false

  const open = () => {
    clearTimeout(timer)
    if (stopped) return
    const url = `${location.protocol === 'https:' ? 'wss' : 'ws'}://${location.host}/api/ws`
    try {
      ws = new WebSocket(url)
    } catch {
      return schedule()
    }
    ws.addEventListener('open', () => {
      retry = 0
      clearInterval(ping)
      ping = setInterval(() => send({ t: 'ping' }), 25000)
      onOpen?.()
    })
    ws.addEventListener('message', e => {
      let msg
      try {
        msg = JSON.parse(e.data)
      } catch {
        return
      }
      onMessage(msg)
    })
    ws.addEventListener('close', () => {
      clearInterval(ping)
      onClose?.()
      if (!stopped) schedule()
    })
    ws.addEventListener('error', () => ws?.close())
  }

  const schedule = () => {
    clearTimeout(timer)
    timer = setTimeout(open, Math.min(10000, 600 * 2 ** retry++))
  }

  const send = obj => {
    if (ws?.readyState === WebSocket.OPEN) ws.send(JSON.stringify(obj))
  }

  const wake = () => {
    if (stopped) return
    if (!ws || ws.readyState === WebSocket.CLOSED || ws.readyState === WebSocket.CLOSING) {
      retry = 0
      open()
    }
  }

  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') wake()
  })
  window.addEventListener('online', wake)
  window.addEventListener('pageshow', wake)
  open()

  return {
    send,
    get connected() {
      return ws?.readyState === WebSocket.OPEN
    },
    close() {
      stopped = true
      clearTimeout(timer)
      clearInterval(ping)
      ws?.close()
    }
  }
}
