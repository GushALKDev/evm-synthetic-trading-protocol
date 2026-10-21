import { describe, expect, it } from 'vitest'
import { decodeAbiParameters, encodeErrorResult, ContractFunctionRevertedError, type Hex } from 'viem'
import { buildPriceUpdate, mirroredPrice } from './pyth'
import {
  assetsForShares,
  bondCapacity,
  deficitOf,
  navOf,
  openPnlLiability,
  pairPnl,
  pendingInjection,
  quantityOf,
  quoteBond,
  ratioOf,
  sharesForAssets,
  sidePnl,
  snapshotNetPnl,
  solvencyLevel,
  toUsdcUp,
} from './vault'
import { describeError, noErrorContext } from './errors'
import { engineAbi } from './abi'
import { formatFixed, formatSigned, parseAmount, relativeTime, toInput } from './format'

const E18 = 10n ** 18n
const E6 = 10n ** 6n

describe('open PnL', () => {
  it('rounds quantity up for longs and down for shorts', () => {
    expect(quantityOf(10n * E18, 3n * E18, true)).toBe(3_333_333_333_333_333_334n)
    expect(quantityOf(10n * E18, 3n * E18, false)).toBe(3_333_333_333_333_333_333n)
  })

  it('clamps a side at minus its collateral', () => {
    // 1,000 USD long of 10 units, price to zero: the loss stops at the 100 USDC of collateral
    expect(sidePnl(0n, 1_000n * E18, 10n * E18, 100n * E6, true)).toBe(-100n * E18)
  })

  it('takes the band edge that is highest for the traders', () => {
    const totals = { longSize: 1_000n * E18, longCollateral: 100n * E6, longQuantity: 10n * E18, shortSize: 0n, shortCollateral: 0n, shortQuantity: 0n }
    // Long only: the high edge, 101 per unit
    expect(pairPnl(100n * E18, 1n * E18, totals)).toBe(10n * E18)
  })

  it('converts to USDC toward plus infinity', () => {
    expect(toUsdcUp(1n)).toBe(1n)
    expect(toUsdcUp(-1n)).toBe(0n)
    expect(toUsdcUp(-(10n ** 12n) - 1n)).toBe(-1n)
  })

  it('skips pairs with no open interest', () => {
    const empty = { longSize: 0n, longCollateral: 0n, longQuantity: 0n, shortSize: 0n, shortCollateral: 0n, shortQuantity: 0n }
    expect(snapshotNetPnl([{ totals: empty, price: 0n, conf: 0n }])).toBe(0n)
  })
})

describe('NAV and shares', () => {
  it('subtracts only positive open PnL, and only with open trades', () => {
    expect(openPnlLiability(0n, 500n)).toBe(0n)
    expect(openPnlLiability(3n, -500n)).toBe(0n)
    expect(openPnlLiability(3n, 500n)).toBe(500n)
    expect(navOf(1_000n, 1_500n)).toBe(0n)
  })

  it('reports ratios and the deficit against 1.0 per share', () => {
    const supply = 1_000_000n * E18
    expect(ratioOf(1_000_000n * E6, supply)).toBe(E18)
    expect(ratioOf(950_000n * E6, supply)).toBe(95n * 10n ** 16n)
    expect(ratioOf(1n, 0n)).toBe(null)
    expect(deficitOf(950_000n * E6, supply)).toBe(50_000n * E6)
  })

  it('mints and redeems with Solady virtual shares and a 12-decimal offset', () => {
    const supply = 1_000_000n * E18
    const assets = 1_000_320n * E6
    const shares = sharesForAssets(5_000n * E6, supply, assets)
    expect(shares).toBe((5_000n * E6 * (supply + 10n ** 12n)) / (assets + 1n))
    expect(assetsForShares(shares, supply + shares, assets + 5_000n * E6) <= 5_000n * E6).toBe(true)
  })

  it('injects the reserve before a deposit only below a 100% NAV ratio, up to the deficit', () => {
    const supply = 1_000_000n * E18
    expect(pendingInjection(1_000_000n * E6, supply, 5_000n * E6)).toBe(0n)
    expect(pendingInjection(997_969n * E6, supply, 116n * E6)).toBe(116n * E6)
    expect(pendingInjection(999_900n * E6, supply, 5_000n * E6)).toBe(100n * E6)
    expect(pendingInjection(1n, 0n, 5_000n * E6)).toBe(0n)
  })

  it('places the ratios in the solvency bands', () => {
    expect(solvencyLevel(115n * 10n ** 16n, 115n * 10n ** 16n)).toBe('healthy')
    expect(solvencyLevel(105n * 10n ** 16n, 105n * 10n ** 16n)).toBe('warning')
    expect(solvencyLevel(98n * 10n ** 16n, 99n * 10n ** 16n)).toBe('deficit')
    expect(solvencyLevel(90n * 10n ** 16n, 94n * 10n ** 16n)).toBe('critical')
  })
})

