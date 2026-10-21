import type { Address } from 'viem'
import type { Deployment } from '../config/deployment'
import type { AccountData, ConfigData, LiveData, PairConfig, PairLive, RawTrade } from '../hooks/useProtocolData'
import type { ErrorContext } from './errors'
import { mirroredPrice } from './pyth'
import {
  PAUSE_OPEN,
  PAUSE_SETTLE,
  activeFundingFactor,
  closeOutcome,
  fundingOwedOf,
  fundingRates,
  limitOutcome,
  limitTriggered,
  liquidationAnswer,
  liquidationCheck,
  liquidatorReward,
  positionSizeWad,
  projectFundingIndexes,
  spreadBps,
  type Position,
} from './trading'
import {
  CRITICAL_CR,
  DEFICIT_CR,
  assetsForShares,
  bondCapacity,
  deficitOf,
  epochAt,
  navOf,
  openPnlLiability,
  pendingInjection,
  ratioOf,
  snapshotNetPnl,
  solvencyLevel,
  type SolvencyLevel,
} from './vault'

export interface PairView extends PairConfig, PairLive {
  symbol: string
  price: bigint
  conf: bigint
  anchorAge: bigint
  anchorFresh: boolean
  oi: bigint
  spread: bigint
  spreadAt: (openInterest: bigint) => bigint
  /** Indexes the next call would accrue to, at the latest block's timestamp */
  projected: { long: bigint; short: bigint }
  /** Hourly funding rate per unit of notional: positive pays, negative receives */
  rates: { long: bigint; short: bigint }
}

export interface TradeView {
  id: bigint
  user: Address
  isSeed: boolean
  pair: PairView
  position: Position
  openedAt: bigint
  sizeWad: bigint
  entryIndex: bigint
  fundingOwed: bigint
  /** What closeTrade would pay at the current price */
  close: ReturnType<typeof closeOutcome>
  /**
   * Payout minus the collateral stored for the trade, which is what the open fee left: the result if closed now, with
   * the close fee and funding, without the open fee
   */
  netResult: bigint
  liquidation: ReturnType<typeof liquidationCheck> & { reward: bigint }
  /** Chainlink price at which liquidate would first succeed, at today's funding and open interest */
  liquidationPrice: bigint | null
  limit: 'tp' | 'sl' | null
  limitResult: ReturnType<typeof limitOutcome> | null
}

export interface VaultView {
  balance: bigint
  supply: bigint
  openTrades: bigint
  snapshot: LiveData['snapshot']
  snapshotFresh: boolean
  snapshotAge: bigint
  /** totalAssets as the Vault reports it now, from the stored snapshot */
  storedNav: bigint
  /** Net trader PnL a refresh would store at the current prices, and the NAV it would leave */
  liveNetPnl: bigint
  liveLiability: bigint
  liveNav: bigint
  navRatio: bigint | null
  realisedRatio: bigint | null
  navDeficit: bigint
  realisedDeficit: bigint
  level: SolvencyLevel
  pendingInjection: bigint
  reserve: bigint
  reserveTargetCap: bigint
  bondActive: boolean
  remainingCap: bigint
  bondCapacity: bigint
  /** A bonding round is open, or the solvency check a deposit or refresh runs would open one */
  roundDue: boolean
  depositsPaused: boolean
  withdrawalsPaused: boolean
  epoch: bigint
}

export interface AccountView {
  address: Address
  data: AccountData
  trades: TradeView[]
  sharesValue: bigint
  request: { shares: bigint; requestEpoch: bigint; unlockEpoch: bigint; expiryEpoch: bigint; canExecute: boolean } | null
}

export interface Model {
  deployment: Deployment
  config: ConfigData
  pairs: PairView[]
  vault: VaultView
  account: AccountView | null
  chainTime: bigint
  openPaused: boolean
  settlePaused: boolean
  tradeCounter: bigint
  activeFundingFactor: bigint
}

