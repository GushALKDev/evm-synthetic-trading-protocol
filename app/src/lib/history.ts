// The History tab's records, kept in the visitor's browser. A proof of concept with no indexer cannot read an account's
// past events through the public RPC, which serves at most 200 blocks per log query (about 40 s on Base Sepolia), so the
// app records what it sees: the settlements of the calls it sends, and positions that disappear while the page is open.
import { parseEventLogs, type Address, type Hex, type Log } from 'viem'
import { tradingEngineAbi } from '../abi'

export type HistoryKind = 'closed' | 'take profit' | 'stop loss' | 'liquidated' | 'closed while away'

/** What the app knew about an open position, so a record can name it after the trade is deleted */
export interface PositionSnapshot {
  tradeId: string
  pair: string
  isLong: boolean
  leverage: string
  /** Collateral after the open fee, USDC base units */
  collateral: string
  openPrice: string
  /** Block at which the app last saw it open */
  seenAtBlock: string
}

export interface HistoryEntry extends Omit<PositionSnapshot, 'seenAtBlock'> {
  kind: HistoryKind
  /** Unix seconds, of the settlement's block, or of the moment the app noticed the position was gone */
  time: number
  closePrice?: string
  pnl?: string
  funding?: string
  /** What the trader received */
  payout?: string
  txHash?: Hex
}

const settlementEvents = ['TradeClosed', 'LimitExecuted', 'TradeLiquidated'] as const

const positionOf = (s: PositionSnapshot) => ({
  tradeId: s.tradeId,
  pair: s.pair,
  isLong: s.isLong,
  leverage: s.leverage,
  collateral: s.collateral,
  openPrice: s.openPrice,
})

/**
 * The settlements of an account's positions in a set of logs, as history entries. Positions the app has no snapshot of
 * are skipped: a record without its pair, side and size would say little.
 */
export function entriesFromLogs(logs: Log[], account: Address, snapshots: Map<string, PositionSnapshot>, time: number): HistoryEntry[] {
  const events = parseEventLogs({ abi: tradingEngineAbi, logs, eventName: [...settlementEvents] })
  const entries: HistoryEntry[] = []
  for (const e of events) {
    if (e.args.user.toLowerCase() !== account.toLowerCase()) continue
    const snapshot = snapshots.get(e.args.tradeId.toString())
    if (!snapshot) continue
    const base = { ...positionOf(snapshot), time, txHash: e.transactionHash ?? undefined, closePrice: e.args.closePrice.toString(), pnl: e.args.pnlUsdc.toString(), funding: e.args.fundingOwedUsdc.toString() }
    if (e.eventName === 'TradeClosed') entries.push({ ...base, kind: 'closed', payout: e.args.payoutUsdc.toString() })
    else if (e.eventName === 'LimitExecuted') entries.push({ ...base, kind: e.args.isTp ? 'take profit' : 'stop loss', payout: e.args.payoutUsdc.toString() })
    else entries.push({ ...base, kind: 'liquidated', payout: '0' })
  }
  return entries
}

/** A position that is gone, with no settlement event found: the app shows what it knew, without amounts */
export function awayEntry(snapshot: PositionSnapshot, time: number): HistoryEntry {
  return { ...positionOf(snapshot), kind: 'closed while away', time }
}

/** Newest first, one entry per trade: an exact settlement replaces a "closed while away" record of the same trade */
export function mergeHistory(current: HistoryEntry[], added: HistoryEntry[]): HistoryEntry[] {
  const byTrade = new Map<string, HistoryEntry>()
  for (const e of [...current, ...added]) {
    const existing = byTrade.get(e.tradeId)
    if (!existing || (existing.kind === 'closed while away' && e.kind !== 'closed while away')) byTrade.set(e.tradeId, e)
  }
  return [...byTrade.values()].sort((a, b) => b.time - a.time)
}

export const historyKey = (chainId: number, account: Address) => `history:${chainId}:${account.toLowerCase()}`
export const openKey = (chainId: number, account: Address) => `open-positions:${chainId}:${account.toLowerCase()}`

/** Browser storage can be missing or refuse (private windows, blocked site data): the tab then starts empty */
export function load<T>(key: string, fallback: T): T {
  try {
    const raw = window.localStorage.getItem(key)
    return raw ? (JSON.parse(raw) as T) : fallback
  } catch {
    return fallback
  }
}

export function save(key: string, value: unknown) {
  try {
    window.localStorage.setItem(key, JSON.stringify(value))
  } catch {
    // Nothing to do: the history lasts for this visit only
  }
}
