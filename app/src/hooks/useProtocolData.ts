import { useMemo } from 'react'
import type { Abi, Address, Hex } from 'viem'
import { useBalance, useReadContracts } from 'wagmi'
import { deployment } from '../config/chain'
import type { Deployment } from '../config/deployment'
import {
  assistantFundAbi,
  bondAbi,
  chainlinkAbi,
  demoPythAbi,
  engineAbi,
  faucetCallAbi,
  oracleAbi,
  spreadManagerAbi,
  storageAbi,
  tokenAbi,
  vaultAbi,
} from '../lib/abi'
import type { PairTotals } from '../lib/vault'

const REFRESH_MS = 6_000
const CONFIG_REFRESH_MS = 60_000
/** The positions page reads the most recent trade ids only, so its read stays bounded however many trades exist */
export const TRADE_WINDOW = 500

interface Read {
  address: Address
  abi: Abi | readonly unknown[]
  functionName: string
  args?: readonly unknown[]
}

function useReads(contracts: Read[], query: { enabled?: boolean; refetchInterval?: number; staleTime?: number }) {
  const res = useReadContracts({ allowFailure: false, contracts: contracts as never, query })
  return { ...res, data: res.data as unknown as readonly unknown[] | undefined }
}

/* ------------------------------------------------------------------ */
/* Configuration: changes only by owner action                         */
/* ------------------------------------------------------------------ */

export interface PairConfig {
  index: number
  name: string
  maxOI: bigint
  maxLeverage: bigint
  isActive: boolean
  pythFeedId: Hex
  chainlinkFeed: Address
  heartbeat: bigint
  decimals: number
}

export interface ConfigData {
  pairs: PairConfig[]
  spread: { baseSpreadBps: bigint; impactFactor: bigint; volFactor: bigint; maxSpreadBps: bigint }
  fundingFactor: bigint
  maxPriceAge: bigint
  updateFee: bigint
  confBps: bigint
  deployTimestamp: bigint
  maxSnapshotAge: bigint
  reserveTargetCap: bigint
  referencePrice: bigint
  discountBps: bigint
  vestingPeriod: bigint
}

function useConfig(d: Deployment) {
  const count = useReads([{ address: d.tradingStorage, abi: storageAbi, functionName: 'getPairsCount' }], { refetchInterval: CONFIG_REFRESH_MS })
  const n = count.data ? Number(count.data[0] as bigint) : 0
  const indexes = Array.from({ length: n }, (_, i) => BigInt(i))
  const pairReads = useReads(
    [
      ...indexes.map((i) => ({ address: d.tradingStorage, abi: storageAbi, functionName: 'getPair', args: [i] })),
      ...indexes.map((i) => ({ address: d.oracle, abi: oracleAbi, functionName: 'getPairFeed', args: [i] })),
    ],
    { enabled: n > 0, refetchInterval: CONFIG_REFRESH_MS },
  )
  const feeds = pairReads.data ? (pairReads.data.slice(n) as { chainlinkFeed: Address }[]).map((f) => f.chainlinkFeed) : []
  const decimals = useReads(
    feeds.map((address) => ({ address, abi: chainlinkAbi, functionName: 'decimals' })),
    { enabled: feeds.length > 0, staleTime: Infinity },
  )
  const rest = useReads(
    [
      { address: d.spreadManager, abi: spreadManagerAbi, functionName: 'baseSpreadBps' },
      { address: d.spreadManager, abi: spreadManagerAbi, functionName: 'impactFactor' },
      { address: d.spreadManager, abi: spreadManagerAbi, functionName: 'volFactor' },
      { address: d.spreadManager, abi: spreadManagerAbi, functionName: 'maxSpreadBps' },
      { address: d.engine, abi: engineAbi, functionName: 'fundingFactor' },
      { address: d.oracle, abi: oracleAbi, functionName: 'maxPriceAge' },
      { address: d.pyth, abi: demoPythAbi, functionName: 'SINGLE_UPDATE_FEE' },
      { address: d.pyth, abi: demoPythAbi, functionName: 'DEMO_CONF_BPS' },
      { address: d.vault, abi: vaultAbi, functionName: 'DEPLOY_TIMESTAMP' },
      { address: d.vault, abi: vaultAbi, functionName: 'maxPnlSnapshotAge' },
      { address: d.assistantFund, abi: assistantFundAbi, functionName: 'targetCap' },
      { address: d.bondDepository, abi: bondAbi, functionName: 'referencePrice' },
      { address: d.bondDepository, abi: bondAbi, functionName: 'discountBps' },
      { address: d.bondDepository, abi: bondAbi, functionName: 'vestingPeriod' },
    ],
    { refetchInterval: CONFIG_REFRESH_MS },
  )

  const data = useMemo((): ConfigData | undefined => {
    const p = pairReads.data
    const dec = decimals.data
    const r = rest.data
    if (!p || !dec || !r || dec.length !== n) return undefined
    const pairs = indexes.map((_, i): PairConfig => {
      const pair = p[i] as { name: string; maxOI: bigint; maxLeverage: number; isActive: boolean }
      const feed = p[n + i] as { pythFeedId: Hex; chainlinkFeed: Address; chainlinkHeartbeat: number }
      return {
        index: i,
        name: pair.name,
        maxOI: pair.maxOI,
        maxLeverage: BigInt(pair.maxLeverage),
        isActive: pair.isActive,
        pythFeedId: feed.pythFeedId,
        chainlinkFeed: feed.chainlinkFeed,
        heartbeat: BigInt(feed.chainlinkHeartbeat),
        decimals: Number(dec[i]),
      }
    })
    const big = (x: unknown) => BigInt(x as bigint | number)
    return {
      pairs,
      spread: { baseSpreadBps: big(r[0]), impactFactor: big(r[1]), volFactor: big(r[2]), maxSpreadBps: big(r[3]) },
      fundingFactor: big(r[4]),
      maxPriceAge: big(r[5]),
      updateFee: big(r[6]),
      confBps: big(r[7]),
      deployTimestamp: big(r[8]),
      maxSnapshotAge: big(r[9]),
      reserveTargetCap: big(r[10]),
      referencePrice: big(r[11]),
      discountBps: big(r[12]),
      vestingPeriod: big(r[13]),
    }
  }, [pairReads.data, decimals.data, rest.data, n])

  return { data, error: count.error ?? pairReads.error ?? decimals.error ?? rest.error, isLoading: count.isLoading || pairReads.isLoading || rest.isLoading }
}

