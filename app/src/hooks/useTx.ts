import { useQueryClient } from '@tanstack/react-query'
import { useCallback, useState } from 'react'
import type { Abi, Address, Hex } from 'viem'
import { BaseError, ContractFunctionRevertedError, encodeFunctionData, ExecutionRevertedError } from 'viem'
import { useConnection } from 'wagmi'
import { estimateGas, getBlock, readContracts, simulateContract, waitForTransactionReceipt, writeContract } from 'wagmi/actions'
import { explorerTx } from '../config/chain'
import { chainlinkAbi } from '../lib/abi'
import { describeError, LandedRevertError, type ErrorContext } from '../lib/errors'
import type { PairView } from '../lib/model'
import { buildPriceUpdate } from '../lib/pyth'
import { wagmiConfig } from '../wagmi'
import { useToasts } from './useToasts'

export interface ContractCall {
  address: Address
  abi: Abi | readonly unknown[]
  functionName: string
  args?: readonly unknown[]
  value?: bigint
}

/** Tries, and the pause between them, for a call that follows an approval while the RPC catches up */
const CATCH_UP_TRIES = 5
const CATCH_UP_MS = 2_000

/**
 * Gas margin over our own estimate. The node estimates at the latest block's timestamp: when a pair's funding was
 * updated in that same second, _updateFundingIndex is a no-op in the estimate but writes both indexes and the
 * timestamp once the call lands a second later, which from zero indexes means two fresh slots. The worst case
 * measured on openTrade is 192,319 gas estimated against 260,807 landed
 * (script/testnet/test/DeployTestnet.t.sol, test_gas_theAppMarginCoversTheFundingAccrualWrite).
 */
export const gasWithMargin = (estimate: bigint) => (estimate * 125n) / 100n + 50_000n

const isRevert = (err: unknown) =>
  err instanceof BaseError && !!err.walk((e) => e instanceof ContractFunctionRevertedError || e instanceof ExecutionRevertedError)

/**
 * Reads the latest Chainlink answers of the given pairs and the latest block's timestamp, and returns the DemoPyth
 * update for a price-dependent call plus the fee to attach: one entry per pair, SINGLE_UPDATE_FEE each. The first
 * oracle read of the call pays for every entry; any surplus is refunded.
 */
export async function freshPriceUpdate(pairs: PairView[], confBps: bigint, singleUpdateFee: bigint): Promise<{ update: Hex[]; value: bigint }> {
  const [block, rounds] = await Promise.all([
    getBlock(wagmiConfig, { blockTag: 'latest' }),
    readContracts(wagmiConfig, {
      allowFailure: false,
      contracts: pairs.map((p) => ({ address: p.chainlinkFeed, abi: chainlinkAbi, functionName: 'latestRoundData' }) as const),
    }),
  ])
  const readings = pairs.map((p, i) => ({ pythFeedId: p.pythFeedId, answer: (rounds[i] as readonly bigint[])[1], decimals: p.decimals }))
  const update = buildPriceUpdate(readings, confBps, block.timestamp)
  return { update, value: singleUpdateFee * BigInt(update.length) }
}

/** Builds, simulates and estimates a call: everything before the wallet asks for a signature */
async function prepare(build: () => Promise<ContractCall> | ContractCall, account: Address) {
  const call = await build()
  // Simulating first surfaces a revert, decoded, before the wallet asks for a signature.
  const { request } = await simulateContract(wagmiConfig, { ...call, account } as never)
  const estimate = await estimateGas(wagmiConfig, {
    account,
    to: call.address,
    data: encodeFunctionData({ abi: call.abi as Abi, functionName: call.functionName, args: call.args as unknown[] }),
    value: call.value,
  })
  return { request, gas: gasWithMargin(estimate) }
}

/** Simulates, sends and confirms one call at a time, reporting each step in a toast */
export function useTx(errorContext: ErrorContext) {
  const { address } = useConnection()
  const toasts = useToasts()
  const queryClient = useQueryClient()
  const [busy, setBusy] = useState<string | null>(null)

  const run = useCallback(
    async (label: string, done: string, build: () => Promise<ContractCall> | ContractCall, opts: { afterApproval?: boolean } = {}): Promise<boolean> => {
      if (!address) return false
      setBusy(label)
      const id = toasts.push({ tone: 'pending', title: label, body: 'Checking the call against the chain…' })
      try {
        // A public RPC spreads requests over several nodes, so the call right after an approval can reach one that
        // has not imported the approval's block yet and revert on the old allowance. That call retries a revert for a
        // few blocks before reporting it, rebuilding it each time so its price update stays fresh.
        let prepared
        for (let attempt = 1; !prepared; attempt++) {
          try {
            prepared = await prepare(build, address)
          } catch (err) {
            if (!opts.afterApproval || attempt >= CATCH_UP_TRIES || !isRevert(err)) throw err
            await new Promise((r) => setTimeout(r, CATCH_UP_MS))
          }
        }
        const { request, gas } = prepared
        toasts.update(id, { body: 'Confirm it in your wallet.' })
        const hash = await writeContract(wagmiConfig, { ...(request as object), gas } as never)
        toasts.update(id, { body: 'Waiting for the block…', href: explorerTx(hash) })
        let receipt
        try {
          receipt = await waitForTransactionReceipt(wagmiConfig, { hash })
        } catch {
          // The transaction was sent, but its outcome could not be read: do not guess either way.
          toasts.update(id, {
            tone: 'error',
            title: `${label}: outcome unknown`,
            body: 'The transaction was sent but its result could not be read from the RPC. Check it on the explorer before trying again.',
          })
          await queryClient.invalidateQueries()
          return false
        }
        if (receipt.status !== 'success') throw new LandedRevertError()
        toasts.update(id, { tone: 'success', title: done, body: undefined })
        await queryClient.invalidateQueries()
        return true
      } catch (err) {
        console.error(err)
        toasts.update(id, { tone: 'error', title: `${label} failed`, body: describeError(err, errorContext) })
        return false
      } finally {
        setBusy(null)
      }
    },
    [address, toasts, queryClient, errorContext],
  )

  return { run, busy }
}
