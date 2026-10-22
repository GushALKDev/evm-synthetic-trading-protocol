// Drives the local anvil chain from the end-to-end tests: moves the mock Chainlink feeds, moves time and funds
// accounts. Every account here is one of anvil's default accounts, unlocked by the node, so no key is used.
import { readFileSync } from 'node:fs'
import { createPublicClient, createWalletClient, http, parseAbi, type Abi, type Address, type Hex } from 'viem'
import { foundry } from 'viem/chains'
import { chainlinkAbi, oracleAbi, tradingEngineAbi, tradingStorageAbi, vaultAbi } from '../src/abi'
import { faucetCallAbi, tokenAbi } from '../src/lib/abi'
import { buildPriceUpdate } from '../src/lib/pyth'

const rpc = process.env.LOCAL_RPC ?? 'http://127.0.0.1:8545'
export const DEPLOYER = '0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266' as Address
// anvil's default account 5: a trader outside the app whose winning trade drains the vault
export const WHALE = '0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc' as Address

export const d = JSON.parse(readFileSync(new URL('../src/config/deployments/31337.json', import.meta.url), 'utf8')) as Record<string, Address>
// anvil can answer a send before it mines the block; a 50 ms poll keeps a missed first look from costing 4 s
export const pub = createPublicClient({ chain: foundry, transport: http(rpc), pollingInterval: 50 })
const wallet = createWalletClient({ chain: foundry, transport: http(rpc) })
const mockFeedAbi = parseAbi(['function setAnswer(int256 answer)', 'function setUpdatedAt(uint256 updatedAt)'])

export const rpcCall = (method: string, params: unknown[] = []) => pub.request({ method: method as never, params: params as never })

export async function send(from: Address, address: Address, abi: Abi | readonly unknown[], functionName: string, args: readonly unknown[] = [], value?: bigint) {
  const hash = await wallet.writeContract({ account: from, address, abi: abi as Abi, functionName, args, value, gas: 5_000_000n } as never)
  const receipt = await pub.waitForTransactionReceipt({ hash })
  if (receipt.status !== 'success') throw new Error(`${functionName} reverted`)
  return receipt
}

export const latestTime = async () => (await pub.getBlock()).timestamp

async function feedOf(pair: number) {
  return pub.readContract({ address: d.oracle, abi: oracleAbi, functionName: 'getPairFeed', args: [BigInt(pair)] })
}

export async function answerOf(pair: number) {
  const [, answer] = await pub.readContract({ address: (await feedOf(pair)).chainlinkFeed, abi: chainlinkAbi, functionName: 'latestRoundData' })
  return answer
}

/** Moves a mock Chainlink answer and stamps it at the latest block, as a feed round would */
export async function setPrice(pair: number, answer: bigint) {
  const feed = (await feedOf(pair)).chainlinkFeed
  await send(DEPLOYER, feed, mockFeedAbi, 'setAnswer', [answer])
  await send(DEPLOYER, feed, mockFeedAbi, 'setUpdatedAt', [await latestTime()])
}

/** Moves a pair's price by a fraction in basis points (+300 is 3% up) */
export async function movePrice(pair: number, bps: bigint) {
  await setPrice(pair, ((await answerOf(pair)) * (10_000n + bps)) / 10_000n)
}

/** Ages a feed past its window, so the oracle treats the anchor as stale */
export async function makeStale(pair: number) {
  const feed = (await feedOf(pair)).chainlinkFeed
  await send(DEPLOYER, feed, mockFeedAbi, 'setUpdatedAt', [(await latestTime()) - 4_000n])
}

/** Stamps every feed at the latest block, keeping its answer */
export async function refreshFeeds() {
  for (const pair of [0, 1, 2]) {
    const feed = (await feedOf(pair)).chainlinkFeed
    await send(DEPLOYER, feed, mockFeedAbi, 'setUpdatedAt', [await latestTime()])
  }
}

/** Moves chain time to a given timestamp, mines, and refreshes the feeds */
export async function warpTo(time: bigint) {
  await rpcCall('evm_setNextBlockTimestamp', [Number(time)])
  await rpcCall('evm_mine')
  await refreshFeeds()
}

export async function warp(seconds: bigint) {
  await warpTo((await latestTime()) + seconds)
}

/** The unlock time of an account's withdrawal request */
export async function unlockTime(account: Address) {
  const epoch = await pub.readContract({ address: d.vault, abi: vaultAbi, functionName: 'getWithdrawalUnlockEpoch', args: [account] })
  const deployed = await pub.readContract({ address: d.vault, abi: vaultAbi, functionName: 'DEPLOY_TIMESTAMP' })
  return deployed + epoch * 86_400n
}

export async function realisedRatio() {
  return pub.readContract({ address: d.vault, abi: vaultAbi, functionName: 'realisedCollateralizationRatio' })
}

async function update(pair: number): Promise<Hex[]> {
  const f = await feedOf(pair)
  const decimals = await pub.readContract({ address: f.chainlinkFeed, abi: chainlinkAbi, functionName: 'decimals' })
  return buildPriceUpdate([{ pythFeedId: f.pythFeedId, answer: await answerOf(pair), decimals }], 5n, await latestTime())
}

/** Liquidates a position from the deployer's account, outside the app, as a keeper or bot would */
export async function liquidateAs(tradeId: number, pair: number) {
  await send(DEPLOYER, d.engine, tradingEngineAbi, 'liquidate', [BigInt(tradeId), await update(pair)], 1n)
}

/** A large BTC long that wins 7% and closes, taking more than 5% of the vault: the realised ratio drops under 95% */
export async function whaleWins() {
  await send(DEPLOYER, d.faucet, faucetCallAbi, 'mint', [WHALE, 100_000_000_000n])
  await send(WHALE, d.usdc, tokenAbi, 'approve', [d.engine, 100_000_000_000n])
  const price = (await answerOf(0)) * 10n ** 10n
  await send(WHALE, d.engine, tradingEngineAbi, 'openTrade', [0, true, 100_000_000_000n, 10, price, 1_000, 0n, 0n, await update(0)], 1n)
  const id = (await pub.readContract({ address: d.tradingStorage, abi: tradingStorageAbi, functionName: 'getTradeCounter' })) - 1
  await movePrice(0, 700n)
  const exit = (await answerOf(0)) * 10n ** 10n
  await send(WHALE, d.engine, tradingEngineAbi, 'closeTrade', [BigInt(id), exit, 1_000, await update(0)], 1n)
}
