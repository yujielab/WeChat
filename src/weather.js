// Weather for the smart panels (src/insights.js): now and the next sunrise
// or sunset where someone is, from Open-Meteo (no key; city names through
// its geocoder). A place's weather is kept for half an hour.

const FORECAST = 'https://api.open-meteo.com/v1/forecast'
const GEOCODE = 'https://geocoding-api.open-meteo.com/v1/search'
const KEEP_MS = 30 * 60 * 1000
const TIMEOUT_MS = 5000

const cache = new Map()

// WMO weather codes, as words and a symbol (day / night).
const CODES = [
  [[0], '晴', 'sun', 'moon'],
  [[1], '大致晴朗', 'sun', 'moon'],
  [[2], '局部多云', 'cloud', 'cloud'],
  [[3], '阴', 'cloud', 'cloud'],
  [[45, 48], '雾', 'cloud', 'cloud'],
  [[51, 53, 55, 56, 57], '毛毛雨', 'cloud-rain', 'cloud-rain'],
  [[61, 80], '小雨', 'cloud-rain', 'cloud-rain'],
  [[63, 81], '中雨', 'cloud-rain', 'cloud-rain'],
  [[65, 82], '大雨', 'cloud-rain', 'cloud-rain'],
  [[66, 67], '冻雨', 'cloud-rain', 'cloud-rain'],
  [[71, 85], '小雪', 'cloud-snow', 'cloud-snow'],
  [[73, 75, 77, 86], '雪', 'cloud-snow', 'cloud-snow'],
  [[95, 96, 99], '雷雨', 'cloud-bolt', 'cloud-bolt']
]

export function describe(code, isDay = true) {
  const row = CODES.find(([codes]) => codes.includes(Number(code)))
  if (!row) return { text: '', symbol: isDay ? 'sun' : 'moon' }
  // A clear night reads as one.
  const text = !isDay && row[0][0] <= 1 ? (row[0][0] === 0 ? '晴朗夜空' : '大致晴朗') : row[1]
  return { text, symbol: isDay ? row[2] : row[3] }
}

async function get(url, fetcher) {
  const ctl = new AbortController()
  const timer = setTimeout(() => ctl.abort(), TIMEOUT_MS)
  try {
    const res = await fetcher(url, { signal: ctl.signal, headers: { accept: 'application/json' } })
    if (!res.ok) throw new Error(`weather ${res.status}`)
    return await res.json()
  } finally {
    clearTimeout(timer)
  }
}

/** Where a city is: { lat, lon, name } or null. */
export async function geocode(city, fetcher = fetch) {
  const name = String(city || '').trim().slice(0, 40)
  if (!name) return null
  const key = `geo:${name}`
  const hit = cache.get(key)
  if (hit && Date.now() - hit.at < 24 * 3600 * 1000) return hit.value
  const data = await get(`${GEOCODE}?name=${encodeURIComponent(name)}&count=1&language=zh&format=json`, fetcher)
  const r = data?.results?.[0]
  const value = r && Number.isFinite(r.latitude) && Number.isFinite(r.longitude) ? { lat: r.latitude, lon: r.longitude, name: r.name || name } : null
  cache.set(key, { at: Date.now(), value })
  return value
}

/**
 * The weather at { lat, lon } now: temperature (unit 'c' or 'f'), words and
 * a symbol, and the next sunrise or sunset there (its own clock, 'HH:mm').
 */
export async function weatherAt({ lat, lon }, { unit = 'c', fetcher = fetch, now = Date.now() } = {}) {
  const la = Math.round(Number(lat) * 100) / 100
  const lo = Math.round(Number(lon) * 100) / 100
  if (!Number.isFinite(la) || !Number.isFinite(lo)) return null
  const u = unit === 'f' ? 'f' : 'c'
  const key = `wx:${la},${lo},${u}`
  const hit = cache.get(key)
  if (hit && now - hit.at < KEEP_MS) return hit.value
  const q = new URLSearchParams({
    latitude: String(la),
    longitude: String(lo),
    current: 'temperature_2m,weather_code,is_day',
    daily: 'sunrise,sunset,temperature_2m_max,temperature_2m_min',
    timezone: 'auto',
    forecast_days: '2',
    ...(u === 'f' && { temperature_unit: 'fahrenheit' })
  })
  const data = await get(`${FORECAST}?${q}`, fetcher)
  const cur = data?.current
  if (!cur || !Number.isFinite(cur.temperature_2m)) return null
  const isDay = cur.is_day !== 0
  // The place's own clock: Open-Meteo gives local times and their offset.
  const offset = Number(data.utc_offset_seconds) || 0
  const local = new Date(now + offset * 1000).toISOString().slice(0, 16)
  const times = [...(data.daily?.sunrise || []).map(t => ['sunrise', t]), ...(data.daily?.sunset || []).map(t => ['sunset', t])]
    .filter(([, t]) => typeof t === 'string' && t > local)
    .sort((a, b) => (a[1] < b[1] ? -1 : 1))
  const next = times[0]
  const value = {
    temp: Math.round(cur.temperature_2m),
    unit: u,
    ...describe(cur.weather_code, isDay),
    isDay,
    high: Number.isFinite(data.daily?.temperature_2m_max?.[0]) ? Math.round(data.daily.temperature_2m_max[0]) : null,
    low: Number.isFinite(data.daily?.temperature_2m_min?.[0]) ? Math.round(data.daily.temperature_2m_min[0]) : null,
    next: next ? { kind: next[0], time: next[1].slice(11, 16) } : null
  }
  cache.set(key, { at: now, value })
  if (cache.size > 500) cache.delete(cache.keys().next().value)
  return value
}