export function buildPairs(config: ConfigData, live: LiveData, chainTime: bigint): PairView[] {
  const factor = activeFundingFactor(config.fundingFactor, live.enginePauseFlags)
  return config.pairs.map((c, i) => {
    const l = live.pairs[i]
    const { price, conf } = mirroredPrice(l.answer, c.decimals, config.confBps)
    const oi = l.oiLong + l.oiShort
    const spreadAt = (openInterest: bigint) => spreadBps(config.spread, l.volatility, openInterest)
    const anchorAge = chainTime > l.updatedAt ? chainTime - l.updatedAt : 0n
    return {
      ...c,
      ...l,
      symbol: c.name.split('/')[0],
      price,
      conf,
      anchorAge,
      anchorFresh: anchorAge <= c.heartbeat,
      oi,
      spread: spreadAt(oi),
      spreadAt,
      projected: projectFundingIndexes(l, chainTime, factor),
      rates: fundingRates(l.oiLong, l.oiShort, factor),
    }
  })
}

export function buildTrade(raw: RawTrade, pairs: PairView[], d: Deployment, confBps: bigint): TradeView | null {
  const pair = pairs[raw.pairIndex]
  if (!pair) return null
  const position: Position = { isLong: raw.isLong, collateral: raw.collateral, leverage: raw.leverage, openPrice: raw.openPrice, tp: raw.tp, sl: raw.sl }
  const sizeWad = positionSizeWad(raw.collateral, raw.leverage)
  const index = raw.isLong ? pair.projected.long : pair.projected.short
  const fundingOwed = fundingOwedOf(sizeWad, index, raw.entryIndex)
  const close = closeOutcome(position, pair.price, pair.spread, fundingOwed)
  const liq = liquidationCheck(position, pair.price, pair.conf, pair.spread, fundingOwed)
  const answerAtOpen = raw.openPrice / 10n ** BigInt(18 - pair.decimals)
  const liqAnswer = liquidationAnswer(position, fundingOwed, pair.spread, pair.decimals, confBps, answerAtOpen > 0n ? answerAtOpen : pair.answer)
  const limit = limitTriggered(position, pair.price)
  return {
    id: raw.id,
    user: raw.user,
    isSeed: raw.user.toLowerCase() === d.deployer.toLowerCase(),
    pair,
    position,
    openedAt: raw.timestamp,
    sizeWad,
    entryIndex: raw.entryIndex,
    fundingOwed,
    close,
    netResult: close.payout - raw.collateral,
    liquidation: { ...liq, reward: liquidatorReward(raw.collateral, liq.loss) },
    liquidationPrice: liqAnswer === null ? null : liqAnswer * 10n ** BigInt(18 - pair.decimals),
    limit,
    limitResult: limit ? limitOutcome(position, pair.price, pair.spread, fundingOwed) : null,
  }
}