/* ------------------------------------------------------------------ */
/* Live state                                                          */
/* ------------------------------------------------------------------ */

export interface PairLive {
  answer: bigint
  updatedAt: bigint
  oiLong: bigint
  oiShort: bigint
  longIndex: bigint
  shortIndex: bigint
  lastUpdated: bigint
  totals: PairTotals
  volatility: bigint
}

export interface LiveData {
  pairs: PairLive[]
  enginePauseFlags: number
  vaultPauseFlags: number
  vaultBalance: bigint
  supply: bigint
  snapshot: { netPnl: bigint; timestamp: bigint; nonce: bigint }
  openTrades: bigint
  positionsNonce: bigint
  tradeCounter: bigint
  reserveBalance: bigint
  remainingCap: bigint
}

/** Reads per pair in useLive, in the order listed there */
const PER_PAIR = 8

function useLive(d: Deployment, config: ConfigData | undefined) {
  const pairs = config?.pairs ?? []
  const res = useReads(
    [
      ...pairs.flatMap((p) => {
        const i = BigInt(p.index)
        return [
          { address: p.chainlinkFeed, abi: chainlinkAbi, functionName: 'latestRoundData' },
          { address: d.tradingStorage, abi: storageAbi, functionName: 'getOpenInterestLong', args: [i] },
          { address: d.tradingStorage, abi: storageAbi, functionName: 'getOpenInterestShort', args: [i] },
          { address: d.tradingStorage, abi: storageAbi, functionName: 'getCumulativeFundingIndex', args: [i, true] },
          { address: d.tradingStorage, abi: storageAbi, functionName: 'getCumulativeFundingIndex', args: [i, false] },
          { address: d.tradingStorage, abi: storageAbi, functionName: 'getFundingLastUpdated', args: [i] },
          { address: d.tradingStorage, abi: storageAbi, functionName: 'getPairOpenTotals', args: [i] },
          { address: d.spreadManager, abi: spreadManagerAbi, functionName: 'getPairVolatility', args: [i] },
        ]
      }),
      { address: d.engine, abi: engineAbi, functionName: 'pauseFlags' },
      { address: d.vault, abi: vaultAbi, functionName: 'pauseFlags' },
      { address: d.usdc, abi: tokenAbi, functionName: 'balanceOf', args: [d.vault] },
      { address: d.vault, abi: vaultAbi, functionName: 'totalSupply' },
      { address: d.vault, abi: vaultAbi, functionName: 'pnlSnapshot' },
      { address: d.tradingStorage, abi: storageAbi, functionName: 'getPositionState' },
      { address: d.tradingStorage, abi: storageAbi, functionName: 'getTradeCounter' },
      { address: d.usdc, abi: tokenAbi, functionName: 'balanceOf', args: [d.assistantFund] },
      { address: d.bondDepository, abi: bondAbi, functionName: 'remainingCap' },
    ],
    { enabled: pairs.length > 0, refetchInterval: REFRESH_MS },
  )

  const data = useMemo((): LiveData | undefined => {
    const r = res.data
    if (!r || pairs.length === 0) return undefined
    const live = pairs.map((_, i): PairLive => {
      const o = i * PER_PAIR
      const round = r[o] as readonly [bigint, bigint, bigint, bigint, bigint]
      const t = r[o + 6] as PairTotals
      return {
        answer: round[1],
        updatedAt: round[3],
        oiLong: r[o + 1] as bigint,
        oiShort: r[o + 2] as bigint,
        longIndex: r[o + 3] as bigint,
        shortIndex: r[o + 4] as bigint,
        lastUpdated: r[o + 5] as bigint,
        totals: {
          longSize: t.longSize,
          longCollateral: t.longCollateral,
          longQuantity: t.longQuantity,
          shortSize: t.shortSize,
          shortCollateral: t.shortCollateral,
          shortQuantity: t.shortQuantity,
        },
        volatility: r[o + 7] as bigint,
      }
    })
    const b = pairs.length * PER_PAIR
    const snapshot = r[b + 4] as readonly [bigint, number, number]
    const position = r[b + 5] as readonly [number, number]
    return {
      pairs: live,
      enginePauseFlags: Number(r[b]),
      vaultPauseFlags: Number(r[b + 1]),
      vaultBalance: r[b + 2] as bigint,
      supply: r[b + 3] as bigint,
      snapshot: { netPnl: BigInt(snapshot[0]), timestamp: BigInt(snapshot[1]), nonce: BigInt(snapshot[2]) },
      openTrades: BigInt(position[0]),
      positionsNonce: BigInt(position[1]),
      tradeCounter: BigInt(r[b + 6] as number),
      reserveBalance: r[b + 7] as bigint,
      remainingCap: r[b + 8] as bigint,
    }
  }, [res.data, pairs])

  return { data, error: res.error, isLoading: res.isLoading }
}

