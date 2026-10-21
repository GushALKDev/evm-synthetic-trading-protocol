// Trading math mirrored from TradingEngine.sol, SpreadManager.sol and FundingLib.sol: same scales, same
// rounding, same order of operations. scripts/parity.test.ts checks it against a local deployment to the wei.
// Prices are 18 decimals, collateral and payouts are USDC (6 decimals), sizes and open interest are 18 decimals.

export const BPS = 10_000n
export const WAD = 10n ** 18n
/** USDC (6 decimals) to an 18-decimal USD amount */
export const USDC_TO_WAD = 10n ** 12n

// TradingEngine constants
export const MAX_PROFIT_MULTIPLIER = 9n
export const MAX_LEVERAGE = 100n
export const MIN_COLLATERAL = 10_000_000n
export const OPEN_FEE_BPS = 8n
export const CLOSE_FEE_BPS = 8n
export const FEE_VAULT_SPLIT_BPS = 8_000n
export const LIQUIDATION_THRESHOLD_BPS = 9_000n
export const LIQUIDATOR_REWARD_BPS = 1_000n
export const LIQUIDATOR_MIN_REWARD_BPS = 50n
export const EXEC_REWARD_BPS = 10n
export const PAUSE_OPEN = 1
export const PAUSE_SETTLE = 2

// SpreadManager precision
export const OI_PRECISION = 10n ** 30n
export const VOL_PRECISION = 10n ** 18n

// FundingLib
export const SECONDS_PER_HOUR = 3_600n
export const INDEX_TO_USDC = 10n ** 30n
export const MAX_FUNDING_RATE_PER_HOUR = 10n ** 14n

export const ceilDiv = (a: bigint, b: bigint) => (a === 0n ? 0n : (a - 1n) / b + 1n)

/* ------------------------------------------------------------------ */
/* Spread                                                              */
/* ------------------------------------------------------------------ */

export interface SpreadParams {
  baseSpreadBps: bigint
  impactFactor: bigint
  volFactor: bigint
  maxSpreadBps: bigint
}

/** SpreadManager.getSpreadBps: base + OI impact + volatility impact, capped */
export function spreadBps(p: SpreadParams, volatility: bigint, openInterest: bigint): bigint {
  const oiImpact = (openInterest * p.impactFactor) / OI_PRECISION
  const volImpact = (volatility * p.volFactor) / VOL_PRECISION
  const spread = p.baseSpreadBps + oiImpact + volImpact
  return spread > p.maxSpreadBps ? p.maxSpreadBps : spread
}

/** TradingEngine._applySpreadAtOI: long open and short close move the price up, the other two down */
export function applySpread(price: bigint, isLong: boolean, isOpen: boolean, spread: bigint): bigint {
  const up = (isLong && isOpen) || (!isLong && !isOpen)
  return up ? (price * (BPS + spread)) / BPS : (price * (BPS - spread)) / BPS
}

/* ------------------------------------------------------------------ */
/* Fees, size, PnL, payout                                             */
/* ------------------------------------------------------------------ */

/** TradingEngine._calculateFee: bps of the notional (collateral times leverage) */
export const feeOf = (collateral: bigint, leverage: bigint, feeBps: bigint) => (collateral * leverage * feeBps) / BPS

/** TradingEngine._positionSizeWad */
export const positionSizeWad = (collateral: bigint, leverage: bigint) => collateral * leverage * USDC_TO_WAD

/** Fee split of TradingEngine._distributeFees: 80% to the Vault, the rest to the treasury */
export function splitFee(fee: bigint): { vault: bigint; treasury: bigint } {
  const vault = (fee * FEE_VAULT_SPLIT_BPS) / BPS
  return { vault, treasury: fee - vault }
}

/** TradingEngine._calculatePnl: longs floor the exit value, shorts ceil it, so rounding favours the pool */
export function pnlOf(collateral: bigint, leverage: bigint, openPrice: bigint, closePrice: bigint, isLong: boolean): bigint {
  const size = collateral * leverage
  if (isLong) return (closePrice * size) / openPrice - size
  return size - (closePrice * size + openPrice - 1n) / openPrice
}

/** TradingEngine._calculatePayout: price PnL capped at 8x collateral, funding settled after the cap */
export function payoutOf(collateral: bigint, pnl: bigint, fundingOwed: bigint): bigint {
  const maxProfit = collateral * (MAX_PROFIT_MULTIPLIER - 1n)
  const capped = pnl > maxProfit ? maxProfit : pnl
  const net = collateral + capped - fundingOwed
  return net > 0n ? net : 0n
}

