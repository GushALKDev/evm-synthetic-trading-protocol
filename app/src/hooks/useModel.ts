import { useMemo } from 'react'
import { useBlock, useConnection } from 'wagmi'
import { buildModel, type Model } from '../lib/model'
import { useProtocolData } from './useProtocolData'

/**
 * The protocol as the app shows it, projected to the latest block's timestamp: what the next call's simulation sees,
 * and a floor for when it lands. Funding accrues per second, so every projection moves with each new block.
 */
export function useModel(): { model: Model | null; error: Error | null; isLoading: boolean } {
  const { address } = useConnection()
  const data = useProtocolData(address)
  const block = useBlock({ watch: true })
  const chainTime = block.data?.timestamp
  const model = useMemo(() => {
    if (!data.config || !data.live || chainTime === undefined) return null
    const account = address && data.account && data.accountTrades ? { address, data: data.account, trades: data.accountTrades } : null
    return buildModel(data.deployment, data.config, data.live, account, chainTime)
  }, [data.deployment, data.config, data.live, data.account, data.accountTrades, address, chainTime])
  return { model, error: (data.error as Error | null) ?? (block.error as Error | null) ?? null, isLoading: data.isLoading }
}
