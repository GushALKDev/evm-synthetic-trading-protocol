import { useQuery } from '@tanstack/react-query'
import { parseAbi, type Address } from 'viem'
import { readContract, readContracts } from 'wagmi/actions'
import { chain } from '../config/chain'
import type { OracleRound, Timeframe } from '../lib/chart'
import { wagmiConfig } from '../wagmi'

const roundsAbi = parseAbi([
  'function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)',
  'function getRoundData(uint80 roundId) view returns (uint80, int256, uint256, uint256, uint80)',
])

/** Rounds per multicall, and the most the chart reads for one view (Base Sepolia publishes about 200 a day) */
const BATCH = 250
const MAX_BATCHES = 8
/** A Chainlink proxy round id is the phase in the top bits and the aggregator's round in the low 64 */
const AGGREGATOR_ROUND = (1n << 64n) - 1n

/**
 * Reads a feed's rounds back from the latest, until one is older than `since` (kept, as the price in force when the
 * window opens), a round is missing or the phase starts. A missing round reverts on a Chainlink aggregator, so a failed
 * read ends the history rather than the chart.
 */
export async function fetchRounds(feed: Address, since: bigint): Promise<OracleRound[]> {
  const [latestId, answer, , updatedAt] = await readContract(wagmiConfig, { address: feed, abi: roundsAbi, functionName: 'latestRoundData' })
  const rounds: OracleRound[] = [{ answer, updatedAt }]
  let next = latestId - 1n
  for (let batch = 0; batch < MAX_BATCHES && updatedAt >= since; batch++) {
    const ids: bigint[] = []
    while (ids.length < BATCH && (next & AGGREGATOR_ROUND) > 0n) ids.push(next--)
    if (ids.length === 0) break
    const results = await readContracts(wagmiConfig, {
      allowFailure: true,
      contracts: ids.map((id) => ({ address: feed, abi: roundsAbi, functionName: 'getRoundData', args: [id] }) as const),
    })
    let ended = false
    for (const r of results) {
      if (r.status !== 'success' || r.result[3] === 0n) {
        ended = true
        break
      }
      rounds.push({ answer: r.result[1], updatedAt: r.result[3] })
      if (r.result[3] < since) {
        ended = true
        break
      }
    }
    if (ended) break
  }
  return rounds
}

/** The rounds a chart view needs, refreshed every two minutes; the latest answer comes from the live reads in between */
export function usePriceHistory(feed: Address, timeframe: Timeframe, chainTime: bigint) {
  // Rounded to the minute, so the query key does not change with every block
  const since = ((chainTime - BigInt(timeframe.horizon)) / 60n) * 60n
  return useQuery({
    queryKey: ['oracle-rounds', chain.id, feed, timeframe.horizon],
    queryFn: () => fetchRounds(feed, since),
    staleTime: 120_000,
    refetchInterval: 120_000,
  })
}