/** TradingEngine._validateSlippage */
export function withinSlippage(executionPrice: bigint, expectedPrice: bigint, slippageBps: bigint): boolean {
  const diff = executionPrice > expectedPrice ? executionPrice - expectedPrice : expectedPrice - executionPrice
  return diff * BPS <= expectedPrice * slippageBps
}

/* ------------------------------------------------------------------ */
/* Funding                                                             */
/* ------------------------------------------------------------------ */

/**
 * FundingLib.calculateIndexDeltas: the heavier side pays `rate` per hour on its notional, the lighter side
 * receives the same total pro rata. Payer deltas round up, receiver deltas round down.
 */
export function fundingIndexDeltas(oiLong: bigint, oiShort: bigint, deltaTime: bigint, fundingFactor: bigint): [bigint, bigint] {
  if (oiLong === 0n || oiShort === 0n || oiLong === oiShort) return [0n, 0n]
  const longsHeavy = oiLong > oiShort
  const [heavy, light] = longsHeavy ? [oiLong, oiShort] : [oiShort, oiLong]
  let ratePerHour = (fundingFactor * (heavy - light)) / (heavy + light)
  if (ratePerHour > MAX_FUNDING_RATE_PER_HOUR) ratePerHour = MAX_FUNDING_RATE_PER_HOUR
  const payerDelta = ceilDiv(ratePerHour * deltaTime, SECONDS_PER_HOUR)
  const receiverDelta = (payerDelta * heavy) / light
  return longsHeavy ? [payerDelta, -receiverDelta] : [-receiverDelta, payerDelta]
}

/** Hourly rates (WAD per unit of notional): what the heavy side pays and the light side receives */
export function fundingRates(oiLong: bigint, oiShort: bigint, fundingFactor: bigint): { long: bigint; short: bigint } {
  if (oiLong === 0n || oiShort === 0n || oiLong === oiShort) return { long: 0n, short: 0n }
  const longsHeavy = oiLong > oiShort
  const [heavy, light] = longsHeavy ? [oiLong, oiShort] : [oiShort, oiLong]
  let rate = (fundingFactor * (heavy - light)) / (heavy + light)
  if (rate > MAX_FUNDING_RATE_PER_HOUR) rate = MAX_FUNDING_RATE_PER_HOUR
  const received = (rate * heavy) / light
  return longsHeavy ? { long: rate, short: -received } : { long: -received, short: rate }
}

/** FundingLib.calculateFundingOwed: positive means the trader pays. Payers round up, receivers round down. */
export function fundingOwedOf(positionSizeWad: bigint, currentIndex: bigint, entryIndex: bigint): bigint {
  const delta = currentIndex - entryIndex
  if (delta >= 0n) return ceilDiv(positionSizeWad * delta, INDEX_TO_USDC)
  return -((positionSizeWad * -delta) / INDEX_TO_USDC)
}

export interface FundingState {
  oiLong: bigint
  oiShort: bigint
  longIndex: bigint
  shortIndex: bigint
  lastUpdated: bigint
}

/**
 * The indexes the next call at `time` would accrue to: TradingEngine._updateFundingIndex runs one interval at the
 * current open interest. A pair never touched keeps zero indexes (its first call only stamps the time).
 */
export function projectFundingIndexes(s: FundingState, time: bigint, activeFactor: bigint): { long: bigint; short: bigint } {
  if (s.lastUpdated === 0n || time <= s.lastUpdated) return { long: s.longIndex, short: s.shortIndex }
  const [dl, ds] = fundingIndexDeltas(s.oiLong, s.oiShort, time - s.lastUpdated, activeFactor)
  return { long: s.longIndex + dl, short: s.shortIndex + ds }
}

/** TradingEngine._activeFundingFactor: nothing accrues while PAUSE_SETTLE is set */
export const activeFundingFactor = (fundingFactor: bigint, pauseFlags: number) => ((pauseFlags & PAUSE_SETTLE) !== 0 ? 0n : fundingFactor)

/* ------------------------------------------------------------------ */
/* Positions                                                           */
/* ------------------------------------------------------------------ */

export interface Position {
  isLong: boolean
  collateral: bigint
  leverage: bigint
  openPrice: bigint
  tp: bigint
  sl: bigint
}