export function buildVault(config: ConfigData, live: LiveData, pairs: PairView[], chainTime: bigint): VaultView {
  const liveNetPnl = snapshotNetPnl(pairs.map((p) => ({ totals: p.totals, price: p.price, conf: p.conf })))
  const liveLiability = openPnlLiability(live.openTrades, liveNetPnl)
  const liveNav = navOf(live.vaultBalance, liveLiability)
  const storedNav = navOf(live.vaultBalance, openPnlLiability(live.openTrades, live.snapshot.netPnl))
  const snapshotAge = live.snapshot.timestamp > 0n && chainTime > live.snapshot.timestamp ? chainTime - live.snapshot.timestamp : 0n
  // Vault.isPnlSnapshotFresh at the latest block
  const snapshotFresh =
    live.openTrades === 0n || (live.snapshot.timestamp !== 0n && live.snapshot.nonce === live.positionsNonce && snapshotAge <= config.maxSnapshotAge)
  const navRatio = ratioOf(liveNav, live.supply)
  const realisedRatio = ratioOf(live.vaultBalance, live.supply)
  const realisedDeficit = deficitOf(live.vaultBalance, live.supply)
  const injection = pendingInjection(liveNav, live.supply, live.reserveBalance)
  // SolvencyManager.bondingRoundOpenAfterCheck on the snapshot the deposit itself refreshes. The on-chain view uses the
  // stored snapshot, and while that is stale it counts no reserve injection, so it can report a round as due that the
  // deposit's own check would avoid by injecting first.
  const roundDue =
    live.remainingCap !== 0n
      ? realisedRatio !== null && realisedRatio < DEFICIT_CR
      : realisedRatio !== null && realisedRatio < CRITICAL_CR && realisedDeficit > injection
  return {
    balance: live.vaultBalance,
    supply: live.supply,
    openTrades: live.openTrades,
    snapshot: live.snapshot,
    snapshotFresh,
    snapshotAge,
    storedNav,
    liveNetPnl,
    liveLiability,
    liveNav,
    navRatio,
    realisedRatio,
    navDeficit: deficitOf(liveNav, live.supply),
    realisedDeficit,
    level: solvencyLevel(navRatio, realisedRatio),
    pendingInjection: injection,
    reserve: live.reserveBalance,
    reserveTargetCap: config.reserveTargetCap,
    bondActive: live.remainingCap !== 0n,
    remainingCap: live.remainingCap,
    bondCapacity: bondCapacity(live.remainingCap, realisedDeficit),
    roundDue,
    depositsPaused: (live.vaultPauseFlags & 1) !== 0,
    withdrawalsPaused: (live.vaultPauseFlags & 2) !== 0,
    epoch: epochAt(chainTime, config.deployTimestamp),
  }
}

export function buildModel(
  d: Deployment,
  config: ConfigData,
  live: LiveData,
  account: { address: Address; data: AccountData; trades: RawTrade[] } | null,
  chainTime: bigint,
): Model {
  const pairs = buildPairs(config, live, chainTime)
  const vault = buildVault(config, live, pairs, chainTime)
  let accountView: AccountView | null = null
  if (account) {
    const a = account.data
    const trades = account.trades
      .map((t) => buildTrade(t, pairs, d, config.confBps))
      .filter((t): t is TradeView => t !== null)
      .sort((x, y) => (x.id > y.id ? -1 : 1))
    accountView = {
      address: account.address,
      data: a,
      trades,
      sharesValue: assetsForShares(a.shares, live.supply, vault.liveNav),
      request:
        a.request.shares === 0n
          ? null
          : {
              shares: a.request.shares,
              requestEpoch: a.request.requestEpoch,
              unlockEpoch: a.request.requestEpoch + 3n,
              expiryEpoch: a.expiryEpoch,
              canExecute: a.canExecute,
            },
    }
  }
  return {
    deployment: d,
    config,
    pairs,
    vault,
    account: accountView,
    chainTime,
    openPaused: (live.enginePauseFlags & PAUSE_OPEN) !== 0,
    settlePaused: (live.enginePauseFlags & PAUSE_SETTLE) !== 0,
    tradeCounter: live.tradeCounter,
    activeFundingFactor: activeFundingFactor(config.fundingFactor, live.enginePauseFlags),
  }
}

/** What the error sentences need to name pairs, feeds and epochs */
export function errorContextOf(m: Model): ErrorContext {
  const lower = (x: string) => x.toLowerCase()
  return {
    pairName: (i) => m.pairs[Number(i)]?.name ?? 'this pair',
    pairOfFeedId: (id) => m.pairs.find((p) => lower(p.pythFeedId) === lower(id))?.name ?? 'this pair',
    pairOfChainlinkFeed: (feed) => m.pairs.find((p) => lower(p.chainlinkFeed) === lower(feed))?.name ?? 'this pair',
    maxPriceAge: m.config.maxPriceAge,
    epochStart: (epoch) => m.config.deployTimestamp + epoch * 86_400n,
  }
}
