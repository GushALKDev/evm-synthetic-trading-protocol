// Checks the app's math against the deployed contracts on a local anvil chain, to the wei.
// Run after ./scripts/local-chain.sh:  LOCAL_RPC=http://127.0.0.1:8545 npx vitest run scripts/parity.test.ts
// Every priced call is sent at a pinned timestamp, so the app's projection and the contract see the same second.
// The suite moves the chain forward and reverts it to a snapshot at the end, so it can run again.
import { readFileSync } from 'node:fs'
import { createPublicClient, createWalletClient, http, parseAbi, parseEventLogs, type Abi, type Address, type Hex } from 'viem'
import { foundry } from 'viem/chains'
import { afterAll, beforeAll, describe, expect, it } from 'vitest'
import {
  bondDepositoryAbi,
  chainlinkAbi,
  demoPythAbi,
  faucetAbi,
  oracleAbi,
  spreadManagerAbi,
  tradingEngineAbi,
  tradingStorageAbi,
  vaultAbi,
} from '../src/abi'
import { engineAbi, tokenAbi } from '../src/lib/abi'
import { buildPriceUpdate, mirroredPrice } from '../src/lib/pyth'
import {
  CLOSE_FEE_BPS,
  EXEC_REWARD_BPS,
  FEE_VAULT_SPLIT_BPS,
  LIQUIDATION_THRESHOLD_BPS,
  LIQUIDATOR_MIN_REWARD_BPS,
  LIQUIDATOR_REWARD_BPS,
  MAX_LEVERAGE,
  MAX_PROFIT_MULTIPLIER,
  MIN_COLLATERAL,
  OPEN_FEE_BPS,
  closeOutcome,
  fundingOwedOf,
  limitOutcome,
  liquidationAnswer,
  liquidationCheck,
  liquidatorReward,
  positionSizeWad,
  projectFundingIndexes,
  quoteOpen,
  spreadBps,
  type FundingState,
  type Position,
  type SpreadParams,
} from '../src/lib/trading'
import { assetsForShares, navOf, openPnlLiability, pendingInjection, quoteBond, ratioOf, sharesForAssets, snapshotNetPnl, type PairTotals } from '../src/lib/vault'

const rpc = process.env.LOCAL_RPC
const deployer = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266' as Address
// anvil's default accounts 1 and 3, unlocked on a local node
const alice = '0x70997970C51812dc3A010C7d01b50e0d17dc79C8' as Address
const bob = '0x90F79bf6EB2c4f870365E785982E1f101E93b906' as Address

const mockFeedAbi = parseAbi(['function setAnswer(int256 answer)', 'function setUpdatedAt(uint256 updatedAt)'])

interface LocalDeployment {
  vault: Address
  assistantFund: Address
  tradingStorage: Address
  engine: Address
  spreadManager: Address
  oracle: Address
  bondDepository: Address
  faucet: Address
  usdc: Address
  pyth: Address
}

const E6 = 10n ** 6n
const E18 = 10n ** 18n
const BTC = 0n
const ETH = 1n