/* ------------------------------------------------------------------ */
/* Trades                                                              */
/* ------------------------------------------------------------------ */

export interface RawTrade {
  id: bigint
  user: Address
  isLong: boolean
  pairIndex: number
  leverage: bigint
  timestamp: bigint
  collateral: bigint
  openPrice: bigint
  tp: bigint
  sl: bigint
  entryIndex: bigint
}

interface TradeStruct {
  user: Address
  isLong: boolean
  pairIndex: number
  leverage: number
  timestamp: number
  collateral: bigint
  openPrice: bigint
  tp: bigint
  sl: bigint
}

/** Reads trades by id with their funding entry index; ids of closed trades come back with user == address(0) */
export function useTrades(ids: bigint[], enabled = true) {
  const d = deployment as Deployment
  const res = useReads(
    ids.flatMap((id) => [
      { address: d.tradingStorage, abi: storageAbi, functionName: 'getTrade', args: [id] },
      { address: d.tradingStorage, abi: storageAbi, functionName: 'getTradeFundingIndex', args: [id] },
    ]),
    { enabled: enabled && ids.length > 0, refetchInterval: REFRESH_MS },
  )
  const data = useMemo((): RawTrade[] | undefined => {
    if (ids.length === 0) return []
    const r = res.data
    if (!r) return undefined
    return ids
      .map((id, i) => {
        const t = r[2 * i] as TradeStruct
        return {
          id,
          user: t.user,
          isLong: t.isLong,
          pairIndex: Number(t.pairIndex),
          leverage: BigInt(t.leverage),
          timestamp: BigInt(t.timestamp),
          collateral: BigInt(t.collateral),
          openPrice: t.openPrice,
          tp: t.tp,
          sl: t.sl,
          entryIndex: r[2 * i + 1] as bigint,
        }
      })
      .filter((t) => t.user !== '0x0000000000000000000000000000000000000000')
  }, [res.data, ids])
  return { data, error: res.error, isLoading: res.isLoading }
}

/* ------------------------------------------------------------------ */
/* Account                                                             */
/* ------------------------------------------------------------------ */

export interface BondPosition {
  id: bigint
  totalSynth: bigint
  claimedSynth: bigint
  start: bigint
  end: bigint
  claimable: bigint
}

