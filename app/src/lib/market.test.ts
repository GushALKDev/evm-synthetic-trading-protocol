import { describe, expect, it } from 'vitest'
import { applyTick, candlesUrl, mergeLive, oracleSteps, parseCandles } from './market'

const c = (time: number, open: number, high: number, low: number, close: number) => ({ time, open, high, low, close })

describe('market candles', () => {
  it('reads Coinbase rows, newest first and in [time, low, high, open, close, volume] order, oldest first', () => {
    const rows = [
      [120, 9, 12, 10, 11, 1.5],
      [60, 8, 11, 9, 10, 2],
    ]
    expect(parseCandles(rows)).toEqual([c(60, 9, 11, 8, 10), c(120, 10, 12, 9, 11)])
    expect(() => parseCandles({ message: 'Unsupported granularity' })).toThrow()
  })

  it('asks for the horizon up to the end of the bucket in progress', () => {
    // 1_000_030 sits in the bucket from 1_000_020, which ends at 1_000_080; 300 one-minute candles start 18_000 s earlier
    const url = new URL(candlesUrl('BTC-USD', { label: '1m', bucket: 60, horizon: 300 * 60 }, 1_000_030))
    expect(url.pathname).toBe('/products/BTC-USD/candles')
    expect(url.searchParams.get('granularity')).toBe('60')
    expect(Date.parse(url.searchParams.get('end')!) / 1000).toBe(1_000_080)
    expect(Date.parse(url.searchParams.get('start')!) / 1000).toBe(982_080)
  })

  it('extends the candle in progress with a trade, and opens the next bucket at the trade price', () => {
    const base = [c(60, 10, 11, 9, 10)]
    expect(applyTick(base, 12, 100, 60)).toEqual([c(60, 10, 12, 9, 12)])
    expect(applyTick(base, 8, 119, 60)).toEqual([c(60, 10, 11, 8, 8)])
    expect(applyTick(base, 13, 120, 60)).toEqual([c(60, 10, 11, 9, 10), c(120, 13, 13, 13, 13)])
    // A late trade for a closed bucket changes nothing
    expect(applyTick([c(60, 10, 11, 9, 10), c(120, 13, 13, 13, 13)], 1, 70, 60)).toHaveLength(2)
  })

  it('keeps the live candles on top of a refreshed history', () => {
    const history = [c(60, 10, 11, 9, 10), c(120, 10, 12, 10, 11)]
    const live = [c(60, 10, 11, 9, 10), c(120, 10, 13, 10, 12.5), c(180, 12.5, 12.6, 12.4, 12.6)]
    expect(mergeLive(history, live)).toEqual([c(60, 10, 11, 9, 10), c(120, 10, 13, 10, 12.5), c(180, 12.5, 12.6, 12.4, 12.6)])
    expect(mergeLive(history, [])).toEqual(history)
  })

  it('draws the oracle price at each market candle that has one', () => {
    const oracle = [c(60, 10, 10, 10, 10), c(120, 10, 10.5, 10, 10.5)]
    const market = [c(0, 1, 1, 1, 1), c(60, 1, 1, 1, 1), c(120, 1, 1, 1, 1)]
    expect(oracleSteps(oracle, market)).toEqual([
      { time: 60, value: 10 },
      { time: 120, value: 10.5 },
    ])
  })
})
