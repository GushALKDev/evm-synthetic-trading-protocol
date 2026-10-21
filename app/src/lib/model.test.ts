import { describe, expect, it } from 'vitest'
import type { ConfigData, LiveData } from '../hooks/useProtocolData'
import { buildVault } from './model'

const E6 = 10n ** 6n
const E18 = 10n ** 18n

const config = {
  pairs: [],
  spread: { baseSpreadBps: 5n, impactFactor: 300_000n, volFactor: 100n, maxSpreadBps: 100n },
  fundingFactor: 10n ** 14n,
  maxPriceAge: 30n,
  updateFee: 1n,
  confBps: 5n,
  deployTimestamp: 1_800_000_000n,
  maxSnapshotAge: 60n,
  reserveTargetCap: 1_000_000n * E6,
  referencePrice: 2n * E6,
  discountBps: 500n,
  vestingPeriod: 172_800n,
} as ConfigData

/** 1M shares outstanding, 940,000 USDC in the vault: a 94% realised ratio, with a snapshot taken long ago */
function live(reserve: bigint, remainingCap = 0n): LiveData {
  return {
    pairs: [],
    enginePauseFlags: 0,
    vaultPauseFlags: 0,
    vaultBalance: 940_000n * E6,
    supply: 1_000_000n * E18,
    snapshot: { netPnl: 0n, timestamp: 1_800_000_000n, nonce: 3n },
    openTrades: 4n,
    positionsNonce: 4n,
    tradeCounter: 4n,
    reserveBalance: reserve,
    remainingCap,
  }
}

describe('bonding round, as the deposit will see it', () => {
  it('lets a deposit through when the reserve top-up it runs first covers the deficit', () => {
    // Regression: the app took SolvencyManager.bondingRoundOpenAfterCheck, which counts no injection while the snapshot
    // is stale and reported this round as due, and closed deposits that refreshAndDeposit accepts after injecting 60,000
    const v = buildVault(config, live(100_000n * E6), [], 1_800_100_000n)
    expect(v.pendingInjection).toBe(60_000n * E6)
    expect(v.roundDue).toBe(false)
  })

  it('keeps deposits closed when the reserve falls short, or while a round is open below 100%', () => {
    expect(buildVault(config, live(10_000n * E6), [], 1_800_100_000n).roundDue).toBe(true)
    expect(buildVault(config, { ...live(100_000n * E6, 1n), vaultBalance: 990_000n * E6 }, [], 1_800_100_000n).roundDue).toBe(true)
    expect(buildVault(config, { ...live(0n), vaultBalance: 960_000n * E6 }, [], 1_800_100_000n).roundDue).toBe(false)
  })
})