/** Close at an oracle price, as closeTrade would: close spread, funding-adjusted payout, close fee capped */
export function closeOutcome(p: Position, oraclePrice: bigint, spread: bigint, fundingOwed: bigint) {
  const executionPrice = applySpread(oraclePrice, p.isLong, false, spread)
  const pnl = pnlOf(p.collateral, p.leverage, p.openPrice, executionPrice, p.isLong)
  const gross = payoutOf(p.collateral, pnl, fundingOwed)
  let closeFee = feeOf(p.collateral, p.leverage, CLOSE_FEE_BPS)
  let payout = gross
  if (closeFee >= payout) {
    closeFee = payout
    payout = 0n
  } else {
    payout -= closeFee
  }
  return { executionPrice, pnl, fundingOwed, closeFee, payout }
}

/** TradingEngine._getConservativeLiqPrice: the band edge that favours the trader */
export function conservativePrice(price: bigint, conf: bigint, isLong: boolean): bigint {
  if (isLong) return price + conf
  return conf >= price ? 0n : price - conf
}

/** liquidate's check: band edge, then close spread, then loss on PnL minus funding against 90% of collateral */
export function liquidationCheck(p: Position, price: bigint, conf: bigint, spread: bigint, fundingOwed: bigint) {
  const executionPrice = applySpread(conservativePrice(price, conf, p.isLong), p.isLong, false, spread)
  const pnl = pnlOf(p.collateral, p.leverage, p.openPrice, executionPrice, p.isLong)
  const adjusted = pnl - fundingOwed
  const threshold = (p.collateral * LIQUIDATION_THRESHOLD_BPS) / BPS
  const loss = adjusted < 0n ? -adjusted : 0n
  return { executionPrice, pnl, loss, threshold, liquidatable: loss >= threshold }
}

/** TradingEngine._computeLiquidatorReward: 10% of what is left after the loss, at least 0.5% of collateral */
export function liquidatorReward(collateral: bigint, loss: bigint): bigint {
  const remaining = loss >= collateral ? 0n : collateral - loss
  const reward = (remaining * LIQUIDATOR_REWARD_BPS) / BPS
  const min = (collateral * LIQUIDATOR_MIN_REWARD_BPS) / BPS
  return reward < min ? min : reward
}

/** TradingEngine._isLimitTriggered: TP is checked before SL */
export function limitTriggered(p: Position, oraclePrice: bigint): 'tp' | 'sl' | null {
  if (p.tp !== 0n && (p.isLong ? oraclePrice >= p.tp : oraclePrice <= p.tp)) return 'tp'
  if (p.sl !== 0n && (p.isLong ? oraclePrice <= p.sl : oraclePrice >= p.sl)) return 'sl'
  return null
}

/** executeLimit's settlement: the close, then the executor reward carved out of the trader's payout */
export function limitOutcome(p: Position, oraclePrice: bigint, spread: bigint, fundingOwed: bigint) {
  const close = closeOutcome(p, oraclePrice, spread, fundingOwed)
  let executorReward = (p.collateral * p.leverage * EXEC_REWARD_BPS) / BPS
  if (executorReward > close.payout) executorReward = close.payout
  return { ...close, executorReward, traderPayout: close.payout - executorReward }
}

/* ------------------------------------------------------------------ */
/* Opening                                                             */
/* ------------------------------------------------------------------ */

export interface OpenInput {
  isLong: boolean
  collateral: bigint
  leverage: bigint
  tp: bigint
  sl: bigint
}

export interface OpenQuote {
  fee: bigint
  effectiveCollateral: bigint
  sizeWad: bigint
  spread: bigint
  executionPrice: bigint
  /** Loss the position would show if closed in the same block, and the 90% threshold it must stay under */
  instantLoss: bigint
  threshold: bigint
  preLiquidatable: boolean
  oiAfter: bigint
  exceedsMaxOI: boolean
  tpError?: string
  slError?: string
}

/**
 * openTrade's numbers at an oracle price: open spread at the OI before the position, the pre-liquidation guard at
 * the OI after it, the max OI check, and both TP/SL checks (engine: against the oracle price; storage: against
 * the execution price).
 */
