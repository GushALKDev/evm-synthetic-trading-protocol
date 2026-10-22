import { describe, expect, it } from 'vitest'
import { candlesFromRounds, change24h, orderedRounds } from './chart'

const r = (price: number, at: number) => ({ answer: BigInt(Math.round(price * 1e8)), updatedAt: BigInt(at) })

describe('oracle candles', () => {
  it('orders rounds by time and keeps one per timestamp', () => {
    // A test can move a round's time into the past, so rounds arrive out of order
    const ordered = orderedRounds([r(3, 300), r(1, 100), r(2, 200), r(2.5, 200), r(0, 400)])
    expect(ordered.map((x) => Number(x.updatedAt))).toEqual([100, 200, 300])
    expect(Number(ordered[1].answer)).toBe(2.5e8)
  })

  it('opens each candle at the previous close, with high and low over the rounds in it', () => {
    const candles = candlesFromRounds([r(100, 50), r(102, 120), r(99, 150), r(101, 260)], 8, 100, 100, 299)
    expect(candles).toEqual([
      { time: 100, open: 100, high: 102, low: 99, close: 99 },
      { time: 200, open: 99, high: 101, low: 99, close: 101 },
    ])
  })

  it('draws a bucket with no round as a flat candle at the last price', () => {
    const candles = candlesFromRounds([r(100, 50), r(105, 130)], 8, 100, 100, 399)
    expect(candles.slice(1)).toEqual([
      { time: 200, open: 105, high: 105, low: 105, close: 105 },
      { time: 300, open: 105, high: 105, low: 105, close: 105 },
    ])
  })

  it('leaves out buckets before the first round when none precedes the window', () => {
    const candles = candlesFromRounds([r(100, 250)], 8, 100, 0, 299)
    expect(candles).toEqual([{ time: 200, open: 100, high: 100, low: 100, close: 100 }])
  })

  it('measures the change from the price in force 24 hours ago', () => {
    const now = 1_000_000
    expect(change24h([r(100, now - 90_000), r(110, now - 1_000)], now)).toBeCloseTo(0.1)
    expect(change24h([r(110, now - 1_000)], now)).toBe(null)
  })
})
