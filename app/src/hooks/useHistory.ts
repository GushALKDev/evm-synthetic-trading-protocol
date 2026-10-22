import { useCallback, useEffect, useRef, useState } from 'react'
import { encodeEventTopics, numberToHex, pad, type Address, type Hex, type Log } from 'viem'
import { getBlock, getPublicClient } from 'wagmi/actions'
import { tradingEngineAbi } from '../abi'
import { chain } from '../config/chain'
import { awayEntry, entriesFromLogs, historyKey, load, mergeHistory, openKey, save, type HistoryEntry, type PositionSnapshot } from '../lib/history'
import type { Model, TradeView } from '../lib/model'
import { wagmiConfig } from '../wagmi'

/** The public Base Sepolia RPC serves at most 200 blocks per log query; the app searches at most 10 of those spans */
const LOG_SPAN = 200n
const MAX_SPANS = 10n

/** Raised by useTx with the logs of every successful call, so the history records its own settlements exactly */
export const RECEIPT_EVENT = 'protocol:receipt'
export interface ReceiptDetail {
  account: Address
  logs: Log[]
  timestamp: number
}

const settlementTopics = (['TradeClosed', 'LimitExecuted', 'TradeLiquidated'] as const).map(
  (eventName) => encodeEventTopics({ abi: tradingEngineAbi, eventName })[0],
)

const snapshotOf = (t: TradeView, block: bigint): PositionSnapshot => ({
  tradeId: t.id.toString(),
  pair: t.pair.name,
  isLong: t.position.isLong,
  leverage: t.position.leverage.toString(),
  collateral: t.position.collateral.toString(),
  openPrice: t.position.openPrice.toString(),
  seenAtBlock: block.toString(),
})

/** The settlement logs of one trade between two blocks, or null when the span is longer than the app searches */
async function settlementLogs(engine: Address, tradeId: string, from: bigint, to: bigint): Promise<Log[] | null> {
  if (to - from > LOG_SPAN * MAX_SPANS) return null
  const client = getPublicClient(wagmiConfig)
  if (!client) return null
  const idTopic = pad(numberToHex(BigInt(tradeId)), { size: 32 })
  const logs: Log[] = []
  for (let start = from; start <= to; start += LOG_SPAN) {
    const end = start + LOG_SPAN - 1n < to ? start + LOG_SPAN - 1n : to
    const found = (await client.request({
      method: 'eth_getLogs',
      params: [{ address: engine, fromBlock: numberToHex(start), toBlock: numberToHex(end), topics: [settlementTopics as Hex[], idTopic] }],
    })) as Log[]
    logs.push(...found)
  }
  return logs
}

/**
 * The account's closed positions, kept in this browser: the settlements of its own calls, exact, and positions that
 * disappear while the page is open, found by their settlement event. A position that closed while the page was closed
 * is recorded without amounts.
 */
export function useHistory(model: Model | null) {
  const account = model?.account?.address
  const key = account ? historyKey(chain.id, account) : null
  const [entries, setEntries] = useState<HistoryEntry[]>([])
  const entriesRef = useRef(entries)
  entriesRef.current = entries

  useEffect(() => setEntries(key ? load<HistoryEntry[]>(key, []) : []), [key])

  const add = useCallback(
    (added: HistoryEntry[]) => {
      if (!key || added.length === 0) return
      setEntries((current) => {
        const next = mergeHistory(current, added)
        save(key, next)
        return next
      })
    },
    [key],
  )

  // Own settlements, from the receipt of the call that made them
  useEffect(() => {
    if (!account) return
    const onReceipt = (e: Event) => {
      const detail = (e as CustomEvent<ReceiptDetail>).detail
      if (detail.account.toLowerCase() !== account.toLowerCase()) return
      const snapshots = new Map(Object.entries(load<Record<string, PositionSnapshot>>(openKey(chain.id, account), {})))
      add(entriesFromLogs(detail.logs, account, snapshots, detail.timestamp))
    }
    window.addEventListener(RECEIPT_EVENT, onReceipt)
    return () => window.removeEventListener(RECEIPT_EVENT, onReceipt)
  }, [account, add])

  // Positions that are gone since the last look: closed elsewhere, liquidated or executed by someone else
  const trades = model?.account?.trades
  const block = model?.blockNumber ?? 0n
  const engine = model?.deployment.engine
  const chainTime = Number(model?.chainTime ?? 0n)
  useEffect(() => {
    if (!account || !trades || !engine) return
    const storeKey = openKey(chain.id, account)
    const stored = load<Record<string, PositionSnapshot>>(storeKey, {})
    const current = new Set(trades.map((t) => t.id.toString()))
    const recorded = new Set(entriesRef.current.map((e) => e.tradeId))
    const gone = Object.values(stored).filter((s) => !current.has(s.tradeId) && !recorded.has(s.tradeId))
    save(storeKey, Object.fromEntries(trades.map((t) => [t.id.toString(), snapshotOf(t, block)])))
    if (gone.length === 0) return
    const snapshots = new Map(gone.map((s) => [s.tradeId, s]))
    void (async () => {
      const found: HistoryEntry[] = []
      for (const s of gone) {
        try {
          const logs = await settlementLogs(engine, s.tradeId, BigInt(s.seenAtBlock), block)
          const exact = logs && logs.length > 0 ? entriesFromLogs(logs, account, snapshots, chainTime) : []
          if (exact.length > 0 && logs![0].blockNumber !== null) {
            const settled = await getBlock(wagmiConfig, { blockNumber: BigInt(logs![0].blockNumber) })
            found.push(...exact.map((x) => ({ ...x, time: Number(settled.timestamp) })))
          } else {
            found.push(awayEntry(s, chainTime))
          }
        } catch {
          found.push(awayEntry(s, chainTime))
        }
      }
      add(found)
    })()
  }, [account, trades, block, engine, chainTime, add])

  return entries
}