export function quoteOpen(o: OpenInput, oraclePrice: bigint, spreadAt: (oi: bigint) => bigint, openInterest: bigint, maxOI: bigint): OpenQuote {
  const fee = feeOf(o.collateral, o.leverage, OPEN_FEE_BPS)
  const effectiveCollateral = o.collateral - fee
  const sizeWad = positionSizeWad(effectiveCollateral, o.leverage)
  const spread = spreadAt(openInterest)
  const executionPrice = applySpread(oraclePrice, o.isLong, true, spread)

  const oiAfter = openInterest + sizeWad
  const closePrice = applySpread(oraclePrice, o.isLong, false, spreadAt(oiAfter))
  const instant = pnlOf(effectiveCollateral, o.leverage, executionPrice, closePrice, o.isLong)
  const threshold = (effectiveCollateral * LIQUIDATION_THRESHOLD_BPS) / BPS
  const instantLoss = instant < 0n ? -instant : 0n

  let tpError: string | undefined
  let slError: string | undefined
  if (o.tp !== 0n) {
    if (o.isLong ? o.tp <= oraclePrice : o.tp >= oraclePrice) tpError = `Take profit must be ${o.isLong ? 'above' : 'below'} the current price.`
    else if (o.isLong ? o.tp <= executionPrice : o.tp >= executionPrice) tpError = `Take profit must be ${o.isLong ? 'above' : 'below'} the entry price.`
  }
  if (o.sl !== 0n) {
    if (o.isLong ? o.sl >= oraclePrice : o.sl <= oraclePrice) slError = `Stop loss must be ${o.isLong ? 'below' : 'above'} the current price.`
    else if (o.isLong ? o.sl >= executionPrice : o.sl <= executionPrice) slError = `Stop loss must be ${o.isLong ? 'below' : 'above'} the entry price.`
  }

  return {
    fee,
    effectiveCollateral,
    sizeWad,
    spread,
    executionPrice,
    instantLoss,
    threshold,
    preLiquidatable: instantLoss >= threshold,
    oiAfter,
    exceedsMaxOI: oiAfter > maxOI,
    tpError,
    slError,
  }
}

/* ------------------------------------------------------------------ */
/* Liquidation price                                                   */
/* ------------------------------------------------------------------ */

/**
 * The Chainlink answer at which liquidate would first succeed, holding funding and open interest at today's values.
 * Searches the integer answers the app would push (conf derived from each one as DemoPyth requires), so the result
 * goes through the contract's own rounding rather than a closed-form approximation. Null if out of range.
 */
export function liquidationAnswer(
  p: Position,
  fundingOwed: bigint,
  spread: bigint,
  decimals: number,
  confBps: bigint,
  openAnswer: bigint,
): bigint | null {
  const scale = 10n ** BigInt(18 - decimals)
  const liquidatableAt = (answer: bigint) =>
    liquidationCheck(p, answer * scale, ((answer * confBps) / BPS) * scale, spread, fundingOwed).liquidatable

  if (p.isLong) {
    // Liquidatable at low prices: find the highest answer that is liquidatable
    let lo = 0n
    let hi = openAnswer * 2n
    if (liquidatableAt(hi)) return hi
    if (!liquidatableAt(lo + 1n)) return null
    lo = 1n
    while (hi - lo > 1n) {
      const mid = (lo + hi) / 2n
      if (liquidatableAt(mid)) lo = mid
      else hi = mid
    }
    return lo
  }
  // Short: liquidatable at high prices: find the lowest answer that is liquidatable
  let lo = 1n
  let hi = openAnswer * 4n
  if (liquidatableAt(lo)) return lo
  if (!liquidatableAt(hi)) return null
  while (hi - lo > 1n) {
    const mid = (lo + hi) / 2n
    if (liquidatableAt(mid)) hi = mid
    else lo = mid
  }
  return hi
}

/* ------------------------------------------------------------------ */
/* Updating levels                                                     */
/* ------------------------------------------------------------------ */

/**
 * updateTp / updateSl on an open position: the engine checks the level is not already reached at the oracle price,
 * then TradingStorage checks it is on the right side of the entry price. Clearing a level (0) skips both.
 */
export function levelError(p: Position, kind: 'tp' | 'sl', level: bigint, oraclePrice: bigint): string | undefined {
  if (level === 0n) return undefined
  if (kind === 'tp') {
    if (p.isLong ? level <= oraclePrice : level >= oraclePrice) return `Take profit must be ${p.isLong ? 'above' : 'below'} the current price.`
    if (p.isLong ? level <= p.openPrice : level >= p.openPrice) return `Take profit must be ${p.isLong ? 'above' : 'below'} the entry price.`
    return undefined
  }
  if (p.isLong ? level >= oraclePrice : level <= oraclePrice) return `Stop loss must be ${p.isLong ? 'below' : 'above'} the current price.`
  if (p.isLong ? level >= p.openPrice : level <= p.openPrice) return `Stop loss must be ${p.isLong ? 'below' : 'above'} the entry price.`
  return undefined
}
