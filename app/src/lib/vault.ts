// Vault math mirrored from Vault.sol, OpenPnlLib.sol, SolvencyManager.sol, BondDepository.sol and Solady's ERC4626
// (virtual shares with a decimals offset of 12). Same rounding as the contracts; scripts/parity.test.ts checks it.

import { BPS, WAD, USDC_TO_WAD } from './trading'

/** Vault._decimalsOffset: 1 USDC (6 decimals) mints 1e18 raw shares at a 1.0 share price */
export const SHARE_OFFSET = 10n ** 12n

// SolvencyManager thresholds (WAD, 1e18 == 100%)
export const SAFE_CR = 110n * 10n ** 16n
export const DEFICIT_CR = 100n * 10n ** 16n
export const CRITICAL_CR = 95n * 10n ** 16n

// Vault withdrawal timing
export const EPOCH_LENGTH = 86_400n
export const WITHDRAWAL_DELAY_EPOCHS = 3n
export const WITHDRAWAL_WINDOW_EPOCHS = 1n

/* ------------------------------------------------------------------ */
/* Open PnL (OpenPnlLib)                                               */
/* ------------------------------------------------------------------ */

export interface PairTotals {
  longSize: bigint
  longCollateral: bigint
  longQuantity: bigint
  shortSize: bigint
  shortCollateral: bigint
  shortQuantity: bigint
}

/** OpenPnlLib.quantity: rounded up for longs, down for shorts */
export function quantityOf(sizeWad: bigint, openPrice: bigint, isLong: boolean): bigint {
  const numerator = sizeWad * WAD
  return isLong ? (numerator + openPrice - 1n) / openPrice : numerator / openPrice
}

/** OpenPnlLib.sidePnl: 18 decimals, clamped at minus the side's collateral */
export function sidePnl(price: bigint, size: bigint, quantity: bigint, collateral: bigint, isLong: boolean): bigint {
  const product = price * quantity
  const pnl = isLong ? (product + WAD - 1n) / WAD - size : size - product / WAD
  const floor = -(collateral * USDC_TO_WAD)
  return pnl < floor ? floor : pnl
}

/** OpenPnlLib.pairPnl: the net trader PnL at the band edge that is highest for the traders */
export function pairPnl(price: bigint, conf: bigint, t: PairTotals): bigint {
  const low = conf >= price ? 0n : price - conf
  const high = price + conf
  const atLow = sidePnl(low, t.longSize, t.longQuantity, t.longCollateral, true) + sidePnl(low, t.shortSize, t.shortQuantity, t.shortCollateral, false)
  const atHigh = sidePnl(high, t.longSize, t.longQuantity, t.longCollateral, true) + sidePnl(high, t.shortSize, t.shortQuantity, t.shortCollateral, false)
  return atLow > atHigh ? atLow : atHigh
}

/** OpenPnlLib.toUsdcUp: toward +infinity for both signs */
export function toUsdcUp(wad: bigint): bigint {
  if (wad >= 0n) return (wad + USDC_TO_WAD - 1n) / USDC_TO_WAD
  return -(-wad / USDC_TO_WAD)
}

/** Vault._refreshPnlSnapshot: the net PnL a refresh would store, valuing every pair with open interest */
export function snapshotNetPnl(pairs: { totals: PairTotals; price: bigint; conf: bigint }[]): bigint {
  let net = 0n
  for (const p of pairs) {
    if (p.totals.longSize === 0n && p.totals.shortSize === 0n) continue
    net += pairPnl(p.price, p.conf, p.totals)
  }
  return toUsdcUp(net)
}

/* ------------------------------------------------------------------ */
/* NAV and ratios                                                      */
/* ------------------------------------------------------------------ */

/** Vault._openPnlLiability: the positive part of the snapshot, zero with no open trade */
export const openPnlLiability = (openTrades: bigint, netPnl: bigint) => (openTrades === 0n || netPnl <= 0n ? 0n : netPnl)

/** Vault.totalAssets: USDC balance minus the liability, floored at zero */
export const navOf = (balance: bigint, liability: bigint) => (balance > liability ? balance - liability : 0n)

/** Vault.collateralizationRatio (and the realised one with the balance in place of the NAV) */
export function ratioOf(assets: bigint, supply: bigint): bigint | null {
  if (supply === 0n) return null
  return (assets * SHARE_OFFSET * WAD) / supply
}

/** Vault.collateralizationDeficit: USDC needed to bring the ratio back to 100% */
export function deficitOf(assets: bigint, supply: bigint): bigint {
  const nominal = supply / SHARE_OFFSET
  return nominal > assets ? nominal - assets : 0n
}

/** Solady ERC4626.convertToShares (and previewDeposit) with the offset */
export const sharesForAssets = (assets: bigint, supply: bigint, totalAssets: bigint) => (assets * (supply + SHARE_OFFSET)) / (totalAssets + 1n)

/** Solady ERC4626.convertToAssets (and previewRedeem) with the offset */
export const assetsForShares = (shares: bigint, supply: bigint, totalAssets: bigint) => (shares * (totalAssets + 1n)) / (supply + SHARE_OFFSET)

/* ------------------------------------------------------------------ */
/* Solvency layers                                                     */
/* ------------------------------------------------------------------ */

/**
 * SolvencyManager._pendingInjection on a fresh snapshot: below a 100% NAV ratio the reserve covers as much of the
 * deficit as it holds. The deposit paths run it before minting, so a deposit is priced at the NAV after it.
 */
export function pendingInjection(nav: bigint, supply: bigint, reserve: bigint): bigint {
  const ratio = ratioOf(nav, supply)
  if (ratio === null || ratio >= DEFICIT_CR) return 0n
  const deficit = deficitOf(nav, supply)
  return reserve < deficit ? reserve : deficit
}

export type SolvencyLevel = 'healthy' | 'warning' | 'deficit' | 'critical'

/** The band SolvencyManager places a NAV ratio in; critical is judged on the realised ratio */
export function solvencyLevel(navRatio: bigint | null, realisedRatio: bigint | null): SolvencyLevel {
  if (realisedRatio !== null && realisedRatio < CRITICAL_CR) return 'critical'
  if (navRatio === null || navRatio >= SAFE_CR) return 'healthy'
  if (navRatio >= DEFICIT_CR) return 'warning'
  return 'deficit'
}

/* ------------------------------------------------------------------ */
/* Bonds                                                               */
/* ------------------------------------------------------------------ */

/** BondDepository.quoteBond: SYNTH (18 decimals) for USDC at the discounted reference price */
export function quoteBond(usdc: bigint, referencePrice: bigint, discountBps: bigint): bigint {
  const effective = (referencePrice * (BPS - discountBps)) / BPS
  return effective === 0n ? 0n : (usdc * WAD) / effective
}

/** bond's clamp: the most a call can take, min(remainingCap, realised deficit) */
export const bondCapacity = (remainingCap: bigint, realisedDeficit: bigint) => (realisedDeficit < remainingCap ? realisedDeficit : remainingCap)

/** Withdrawal epochs */
export const epochAt = (time: bigint, deployTimestamp: bigint) => (time - deployTimestamp) / EPOCH_LENGTH
export const epochStart = (epoch: bigint, deployTimestamp: bigint) => deployTimestamp + epoch * EPOCH_LENGTH