describe.skipIf(!rpc)('parity with the contracts on a local chain', () => {
  // Read lazily: the local deployment file is not committed, and a skipped suite still gets collected.
  let d: LocalDeployment
  let snapshot: Hex
  let spreadParams: SpreadParams
  let confBps: bigint
  let fundingFactor: bigint
  const pub = createPublicClient({ chain: foundry, transport: http(rpc) })
  const wallet = createWalletClient({ chain: foundry, transport: http(rpc), account: deployer })

  beforeAll(async () => {
    d = JSON.parse(readFileSync(new URL('../src/config/deployments/31337.json', import.meta.url), 'utf8'))
    snapshot = await pub.request({ method: 'evm_snapshot' as never })
    const read = (functionName: 'baseSpreadBps' | 'impactFactor' | 'volFactor' | 'maxSpreadBps') =>
      pub.readContract({ address: d.spreadManager, abi: spreadManagerAbi, functionName })
    spreadParams = {
      baseSpreadBps: await read('baseSpreadBps'),
      impactFactor: await read('impactFactor'),
      volFactor: await read('volFactor'),
      maxSpreadBps: await read('maxSpreadBps'),
    }
    confBps = await pub.readContract({ address: d.pyth, abi: demoPythAbi, functionName: 'DEMO_CONF_BPS' })
    fundingFactor = BigInt(await pub.readContract({ address: d.engine, abi: tradingEngineAbi, functionName: 'fundingFactor' }))
  })

  afterAll(async () => {
    if (snapshot) await pub.request({ method: 'evm_revert' as never, params: [snapshot] as never })
  })

  /* ---------------------------------------------------------------- */
  /* Chain helpers                                                     */
  /* ---------------------------------------------------------------- */

  const latestTime = async () => (await pub.getBlock()).timestamp

  /** Sends a call from an unlocked account, optionally at a pinned timestamp, and returns its receipt */
  async function send(from: Address, address: Address, abi: Abi | readonly unknown[], functionName: string, args: readonly unknown[], opts: { at?: bigint; value?: bigint; expectRevert?: boolean } = {}) {
    if (opts.at !== undefined) await pub.request({ method: 'evm_setNextBlockTimestamp' as never, params: [Number(opts.at)] as never })
    // Fixed gas: an estimate made at the previous block's timestamp can miss the funding accrual the call pays for.
    const hash = await wallet.writeContract({ account: from, address, abi: abi as Abi, functionName, args, value: opts.value, gas: 5_000_000n } as never)
    const receipt = await pub.waitForTransactionReceipt({ hash })
    expect(receipt.status, `${functionName} from ${from}`).toBe(opts.expectRevert ? 'reverted' : 'success')
    return receipt
  }

  /** Mines an empty block at a given time, so an update built next is stamped one second before the call lands */
  async function mineAt(time: bigint) {
    await pub.request({ method: 'evm_setNextBlockTimestamp' as never, params: [Number(time)] as never })
    await pub.request({ method: 'evm_mine' as never })
  }

  async function feedOf(pair: bigint) {
    return pub.readContract({ address: d.oracle, abi: oracleAbi, functionName: 'getPairFeed', args: [pair] })
  }

  /** Moves a mock Chainlink answer and stamps it at the latest block, as a feed round would */
  async function setAnswer(pair: bigint, answer: bigint) {
    const feed = (await feedOf(pair)).chainlinkFeed
    await send(deployer, feed, mockFeedAbi, 'setAnswer', [answer])
    await send(deployer, feed, mockFeedAbi, 'setUpdatedAt', [await latestTime()])
  }

  /** What the app reads before a priced call: answer, decimals, and the oracle's view of them */
  async function priceOf(pair: bigint) {
    const feed = await feedOf(pair)
    const [, answer] = await pub.readContract({ address: feed.chainlinkFeed, abi: chainlinkAbi, functionName: 'latestRoundData' })
    const decimals = await pub.readContract({ address: feed.chainlinkFeed, abi: chainlinkAbi, functionName: 'decimals' })
    return { answer, decimals, pythFeedId: feed.pythFeedId, ...mirroredPrice(answer, decimals, confBps) }
  }

  /** The update the app builds: one entry per pair, published at the latest block's timestamp */
  async function update(pairs: bigint[]) {
    const readings = await Promise.all(pairs.map(priceOf))
    return buildPriceUpdate(readings, confBps, await latestTime())
  }

  async function allPairs() {
    const count = await pub.readContract({ address: d.tradingStorage, abi: tradingStorageAbi, functionName: 'getPairsCount' })
    return Array.from({ length: Number(count) }, (_, i) => BigInt(i))
  }

  async function fundingState(pair: bigint): Promise<FundingState> {
    const r = (functionName: 'getOpenInterestLong' | 'getOpenInterestShort' | 'getFundingLastUpdated') =>
      pub.readContract({ address: d.tradingStorage, abi: tradingStorageAbi, functionName, args: [pair] })
    const index = (isLong: boolean) =>
      pub.readContract({ address: d.tradingStorage, abi: tradingStorageAbi, functionName: 'getCumulativeFundingIndex', args: [pair, isLong] })
    return { oiLong: await r('getOpenInterestLong'), oiShort: await r('getOpenInterestShort'), longIndex: await index(true), shortIndex: await index(false), lastUpdated: await r('getFundingLastUpdated') }
  }

  async function openInterest(pair: bigint) {
    return pub.readContract({ address: d.tradingStorage, abi: tradingStorageAbi, functionName: 'getOpenInterest', args: [pair] })
  }

  async function volatility(pair: bigint) {
    return pub.readContract({ address: d.spreadManager, abi: spreadManagerAbi, functionName: 'getPairVolatility', args: [pair] })
  }

  async function position(id: bigint): Promise<Position & { pairIndex: bigint; entryIndex: bigint }> {
    const t = await pub.readContract({ address: d.tradingStorage, abi: tradingStorageAbi, functionName: 'getTrade', args: [id] })
    const entryIndex = await pub.readContract({ address: d.tradingStorage, abi: tradingStorageAbi, functionName: 'getTradeFundingIndex', args: [id] })
    return { isLong: t.isLong, collateral: t.collateral, leverage: BigInt(t.leverage), openPrice: t.openPrice, tp: t.tp, sl: t.sl, pairIndex: BigInt(t.pairIndex), entryIndex }
  }

  /** Funding owed at `time`, projected the way the app does it */
  async function projectedFunding(id: bigint, time: bigint) {
    const p = await position(id)
    const idx = projectFundingIndexes(await fundingState(p.pairIndex), time, fundingFactor)
    return fundingOwedOf(positionSizeWad(p.collateral, p.leverage), p.isLong ? idx.long : idx.short, p.entryIndex)
  }

  async function fund(account: Address, amount: bigint) {
    await send(deployer, d.faucet, faucetAbi, 'mint', [account, amount])
    await send(account, d.usdc, tokenAbi, 'approve', [d.engine, 2n ** 255n])
    await send(account, d.usdc, tokenAbi, 'approve', [d.vault, 2n ** 255n])
    await send(account, d.usdc, tokenAbi, 'approve', [d.bondDepository, 2n ** 255n])
  }

  /** Opens at a pinned time and checks the quote against TradeOpened */
  async function openAndCheck(account: Address, pair: bigint, isLong: boolean, collateral: bigint, leverage: bigint) {
    const at = (await latestTime()) + 5n
    const p = await priceOf(pair)
    const oi = await openInterest(pair)
    const vol = await volatility(pair)
    const before = await fundingState(pair)
    const quote = quoteOpen({ isLong, collateral, leverage, tp: 0n, sl: 0n }, p.price, (x) => spreadBps(spreadParams, vol, x), oi, 2n ** 127n)
    const receipt = await send(account, d.engine, tradingEngineAbi, 'openTrade', [Number(pair), isLong, collateral, Number(leverage), quote.executionPrice, 10, 0n, 0n, await update([pair])], { at, value: 1n })
    const [event] = parseEventLogs({ abi: tradingEngineAbi, logs: receipt.logs, eventName: 'TradeOpened' })
    expect(event.args.openPrice).toBe(quote.executionPrice)
    expect(event.args.fee).toBe(quote.fee)
    expect(event.args.collateral).toBe(quote.effectiveCollateral)
    expect(await openInterest(pair)).toBe(quote.oiAfter)
    // The entry index is the side's index accrued to the open's second
    const projected = projectFundingIndexes(before, at, fundingFactor)
    const entry = await pub.readContract({ address: d.tradingStorage, abi: tradingStorageAbi, functionName: 'getTradeFundingIndex', args: [event.args.tradeId] })
    expect(entry).toBe(isLong ? projected.long : projected.short)
    return event.args.tradeId
  }

  /* ---------------------------------------------------------------- */
  /* Tests                                                             */
  /* ---------------------------------------------------------------- */

  it('mirrors the engine constants', async () => {
    const c = (functionName: string) => pub.readContract({ address: d.engine, abi: tradingEngineAbi, functionName } as never) as Promise<bigint | number>
    expect(BigInt(await c('MAX_PROFIT_MULTIPLIER'))).toBe(MAX_PROFIT_MULTIPLIER)
    expect(BigInt(await c('MAX_LEVERAGE'))).toBe(MAX_LEVERAGE)
    expect(BigInt(await c('MIN_COLLATERAL'))).toBe(MIN_COLLATERAL)
    expect(BigInt(await c('OPEN_FEE_BPS'))).toBe(OPEN_FEE_BPS)
    expect(BigInt(await c('CLOSE_FEE_BPS'))).toBe(CLOSE_FEE_BPS)
    expect(BigInt(await c('FEE_VAULT_SPLIT_BPS'))).toBe(FEE_VAULT_SPLIT_BPS)
    expect(BigInt(await c('LIQUIDATION_THRESHOLD_BPS'))).toBe(LIQUIDATION_THRESHOLD_BPS)
    expect(BigInt(await c('LIQUIDATOR_REWARD_BPS'))).toBe(LIQUIDATOR_REWARD_BPS)
    expect(BigInt(await c('LIQUIDATOR_MIN_REWARD_BPS'))).toBe(LIQUIDATOR_MIN_REWARD_BPS)
    expect(BigInt(await c('EXEC_REWARD_BPS'))).toBe(EXEC_REWARD_BPS)
  })

  it('computes the spread the SpreadManager reports at any open interest', async () => {
    for (const oi of [0n, 123_456n * E18, 10_000_000n * E18, 3n * 10n ** 26n + 7n, 10n ** 30n]) {
      const onChain = await pub.readContract({ address: d.spreadManager, abi: spreadManagerAbi, functionName: 'getSpreadBps', args: [BTC, oi] })
      expect(onChain).toBe(spreadBps(spreadParams, await volatility(BTC), oi))
    }
  })

  it('quotes an open to the wei: execution price, fee, size and the entry funding index', async () => {
    await fund(alice, 50_000n * E6)
    await setAnswer(BTC, 100_123_45678901n)
    await openAndCheck(alice, BTC, true, 1_234_567_891n, 7n)
    await openAndCheck(alice, BTC, false, 2_000n * E6, 33n)
  })

  it('settles a close to the wei: price, PnL, funding, fee and payout', async () => {
    await fund(bob, 20_000n * E6)
    await setAnswer(ETH, 4_000n * 10n ** 8n)
    const id = await openAndCheck(bob, ETH, false, 3_000n * E6, 12n)

    // Funding accrues on the imbalanced seed book for a few hours
    await pub.request({ method: 'evm_increaseTime' as never, params: [3 * 3600 + 17] as never })
    await setAnswer(ETH, 3_871_98765432n)
    const at = (await latestTime()) + 3n
    const p = await priceOf(ETH)
    const pos = await position(id)
    const spread = spreadBps(spreadParams, await volatility(ETH), await openInterest(ETH))
    const expected = closeOutcome(pos, p.price, spread, await projectedFunding(id, at))
    const receipt = await send(bob, d.engine, tradingEngineAbi, 'closeTrade', [id, expected.executionPrice, 10, await update([ETH])], { at, value: 1n })
    const [event] = parseEventLogs({ abi: tradingEngineAbi, logs: receipt.logs, eventName: 'TradeClosed' })
    expect(event.args.closePrice).toBe(expected.executionPrice)
    expect(event.args.pnlUsdc).toBe(expected.pnl)
    expect(event.args.fundingOwedUsdc).toBe(expected.fundingOwed)
    expect(event.args.fee).toBe(expected.closeFee)
    expect(event.args.payoutUsdc).toBe(expected.payout)
    expect(expected.fundingOwed).not.toBe(0n)
  })

  it('finds the liquidation price the contract uses, and pays the reward it computes', async () => {
    await fund(alice, 10_000n * E6)
    await setAnswer(ETH, 4_000n * 10n ** 8n)
    const id = await openAndCheck(alice, ETH, true, 1_000n * E6, 40n)
    const pos = await position(id)
    const spread = spreadBps(spreadParams, await volatility(ETH), await openInterest(ETH))
    // Funding moves the boundary, so each attempt projects it to the second it lands
    const boundaryAt = async (time: bigint) => liquidationAnswer(pos, await projectedFunding(id, time), spread, 8, confBps, 4_000n * 10n ** 8n)!
    const t0 = await latestTime()
    const missAt = t0 + 600n
    const hitAt = t0 + 700n

    // One unit above the boundary: liquidate reverts with NotLiquidatable
    await setAnswer(ETH, (await boundaryAt(missAt)) + 1n)
    await mineAt(missAt - 1n)
    const missUpdate = await update([ETH])
    const missed = await send(deployer, d.engine, tradingEngineAbi, 'liquidate', [id, missUpdate], { at: missAt, value: 1n, expectRevert: true })
    const replay = await pub
      .simulateContract({ account: deployer, address: d.engine, abi: engineAbi, functionName: 'liquidate', args: [id, missUpdate], value: 1n, blockNumber: missed.blockNumber })
      .then(() => null, (err: unknown) => (err as { cause?: { data?: { errorName?: string } } }).cause?.data?.errorName)
    expect(replay).toBe('NotLiquidatable')

    // At the boundary: liquidated, at the execution price and with the reward the app computes
    await setAnswer(ETH, await boundaryAt(hitAt))
    await mineAt(hitAt - 1n)
    const q = await priceOf(ETH)
    const check = liquidationCheck(pos, q.price, q.conf, spread, await projectedFunding(id, hitAt))
    expect(check.liquidatable).toBe(true)
    const receipt = await send(deployer, d.engine, tradingEngineAbi, 'liquidate', [id, await update([ETH])], { at: hitAt, value: 1n })
    const [event] = parseEventLogs({ abi: tradingEngineAbi, logs: receipt.logs, eventName: 'TradeLiquidated' })
    expect(event.args.closePrice).toBe(check.executionPrice)
    expect(event.args.pnlUsdc).toBe(check.pnl)
    expect(event.args.liquidatorReward).toBe(liquidatorReward(pos.collateral, check.loss))
    expect(event.args.vaultAmount).toBe(pos.collateral - liquidatorReward(pos.collateral, check.loss))
  })

  it('settles a triggered take profit to the wei, executor reward included', async () => {
    await fund(bob, 10_000n * E6)
    await setAnswer(BTC, 100_000n * 10n ** 8n)
    const id = await openAndCheck(bob, BTC, true, 2_000n * E6, 10n)
    await send(bob, d.engine, tradingEngineAbi, 'updateTp', [id, 101_000n * E18, await update([BTC])], { value: 1n })

    await pub.request({ method: 'evm_increaseTime' as never, params: [1800] as never })
    await setAnswer(BTC, 101_250n * 10n ** 8n)
    const at = (await latestTime()) + 2n
    const p = await priceOf(BTC)
    const pos = await position(id)
    const spread = spreadBps(spreadParams, await volatility(BTC), await openInterest(BTC))
    const expected = limitOutcome(pos, p.price, spread, await projectedFunding(id, at))
    const receipt = await send(alice, d.engine, tradingEngineAbi, 'executeLimit', [id, await update([BTC])], { at, value: 1n })
    const [event] = parseEventLogs({ abi: tradingEngineAbi, logs: receipt.logs, eventName: 'LimitExecuted' })
    expect(event.args.isTp).toBe(true)
    expect(event.args.closePrice).toBe(expected.executionPrice)
    expect(event.args.pnlUsdc).toBe(expected.pnl)
    expect(event.args.fundingOwedUsdc).toBe(expected.fundingOwed)
    expect(event.args.executorReward).toBe(expected.executorReward)
    expect(event.args.payoutUsdc).toBe(expected.traderPayout)
  })

  /** The snapshot a refresh at the current prices would store, and the NAV it leaves */
  async function liveVault() {
    const pairs = await allPairs()
    const priced = await Promise.all(
      pairs.map(async (i) => {
        const totals = (await pub.readContract({ address: d.tradingStorage, abi: tradingStorageAbi, functionName: 'getPairOpenTotals', args: [i] })) as PairTotals
        const { price, conf } = await priceOf(i)
        return { totals, price, conf }
      }),
    )
    const netPnl = snapshotNetPnl(priced)
    const [openTrades] = await pub.readContract({ address: d.tradingStorage, abi: tradingStorageAbi, functionName: 'getPositionState' })
    const balance = await pub.readContract({ address: d.usdc, abi: tokenAbi, functionName: 'balanceOf', args: [d.vault] })
    const supply = await pub.readContract({ address: d.vault, abi: vaultAbi, functionName: 'totalSupply' })
    return { netPnl, balance, supply, nav: navOf(balance, openPnlLiability(BigInt(openTrades), netPnl)) }
  }

  it('values open PnL as the snapshot does, and prices deposit shares from it', async () => {
    await setAnswer(BTC, 102_345_67890123n)
    await setAnswer(ETH, 3_950_12345678n)
    await setAnswer(2n, 20_98765432n)
    await fund(alice, 30_000n * E6)
    const live = await liveVault()
    const reserve = await pub.readContract({ address: d.usdc, abi: tokenAbi, functionName: 'balanceOf', args: [d.assistantFund] })
    const assets = 12_345_678_901n
    const receipt = await send(alice, d.vault, vaultAbi, 'refreshAndDeposit', [assets, alice, await update(await allPairs())], { value: 3n })
    const [refreshed] = parseEventLogs({ abi: vaultAbi, logs: receipt.logs, eventName: 'PnlSnapshotRefreshed' })
    expect(refreshed.args.netPnl).toBe(live.netPnl)
    const [deposit] = parseEventLogs({ abi: vaultAbi, logs: receipt.logs, eventName: 'Deposit' })
    // The deposit runs the pending reserve injection first, so the shares are priced at the NAV after it
    const injected = pendingInjection(live.nav, live.supply, reserve)
    expect(deposit.args.shares).toBe(sharesForAssets(assets, live.supply, live.nav + injected))

    const ratio = await pub.readContract({ address: d.vault, abi: vaultAbi, functionName: 'realisedCollateralizationRatio' })
    const after = await liveVault()
    expect(ratio).toBe(ratioOf(after.balance, after.supply))
  })

  it('pays a withdrawal at the NAV of the refresh in the same call', async () => {
    const shares = (await pub.readContract({ address: d.vault, abi: vaultAbi, functionName: 'balanceOf', args: [alice] })) / 2n
    await send(alice, d.vault, vaultAbi, 'requestWithdrawal', [shares])
    const unlock = await pub.readContract({ address: d.vault, abi: vaultAbi, functionName: 'getWithdrawalUnlockEpoch', args: [alice] })
    const deployedAt = await pub.readContract({ address: d.vault, abi: vaultAbi, functionName: 'DEPLOY_TIMESTAMP' })
    await pub.request({ method: 'evm_setNextBlockTimestamp' as never, params: [Number(deployedAt + unlock * 86_400n + 60n)] as never })
    await pub.request({ method: 'evm_mine' as never })
    await setAnswer(BTC, 99_876_54321098n)
    await setAnswer(ETH, 4_012_34567890n)
    await setAnswer(2n, 21_12345678n)
    const live = await liveVault()
    const receipt = await send(alice, d.vault, vaultAbi, 'refreshAndExecuteWithdrawal', [await update(await allPairs())], { value: 3n })
    const [executed] = parseEventLogs({ abi: vaultAbi, logs: receipt.logs, eventName: 'WithdrawalExecuted' })
    expect(executed.args.assets).toBe(assetsForShares(shares, live.supply, live.nav))
  })

  it('quotes bonds as the depository does', async () => {
    const referencePrice = await pub.readContract({ address: d.bondDepository, abi: bondDepositoryAbi, functionName: 'referencePrice' })
    const discountBps = await pub.readContract({ address: d.bondDepository, abi: bondDepositoryAbi, functionName: 'discountBps' })
    for (const usdc of [1n, 999_999n, 10_000n * E6, 123_456_789_012n]) {
      const onChain = await pub.readContract({ address: d.bondDepository, abi: bondDepositoryAbi, functionName: 'quoteBond', args: [usdc] })
      expect(onChain).toBe(quoteBond(usdc, referencePrice, discountBps))
    }
  })
})