describe('bonds', () => {
  it('quotes at the reference price less the discount, clamped to the round', () => {
    expect(quoteBond(10_000n * E6, 2n * E6, 500n)).toBe(5_263_157_894_736_842_105_263n)
    expect(bondCapacity(100n, 40n)).toBe(40n)
  })
})

describe('price update', () => {
  it('encodes the Chainlink answer with 5 bps of confidence and the given publish time', () => {
    const id = `0x${'11'.repeat(32)}` as Hex
    const [entry] = buildPriceUpdate([{ pythFeedId: id, answer: 2_000_12345678n, decimals: 8 }], 5n, 1_800_000_000n)
    const [feed] = decodeAbiParameters(
      [
        {
          type: 'tuple',
          components: [
            { name: 'id', type: 'bytes32' },
            { name: 'price', type: 'tuple', components: [{ name: 'price', type: 'int64' }, { name: 'conf', type: 'uint64' }, { name: 'expo', type: 'int32' }, { name: 'publishTime', type: 'uint256' }] },
            { name: 'emaPrice', type: 'tuple', components: [{ name: 'price', type: 'int64' }, { name: 'conf', type: 'uint64' }, { name: 'expo', type: 'int32' }, { name: 'publishTime', type: 'uint256' }] },
          ],
        },
      ],
      entry,
    )
    expect(feed.id).toBe(id)
    expect(feed.price).toEqual({ price: 2_000_12345678n, conf: 100_006172n, expo: -8, publishTime: 1_800_000_000n })
    expect(mirroredPrice(2_000_12345678n, 8, 5n)).toEqual({ price: 2_000_12345678n * 10n ** 10n, conf: 100_006172n * 10n ** 10n })
  })
})

describe('error sentences', () => {
  const revert = (errorName: string, args: readonly unknown[]) =>
    new ContractFunctionRevertedError({
      abi: engineAbi as never,
      functionName: 'openTrade',
      data: encodeErrorResult({ abi: engineAbi as never, errorName, args } as never),
    })

  it('names the Chainlink move for a refused mirror', () => {
    const err = revert('PriceNotChainlinkAnswer', [`0x${'22'.repeat(32)}`, 1n, 2n])
    expect(describeError(err, { ...noErrorContext, pairOfFeedId: () => 'ETH/USD' })).toBe(
      'Chainlink published a new ETH/USD price while the transaction was pending, so the Pyth stand-in refused the old one. Try again.',
    )
  })

  it('tells the pre-liquidation guard apart from a failed liquidation', () => {
    expect(describeError(revert('NotLiquidatable', [0n, 95n * E6, 90n * E6]), noErrorContext)).toMatch(/Lower the leverage/)
    expect(describeError(revert('NotLiquidatable', [7n, 10n * E6, 90n * E6]), noErrorContext)).toMatch(/Trade #7 is not liquidatable/)
  })

  it('reports the age of a stale price', () => {
    const err = revert('StalePrice', [`0x${'33'.repeat(32)}`, 100n, 140n])
    expect(describeError(err, noErrorContext)).toMatch(/40 s old/)
  })
})

describe('format', () => {
  it('truncates toward zero and parses amounts', () => {
    expect(formatFixed(1_999_999n, 6, 2)).toBe('1.99')
    expect(formatFixed(-1_999_999n, 6, 2)).toBe('-1.99')
    expect(formatSigned(12_300_000n, 6, 2)).toBe('+12.30')
    expect(parseAmount('1,000.5', 6)).toBe(1_000_500_000n)
    expect(parseAmount('1.0000001', 6)).toBe(null)
    expect(toInput(1_000_500_000n, 6)).toBe('1000.5')
  })

  it('truncates durations instead of rounding them up to the next unit', () => {
    // 2 days, 23 hours and 59 minutes was shown as "2 d 24 h"
    expect(relativeTime(3 * 86_400 - 60)).toBe('2 d 23 h')
    expect(relativeTime(3_599)).toBe('59 min')
    expect(relativeTime(7_199)).toBe('1 h 59 min')
  })
})

describe('retries before signing', () => {
  const revert = (errorName: string, args: readonly unknown[]) =>
    new ContractFunctionRevertedError({ abi: engineAbi as never, functionName: 'openTrade', data: encodeErrorResult({ abi: engineAbi as never, errorName, args } as never) })

  it('retries only the price reverts a fresh build can clear', async () => {
    const { isTransientPriceError } = await import('../hooks/useTx')
    expect(isTransientPriceError(revert('PriceNotChainlinkAnswer', [`0x${'22'.repeat(32)}`, 1n, 2n]))).toBe(true)
    expect(isTransientPriceError(revert('FuturePublishTime', [`0x${'22'.repeat(32)}`, 2n, 1n]))).toBe(true)
    expect(isTransientPriceError(revert('NotLiquidatable', [7n, 1n, 2n]))).toBe(false)
    expect(isTransientPriceError(new Error('x'))).toBe(false)
  })
})
