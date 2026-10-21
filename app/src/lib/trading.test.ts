import { describe, expect, it } from 'vitest'
import {
  applySpread,
  closeOutcome,
  feeOf,
  fundingIndexDeltas,
  fundingOwedOf,
  fundingRates,
  levelError,
  limitOutcome,
  limitTriggered,
  liquidationAnswer,
  liquidationCheck,
  liquidatorReward,
  payoutOf,
  pnlOf,
  positionSizeWad,
  projectFundingIndexes,
  quoteOpen,
  spreadBps,
  splitFee,
  withinSlippage,
  type Position,
} from './trading'
import { mirroredPrice } from './pyth'

const E18 = 10n ** 18n
const E6 = 10n ** 6n
// The parameters of script/Deploy.s.sol
const spreadParams = { baseSpreadBps: 5n, impactFactor: 300_000n, volFactor: 100n, maxSpreadBps: 100n }

describe('spread', () => {
  it('adds the OI and volatility terms and caps the total', () => {
    expect(spreadBps(spreadParams, 0n, 0n)).toBe(5n)
    // 3 bps at 10M of open interest, 3 bps at 3% volatility
    expect(spreadBps(spreadParams, 0n, 10_000_000n * E18)).toBe(8n)
    expect(spreadBps(spreadParams, 3n * 10n ** 16n, 10_000_000n * E18)).toBe(11n)
    expect(spreadBps(spreadParams, 0n, 10n ** 40n)).toBe(100n)
  })

  it('moves long opens and short closes up, the other two down', () => {
    const p = 100_000n * E18
    expect(applySpread(p, true, true, 5n)).toBe(100_050n * E18)
    expect(applySpread(p, false, false, 5n)).toBe(100_050n * E18)
    expect(applySpread(p, true, false, 5n)).toBe(99_950n * E18)
    expect(applySpread(p, false, true, 5n)).toBe(99_950n * E18)
  })
})

describe('fees and size', () => {
  it('matches the seed trade of the deploy rehearsal', () => {
    // 40,000 USDC at 5x: 0.08% of 200,000 notional
    const fee = feeOf(40_000n * E6, 5n, 8n)
    expect(fee).toBe(160n * E6)
    expect(positionSizeWad(40_000n * E6 - fee, 5n)).toBe(199_200n * E18)
  })

  it('splits 80% to the Vault and the remainder to the treasury', () => {
    expect(splitFee(101n)).toEqual({ vault: 80n, treasury: 21n })
  })
})

describe('PnL and payout', () => {
  it('rounds the exit value against the trader on both sides', () => {
    // Exact PnL would be -1/3 for the long and +1/3 for the short
    expect(pnlOf(1n, 1n, 3n, 2n, true)).toBe(-1n)
    expect(pnlOf(1n, 1n, 3n, 2n, false)).toBe(0n)
  })

  it('caps price PnL at 8x collateral and settles funding after the cap', () => {
    expect(payoutOf(100n, 10_000n, 0n)).toBe(900n)
    expect(payoutOf(100n, 10_000n, 50n)).toBe(850n)
    expect(payoutOf(100n, 10_000n, -50n)).toBe(950n)
    expect(payoutOf(100n, -150n, 0n)).toBe(0n)
  })

  it('caps the close fee to the payout', () => {
    const p: Position = { isLong: true, collateral: 1_000n * E6, leverage: 100n, openPrice: 100n * E18, tp: 0n, sl: 0n }
    // A full loss: nothing to pay, no fee taken
    const out = closeOutcome(p, 98n * E18, 5n, 0n)
    expect(out.payout).toBe(0n)
    expect(out.closeFee).toBe(0n)
  })

  it('checks slippage against the expected price', () => {
    expect(withinSlippage(1_005n, 1_000n, 50n)).toBe(true)
    expect(withinSlippage(1_006n, 1_000n, 50n)).toBe(false)
  })
})

