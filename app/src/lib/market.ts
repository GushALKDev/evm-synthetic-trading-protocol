// Market candles from Coinbase Exchange's public market data, which needs no key: the history from its REST candles and
// the candle in progress from its websocket ticker. They show where the market trades; the protocol executes at the
// Chainlink price, which the market bar shows.
import type { Candle, Timeframe } from './chart'

export const MARKET_REST = 'https://api.exchange.coinbase.com'
export const MARKET_WS = 'wss://ws-feed.exchange.coinbase.com'

/** Candle widths Coinbase serves (it rejects 4 h), each over 300 candles at most, the most one request returns */
export const MARKET_TIMEFRAMES: Timeframe[] = [
  { label: '1m', bucket: 60, horizon: 300 * 60 },
  { label: '5m', bucket: 300, horizon: 300 * 300 },
  { label: '15m', bucket: 900, horizon: 3 * 86_400 },
  { label: '1h', bucket: 3_600, horizon: 7 * 86_400 },
]

/** The Coinbase product of a pair symbol, quoted in USD like the Chainlink feeds */
export const productOf = (symbol: string) => `${symbol}-USD`

export function candlesUrl(product: string, timeframe: Timeframe, now: number): string {
  const end = Math.floor(now / timeframe.bucket) * timeframe.bucket + timeframe.bucket
  const start = end - timeframe.horizon
  const iso = (t: number) => new Date(t * 1000).toISOString()
  return `${MARKET_REST}/products/${product}/candles?granularity=${timeframe.bucket}&start=${iso(start)}&end=${iso(end)}`
}

/** Coinbase rows are [time, low, high, open, close, volume], newest first */
export function parseCandles(rows: unknown): Candle[] {
  if (!Array.isArray(rows)) throw new Error('Unexpected market candles response')
  return rows
    .map((r) => ({ time: Number(r[0]), low: Number(r[1]), high: Number(r[2]), open: Number(r[3]), close: Number(r[4]) }))
    .filter((c) => [c.time, c.low, c.high, c.open, c.close].every(Number.isFinite))
    .sort((a, b) => a.time - b.time)
}

/** Folds a trade at `price` into the candles: it extends the candle of its bucket, or opens the next one */
export function applyTick(candles: Candle[], price: number, time: number, bucket: number): Candle[] {
  const start = Math.floor(time / bucket) * bucket
  const last = candles[candles.length - 1]
  if (last && start < last.time) return candles
  if (last && start === last.time) {
    return [...candles.slice(0, -1), { ...last, high: Math.max(last.high, price), low: Math.min(last.low, price), close: price }]
  }
  return [...candles, { time: start, open: price, high: price, low: price, close: price }]
}

/**
 * A refreshed history with the live candles kept on top: the ticks seen since may be newer than the REST candles, so the
 * shared bucket keeps the widest range and the latest close, and later live buckets stay.
 */
export function mergeLive(history: Candle[], live: Candle[]): Candle[] {
  const last = history[history.length - 1]
  if (!last) return live
  const out = [...history]
  for (const c of live) {
    if (c.time < last.time) continue
    if (c.time === last.time) out[out.length - 1] = { ...last, high: Math.max(last.high, c.high), low: Math.min(last.low, c.low), close: c.close }
    else out.push(c)
  }
  return out
}
