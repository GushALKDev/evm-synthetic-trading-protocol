// Candles from Chainlink rounds, the prices the protocol executes at. A feed publishes a round when the price moves past
// its deviation threshold or its heartbeat passes, so a candle can hold several rounds or none.

export interface OracleRound {
  answer: bigint
  updatedAt: bigint
}

export interface Candle {
  /** Bucket start, unix seconds */
  time: number
  open: number
  high: number
  low: number
  close: number
}

export interface Timeframe {
  label: string
  /** Candle width, seconds */
  bucket: number
  /** How far back the chart reads rounds, seconds */
  horizon: number
}

export const TIMEFRAMES: Timeframe[] = [
  { label: '15m', bucket: 900, horizon: 86_400 },
  { label: '1h', bucket: 3_600, horizon: 3 * 86_400 },
  { label: '4h', bucket: 14_400, horizon: 7 * 86_400 },
]

const priceOf = (answer: bigint, decimals: number) => Number(answer) / 10 ** decimals

/** Rounds by time, one per timestamp (the later round wins), with no zero or negative answer */
export function orderedRounds(rounds: OracleRound[]): OracleRound[] {
  const byTime = new Map<bigint, OracleRound>()
  for (const r of rounds) if (r.answer > 0n && r.updatedAt > 0n) byTime.set(r.updatedAt, r)
  return [...byTime.values()].sort((a, b) => (a.updatedAt < b.updatedAt ? -1 : 1))
}

/**
 * One candle per bucket from `from` to `until`. Each candle opens at the previous close, so the series is continuous; a
 * bucket with no round is a flat candle at the last price, since the oracle price did not change in it. The round in
 * force at `from` (the last one before it) opens the first candle; buckets before the first round are left out.
 */
export function candlesFromRounds(rounds: OracleRound[], decimals: number, bucket: number, from: number, until: number): Candle[] {
  const ordered = orderedRounds(rounds)
  const candles: Candle[] = []
  let last: number | null = null
  let i = 0
  // The price in force when the window opens
  while (i < ordered.length && Number(ordered[i].updatedAt) < from) {
    last = priceOf(ordered[i].answer, decimals)
    i++
  }
  for (let start = Math.floor(from / bucket) * bucket; start <= until; start += bucket) {
    const end = start + bucket
    const inBucket: number[] = []
    while (i < ordered.length && Number(ordered[i].updatedAt) < end) {
      inBucket.push(priceOf(ordered[i].answer, decimals))
      i++
    }
    if (last === null && inBucket.length === 0) continue
    const open = last ?? inBucket[0]
    const close = inBucket.length > 0 ? inBucket[inBucket.length - 1] : open
    candles.push({ time: start, open, high: Math.max(open, ...inBucket), low: Math.min(open, ...inBucket), close })
    last = close
  }
  return candles
}

/** Fractional change from the price in force 24 h before `now` to the latest one; null without a round that old */
export function change24h(rounds: OracleRound[], now: number): number | null {
  const ordered = orderedRounds(rounds)
  if (ordered.length === 0) return null
  const dayAgo = now - 86_400
  let before: OracleRound | null = null
  for (const r of ordered) {
    if (Number(r.updatedAt) <= dayAgo) before = r
    else break
  }
  if (!before) return null
  const latest = ordered[ordered.length - 1]
  return Number(latest.answer - before.answer) / Number(before.answer)
}