export interface AccountData {
  usdc: bigint
  /** Unknown while loading, so the interface does not flash a no-gas warning */
  eth: bigint | undefined
  allowance: { engine: bigint; vault: bigint; bond: bigint }
  shares: bigint
  request: { shares: bigint; requestEpoch: bigint }
  expiryEpoch: bigint
  canExecute: boolean
  nextClaimAt: bigint
  tradeIds: bigint[]
  synth: bigint
  bonds: BondPosition[]
}

function useAccount(d: Deployment, account: Address | undefined) {
  const user = account ?? '0x0000000000000000000000000000000000000000'
  const enabled = !!account
  const eth = useBalance({ address: account, query: { enabled, refetchInterval: REFRESH_MS } })
  const reads = useReads(
    [
      { address: d.usdc, abi: tokenAbi, functionName: 'balanceOf', args: [user] },
      { address: d.usdc, abi: tokenAbi, functionName: 'allowance', args: [user, d.engine] },
      { address: d.usdc, abi: tokenAbi, functionName: 'allowance', args: [user, d.vault] },
      { address: d.usdc, abi: tokenAbi, functionName: 'allowance', args: [user, d.bondDepository] },
      { address: d.vault, abi: vaultAbi, functionName: 'balanceOf', args: [user] },
      { address: d.vault, abi: vaultAbi, functionName: 'withdrawalRequests', args: [user] },
      { address: d.vault, abi: vaultAbi, functionName: 'getWithdrawalExpiryEpoch', args: [user] },
      { address: d.vault, abi: vaultAbi, functionName: 'canExecuteWithdrawal', args: [user] },
      { address: d.faucet, abi: faucetCallAbi, functionName: 'nextClaimAt', args: [user] },
      { address: d.tradingStorage, abi: storageAbi, functionName: 'getUserTrades', args: [user] },
      { address: d.synth, abi: tokenAbi, functionName: 'balanceOf', args: [user] },
      { address: d.bondDepository, abi: bondAbi, functionName: 'bondCount', args: [user] },
    ],
    { enabled, refetchInterval: REFRESH_MS },
  )
  const bondCount = reads.data ? Number(reads.data[11] as bigint) : 0
  const bondIds = Array.from({ length: bondCount }, (_, i) => BigInt(i))
  const bonds = useReads(
    bondIds.flatMap((id) => [
      { address: d.bondDepository, abi: bondAbi, functionName: 'bondAt', args: [user, id] },
      { address: d.bondDepository, abi: bondAbi, functionName: 'claimable', args: [user, id] },
    ]),
    { enabled: enabled && bondCount > 0, refetchInterval: REFRESH_MS },
  )

  const data = useMemo((): AccountData | undefined => {
    const r = reads.data
    if (!r || !account) return undefined
    if (bondCount > 0 && !bonds.data) return undefined
    const request = r[5] as readonly [bigint, bigint, bigint]
    return {
      usdc: r[0] as bigint,
      eth: eth.data?.value,
      allowance: { engine: r[1] as bigint, vault: r[2] as bigint, bond: r[3] as bigint },
      shares: r[4] as bigint,
      request: { shares: request[0], requestEpoch: request[1] },
      expiryEpoch: r[6] as bigint,
      canExecute: r[7] as boolean,
      nextClaimAt: r[8] as bigint,
      tradeIds: [...(r[9] as readonly bigint[])],
      synth: r[10] as bigint,
      bonds: bondIds.map((id, i) => {
        const pos = bonds.data![2 * i] as { totalSynth: bigint; claimedSynth: bigint; start: bigint; end: bigint }
        return { id, totalSynth: pos.totalSynth, claimedSynth: pos.claimedSynth, start: BigInt(pos.start), end: BigInt(pos.end), claimable: bonds.data![2 * i + 1] as bigint }
      }),
    }
  }, [reads.data, bonds.data, account, bondCount, eth.data?.value])

  return { data, error: reads.error ?? bonds.error, isLoading: reads.isLoading }
}

/* ------------------------------------------------------------------ */
/* All together                                                        */
/* ------------------------------------------------------------------ */

export function useProtocolData(account: Address | undefined) {
  const d = deployment as Deployment
  const config = useConfig(d)
  const live = useLive(d, config.data)
  const acc = useAccount(d, account)
  const idsKey = acc.data?.tradeIds.join(',') ?? ''
  const tradeIds = useMemo(() => (idsKey ? idsKey.split(',').map(BigInt) : []), [idsKey])
  const accountTrades = useTrades(tradeIds, !!acc.data)
  return {
    deployment: d,
    config: config.data,
    live: live.data,
    account: acc.data,
    accountTrades: accountTrades.data,
    error: config.error ?? live.error ?? acc.error ?? accountTrades.error,
    isLoading: config.isLoading || live.isLoading,
  }
}