describe('funding', () => {
  it('charges the heavy side and credits the light side no more than it pays', () => {
    const [long, short] = fundingIndexDeltas(200n * E18, 100n * E18, 3_600n, 10n ** 14n)
    expect(long).toBe(33_333_333_333_333n)
    expect(short).toBe(-66_666_666_666_666n)
    expect(fundingIndexDeltas(100n * E18, 100n * E18, 3_600n, 10n ** 14n)).toEqual([0n, 0n])
    expect(fundingIndexDeltas(0n, 100n * E18, 3_600n, 10n ** 14n)).toEqual([0n, 0n])
  })

  it('rounds the payer up and the receiver down', () => {
    // 1 USD of notional and the smallest index step: a payer owes one base unit, a receiver gets nothing
    expect(fundingOwedOf(E18, 1n, 0n)).toBe(1n)
    expect(fundingOwedOf(E18, -1n, 0n)).toBe(0n)
    // 10,000 USD at 0.01%: 1 USDC either way
    expect(fundingOwedOf(10n ** 22n, 10n ** 14n, 0n)).toBe(1_000_000n)
    expect(fundingOwedOf(10n ** 22n, -(10n ** 14n), 0n)).toBe(-1_000_000n)
  })

  it('caps the rate at 0.01% per hour and reports both sides', () => {
    expect(fundingRates(1_000n * E18, 1n * E18, 10n ** 15n)).toEqual({ long: 10n ** 14n, short: -(10n ** 14n * 1_000n) })
  })

  it('projects one interval from the last update, never behind it, and keeps an untouched pair at zero', () => {
    const s = { oiLong: 200n * E18, oiShort: 100n * E18, longIndex: 7n, shortIndex: -7n, lastUpdated: 1_000n }
    expect(projectFundingIndexes(s, 999n, 10n ** 14n)).toEqual({ long: 7n, short: -7n })
    expect(projectFundingIndexes(s, 4_600n, 10n ** 14n)).toEqual({ long: 7n + 33_333_333_333_333n, short: -7n - 66_666_666_666_666n })
    expect(projectFundingIndexes({ ...s, lastUpdated: 0n }, 4_600n, 10n ** 14n)).toEqual({ long: 7n, short: -7n })
  })
})

describe('liquidation', () => {
  const long: Position = { isLong: true, collateral: 1_000n * E6, leverage: 10n, openPrice: 100_050n * E18, tp: 0n, sl: 0n }

  it('pays 10% of what is left, at least 0.5% of collateral', () => {
    expect(liquidatorReward(1_000n * E6, 950n * E6)).toBe(5n * E6)
    expect(liquidatorReward(1_000n * E6, 900n * E6)).toBe(10n * E6)
    expect(liquidatorReward(1_000n * E6, 2_000n * E6)).toBe(5n * E6)
  })

  it('uses the band edge that favours the trader', () => {
    const { price, conf } = mirroredPrice(90_900n * 10n ** 8n, 8, 5n)
    const withBand = liquidationCheck(long, price, conf, 5n, 0n)
    const withoutBand = liquidationCheck(long, price, 0n, 5n, 0n)
    expect(withBand.loss < withoutBand.loss).toBe(true)
  })

  it('finds the first answer at which liquidate succeeds', () => {
    const answer = liquidationAnswer(long, 0n, 5n, 8, 5n, 100_000n * 10n ** 8n)!
    const at = (a: bigint) => {
      const { price, conf } = mirroredPrice(a, 8, 5n)
      return liquidationCheck(long, price, conf, 5n, 0n).liquidatable
    }
    expect(at(answer)).toBe(true)
    expect(at(answer + 1n)).toBe(false)
    // Roughly 9% below entry at 10x
    expect(answer > 90_900n * 10n ** 8n && answer < 91_200n * 10n ** 8n).toBe(true)

    const short = { ...long, isLong: false, openPrice: 99_950n * E18 }
    const shortAnswer = liquidationAnswer(short, 0n, 5n, 8, 5n, 100_000n * 10n ** 8n)!
    const atShort = (a: bigint) => {
      const { price, conf } = mirroredPrice(a, 8, 5n)
      return liquidationCheck(short, price, conf, 5n, 0n).liquidatable
    }
    expect(atShort(shortAnswer)).toBe(true)
    expect(atShort(shortAnswer - 1n)).toBe(false)
  })
})

