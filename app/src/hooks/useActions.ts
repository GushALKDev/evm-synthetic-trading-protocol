import { useMemo } from 'react'
import type { Address } from 'viem'
import { bondAbi, engineAbi, faucetCallAbi, solvencyAbi, tokenAbi, vaultCallAbi } from '../lib/abi'
import { errorContextOf, type Model, type PairView, type TradeView } from '../lib/model'
import { freshPriceUpdate, useTx } from './useTx'

export interface OpenArgs {
  pair: PairView
  isLong: boolean
  collateral: bigint
  leverage: bigint
  expectedPrice: bigint
  slippageBps: bigint
  tp: bigint
  sl: bigint
}

/**
 * Every write the app sends, in one place. Calls that read a price carry a DemoPyth update built right before the
 * simulation: engine calls one entry for the trade's pair, the Vault's refresh paths one entry per pair (so a pair
 * whose open interest changes before the call lands is still covered). Each entry costs SINGLE_UPDATE_FEE.
 */
export function useActions(model: Model) {
  const errorContext = useMemo(() => errorContextOf(model), [model])
  const { run, busy } = useTx(errorContext)
  const d = model.deployment
  const { confBps, updateFee } = model.config
  const priceFor = (pairs: PairView[]) => freshPriceUpdate(pairs, confBps, updateFee)

  /** Approves exactly what the next call pulls, if the current allowance is short; false if the approval failed */
  const approveIfNeeded = async (spender: Address, current: bigint, needed: bigint) => {
    if (current >= needed) return { ok: true, approved: false }
    const ok = await run('Approve USDC', 'USDC approved', () => ({ address: d.usdc, abi: tokenAbi, functionName: 'approve', args: [spender, needed] }))
    return { ok, approved: true }
  }

  return {
    busy,

    claimFaucet: () => run('Claim test USDC', 'Test USDC claimed', () => ({ address: d.faucet, abi: faucetCallAbi, functionName: 'claim' })),

    open: async (o: OpenArgs, allowance: bigint) => {
      const approval = await approveIfNeeded(d.engine, allowance, o.collateral)
      if (!approval.ok) return false
      const side = o.isLong ? 'long' : 'short'
      return run(
        `Open ${side}`,
        `${o.isLong ? 'Long' : 'Short'} opened`,
        async () => {
          const { update, value } = await priceFor([o.pair])
          return {
            address: d.engine,
            abi: engineAbi,
            functionName: 'openTrade',
            args: [o.pair.index, o.isLong, o.collateral, Number(o.leverage), o.expectedPrice, Number(o.slippageBps), o.tp, o.sl, update],
            value,
          }
        },
        { afterApproval: approval.approved },
      )
    },

    close: (t: TradeView, expectedPrice: bigint, slippageBps: bigint) =>
      run(`Close #${t.id}`, `Position #${t.id} closed`, async () => {
        const { update, value } = await priceFor([t.pair])
        return { address: d.engine, abi: engineAbi, functionName: 'closeTrade', args: [t.id, expectedPrice, Number(slippageBps), update], value }
      }),

    /** Setting a level reads the price to check it is not already reached; clearing one (0) needs no price */
    setLevel: (t: TradeView, kind: 'tp' | 'sl', price: bigint) => {
      const name = kind === 'tp' ? 'take profit' : 'stop loss'
      const label = price === 0n ? `Clear ${name}` : `Set ${name}`
      const done = price === 0n ? `${kind === 'tp' ? 'Take profit' : 'Stop loss'} cleared` : `${kind === 'tp' ? 'Take profit' : 'Stop loss'} set`
      return run(label, done, async () => {
        const functionName = kind === 'tp' ? 'updateTp' : 'updateSl'
        if (price === 0n) return { address: d.engine, abi: engineAbi, functionName, args: [t.id, 0n, []] }
        const { update, value } = await priceFor([t.pair])
        return { address: d.engine, abi: engineAbi, functionName, args: [t.id, price, update], value }
      })
    },

    liquidate: (t: TradeView) =>
      run(`Liquidate #${t.id}`, `Position #${t.id} liquidated`, async () => {
        const { update, value } = await priceFor([t.pair])
        return { address: d.engine, abi: engineAbi, functionName: 'liquidate', args: [t.id, update], value }
      }),

    executeLimit: (t: TradeView) => {
      const name = t.limit === 'sl' ? 'stop loss' : 'take profit'
      return run(`Execute the ${name} of #${t.id}`, `${t.limit === 'sl' ? 'Stop loss' : 'Take profit'} of #${t.id} executed`, async () => {
        const { update, value } = await priceFor([t.pair])
        return { address: d.engine, abi: engineAbi, functionName: 'executeLimit', args: [t.id, update], value }
      })
    },

    deposit: async (assets: bigint, receiver: Address, allowance: bigint) => {
      const approval = await approveIfNeeded(d.vault, allowance, assets)
      if (!approval.ok) return false
      return run(
        'Deposit USDC',
        'USDC deposited',
        async () => {
          const { update, value } = await priceFor(model.pairs)
          return { address: d.vault, abi: vaultCallAbi, functionName: 'refreshAndDeposit', args: [assets, receiver, update], value }
        },
        { afterApproval: approval.approved },
      )
    },

    requestWithdrawal: (shares: bigint) =>
      run('Request withdrawal', 'Withdrawal requested', () => ({ address: d.vault, abi: vaultCallAbi, functionName: 'requestWithdrawal', args: [shares] })),

    cancelWithdrawal: () => run('Cancel request', 'Request cancelled', () => ({ address: d.vault, abi: vaultCallAbi, functionName: 'cancelWithdrawal' })),

    executeWithdrawal: () =>
      run('Withdraw USDC', 'USDC withdrawn', async () => {
        const { update, value } = await priceFor(model.pairs)
        return { address: d.vault, abi: vaultCallAbi, functionName: 'refreshAndExecuteWithdrawal', args: [update], value }
      }),

    /** Runs the permissionless solvency check after a refresh: when a bonding round is due, this opens it */
    openBondingRound: () =>
      run('Open the bonding round', 'Solvency check run', async () => {
        const { update, value } = await priceFor(model.pairs)
        return { address: d.solvencyManager, abi: solvencyAbi, functionName: 'refreshAndCheckAndAct', args: [update], value }
      }),

    bond: async (usdc: bigint, allowance: bigint) => {
      const approval = await approveIfNeeded(d.bondDepository, allowance, usdc)
      if (!approval.ok) return false
      return run('Bond USDC', 'Bond bought', () => ({ address: d.bondDepository, abi: bondAbi, functionName: 'bond', args: [usdc] }), {
        afterApproval: approval.approved,
      })
    },

    claimBond: (bondId: bigint) =>
      run('Claim SYNTH', 'SYNTH claimed', () => ({ address: d.bondDepository, abi: bondAbi, functionName: 'claim', args: [bondId] })),
  }
}
