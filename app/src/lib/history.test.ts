import { describe, expect, it } from 'vitest'
import { encodeAbiParameters, encodeEventTopics, type Address, type Hex, type Log } from 'viem'
import { tradingEngineAbi } from '../abi'
import { awayEntry, entriesFromLogs, mergeHistory, type PositionSnapshot } from './history'

const ME = '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC' as Address
const OTHER = '0x90F79bf6EB2c4f870365E785982E1f101E93b906' as Address
const ENGINE = '0x959922bE3CAee4b8Cd9a407cc3ac1C251C2007B1' as Address

function log(eventName: 'TradeClosed' | 'LimitExecuted' | 'TradeLiquidated', args: Record<string, unknown>): Log {
  const event = tradingEngineAbi.find((x) => x.type === 'event' && x.name === eventName)!
  const inputs = (event as { inputs: readonly { name: string; type: string; indexed?: boolean }[] }).inputs
  const nonIndexed = inputs.filter((i) => !i.indexed)
  return {
    address: ENGINE,
    topics: encodeEventTopics({ abi: tradingEngineAbi, eventName, args } as never) as [Hex, ...Hex[]],
    data: encodeAbiParameters(nonIndexed, nonIndexed.map((i) => args[i.name]) as never),
    blockHash: `0x${'aa'.repeat(32)}`,
    blockNumber: 10n,
    logIndex: 0,
    transactionHash: `0x${'bb'.repeat(32)}`,
    transactionIndex: 0,
    removed: false,
  } as Log
}

const snapshot = (tradeId: string): PositionSnapshot => ({
  tradeId,
  pair: 'BTC/USD',
  isLong: true,
  leverage: '10',
  collateral: '992000000',
  openPrice: '100050000000000000000000',
  seenAtBlock: '5',
})
const snapshots = new Map([['4', snapshot('4')], ['5', snapshot('5')], ['6', snapshot('6')]])

describe('history from settlement events', () => {
  it('records a close, a take profit and a liquidation of the account, with their amounts', () => {
    const logs = [
      log('TradeClosed', { tradeId: 4n, user: ME, closePrice: 101n, pnlUsdc: -5n, payoutUsdc: 980n, fee: 7n, fundingOwedUsdc: 1n }),
      log('LimitExecuted', { tradeId: 5n, user: ME, executor: OTHER, isTp: true, closePrice: 110n, pnlUsdc: 90n, payoutUsdc: 1_070n, executorReward: 10n, fundingOwedUsdc: -2n }),
      log('TradeLiquidated', { tradeId: 6n, user: ME, liquidator: OTHER, closePrice: 90n, pnlUsdc: -950n, fundingOwedUsdc: 3n, liquidatorReward: 5n, vaultAmount: 987n }),
    ]
    const entries = entriesFromLogs(logs, ME, snapshots, 1_000)
    expect(entries.map((e) => [e.tradeId, e.kind, e.payout, e.pnl, e.funding])).toEqual([
      ['4', 'closed', '980', '-5', '1'],
      ['5', 'take profit', '1070', '90', '-2'],
      ['6', 'liquidated', '0', '-950', '3'],
    ])
    expect(entries[0]).toMatchObject({ pair: 'BTC/USD', closePrice: '101', time: 1_000, txHash: `0x${'bb'.repeat(32)}` })
  })

  it("skips other accounts' settlements and positions the app never saw", () => {
    const logs = [
      log('TradeClosed', { tradeId: 4n, user: OTHER, closePrice: 1n, pnlUsdc: 0n, payoutUsdc: 0n, fee: 0n, fundingOwedUsdc: 0n }),
      log('TradeClosed', { tradeId: 99n, user: ME, closePrice: 1n, pnlUsdc: 0n, payoutUsdc: 0n, fee: 0n, fundingOwedUsdc: 0n }),
    ]
    expect(entriesFromLogs(logs, ME, snapshots, 1_000)).toEqual([])
  })

  it('lets an exact settlement replace a closed-while-away record, newest first', () => {
    const away = awayEntry(snapshot('4'), 2_000)
    expect(away.kind).toBe('closed while away')
    expect(away.payout).toBeUndefined()
    const exact = entriesFromLogs([log('TradeClosed', { tradeId: 4n, user: ME, closePrice: 1n, pnlUsdc: 0n, payoutUsdc: 5n, fee: 0n, fundingOwedUsdc: 0n })], ME, snapshots, 1_500)
    const merged = mergeHistory([away, awayEntry(snapshot('5'), 1_000)], exact)
    expect(merged.map((e) => [e.tradeId, e.kind])).toEqual([
      ['4', 'closed'],
      ['5', 'closed while away'],
    ])
    expect(mergeHistory(merged, [awayEntry(snapshot('4'), 3_000)]).find((e) => e.tradeId === '4')?.kind).toBe('closed')
  })
})