describe('limits', () => {
  const p: Position = { isLong: true, collateral: 1_000n * E6, leverage: 10n, openPrice: 100n * E18, tp: 110n * E18, sl: 95n * E18 }

  it('checks TP before SL, with inclusive bounds', () => {
    expect(limitTriggered(p, 110n * E18)).toBe('tp')
    expect(limitTriggered(p, 95n * E18)).toBe('sl')
    expect(limitTriggered(p, 100n * E18)).toBe(null)
    expect(limitTriggered({ ...p, isLong: false, tp: 90n * E18, sl: 105n * E18 }, 105n * E18)).toBe('sl')
  })

  it('carves the 0.1% executor reward out of the payout', () => {
    const out = limitOutcome(p, 110n * E18, 5n, 0n)
    expect(out.executorReward).toBe(10n * E6)
    expect(out.traderPayout).toBe(out.payout - 10n * E6)
  })
})

describe('updating levels', () => {
  const long: Position = { isLong: true, collateral: 1_000n * E6, leverage: 10n, openPrice: 100n * E18, tp: 0n, sl: 0n }

  it('checks the oracle price first, then the entry price, and lets a level be cleared', () => {
    expect(levelError(long, 'tp', 105n * E18, 106n * E18)).toMatch(/current price/)
    expect(levelError(long, 'tp', 99n * E18, 98n * E18)).toMatch(/entry price/)
    expect(levelError(long, 'tp', 110n * E18, 102n * E18)).toBe(undefined)
    // In profit, a stop above the entry is still refused: storage checks it against the entry price
    expect(levelError(long, 'sl', 101n * E18, 105n * E18)).toMatch(/entry price/)
    expect(levelError(long, 'sl', 0n, 105n * E18)).toBe(undefined)
    expect(levelError({ ...long, isLong: false }, 'sl', 99n * E18, 98n * E18)).toMatch(/entry price/)
  })
})

describe('open quote', () => {
  const spreadAt = (oi: bigint) => spreadBps(spreadParams, 0n, oi)

  it('rejects a position the spread alone would liquidate', () => {
    const tight = quoteOpen({ isLong: true, collateral: 100n * E6, leverage: 100n, tp: 0n, sl: 0n }, 100n * E18, spreadAt, 0n, 10n ** 30n)
    expect(tight.preLiquidatable).toBe(false)
    const wide = quoteOpen({ isLong: true, collateral: 100n * E6, leverage: 100n, tp: 0n, sl: 0n }, 100n * E18, () => 100n, 0n, 10n ** 30n)
    expect(wide.preLiquidatable).toBe(true)
  })

  it('applies the engine and storage TP/SL checks', () => {
    const q = (tp: bigint, sl: bigint) =>
      quoteOpen({ isLong: true, collateral: 100n * E6, leverage: 10n, tp, sl }, 100n * E18, spreadAt, 0n, 10n ** 30n)
    // Above the oracle price but not above the entry price, which includes the spread
    expect(q(100_02n * 10n ** 16n, 0n).tpError).toMatch(/entry price/)
    expect(q(99n * E18, 0n).tpError).toMatch(/current price/)
    expect(q(0n, 100n * E18).slError).toMatch(/current price/)
    expect(q(110n * E18, 90n * E18)).toMatchObject({ tpError: undefined, slError: undefined })
  })

  it('flags the max open interest', () => {
    const quote = quoteOpen({ isLong: true, collateral: 100n * E6, leverage: 10n, tp: 0n, sl: 0n }, 100n * E18, spreadAt, 0n, 500n * E18)
    expect(quote.exceedsMaxOI).toBe(true)
  })
})
