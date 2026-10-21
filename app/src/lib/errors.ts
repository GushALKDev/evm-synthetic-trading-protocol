import { BaseError, ContractFunctionRevertedError, InsufficientFundsError, UserRejectedRequestError, type Hex } from 'viem'
import { chain } from '../config/chain'
import { formatCompact, formatFixed, formatPct, formatPrice, relativeTime } from './format'

export interface ErrorContext {
  pairName: (pairIndex: bigint) => string
  pairOfFeedId: (feedId: Hex) => string
  pairOfChainlinkFeed: (feed: string) => string
  maxPriceAge: bigint
  /** Unix time an epoch of the Vault starts at */
  epochStart: (epoch: bigint) => bigint
}

export const noErrorContext: ErrorContext = {
  pairName: () => 'this pair',
  pairOfFeedId: () => 'this pair',
  pairOfChainlinkFeed: () => 'this pair',
  maxPriceAge: 30n,
  epochStart: () => 0n,
}

/** The transaction passed simulation but reverted once mined, so nothing changed */
export class LandedRevertError extends Error {
  constructor() {
    super('The transaction reverted when it landed, so nothing changed. Prices or positions may have moved: try again.')
    this.name = 'LandedRevertError'
  }
}

const usdc = (v: unknown) => `${formatFixed(v as bigint, 6, 2)} USDC`
const shares = (v: unknown) => `${formatFixed(v as bigint, 18, 2)} sUSDC`
const price = (v: unknown) => formatPrice(v as bigint)

/**
 * Turns a failed simulation or transaction into one sentence that says what happened and, where it helps, what to
 * do. Contract errors are decoded by name from the combined ABI of every contract the call reaches.
 */
export function describeError(err: unknown, ctx: ErrorContext): string {
  if (err instanceof LandedRevertError) return err.message
  if (!(err instanceof BaseError)) return err instanceof Error ? err.message : 'The request failed.'

  if (err.walk((e) => e instanceof UserRejectedRequestError)) return 'You rejected the request in your wallet.'
  if (err.walk((e) => e instanceof InsufficientFundsError))
    return `Your wallet needs ${chain.name} ETH to pay for gas. Get some from a faucet and try again.`

  const reverted = err.walk((e) => e instanceof ContractFunctionRevertedError) as ContractFunctionRevertedError | null
  const name = reverted?.data?.errorName
  const a = (reverted?.data?.args ?? []) as readonly unknown[]

  switch (name) {
    // Trading engine
    case 'BelowMinCollateral':
      return 'Collateral must be at least 10 USDC.'
    case 'ZeroLeverage':
      return 'Leverage must be at least 1x.'
    case 'LeverageExceedsMax':
      return `Leverage ${a[0]}x is above the maximum of ${a[1]}x.`
    case 'PairNotActive':
      return `${ctx.pairName(BigInt(a[0] as number))} is not open for new trades right now.`
    case 'NotTradeOwner':
      return 'Only the trader who opened this position can close it or change its levels.'
    case 'TradeNotFound':
      return `Trade #${a[0]} is no longer open: it was closed, liquidated or executed.`
    case 'SlippageExceeded':
      return `The execution price would be ${price(a[0])}, more than ${Number(a[2]) / 100}% away from the ${price(a[1])} quoted. Check the new quote and try again.`
    case 'TpAlreadyTriggered':
      return `The take profit ${price(a[0])} is already reached at the current price, ${price(a[1])}.`
    case 'SlAlreadyTriggered':
      return `The stop loss ${price(a[0])} is already reached at the current price, ${price(a[1])}.`
    case 'NotLiquidatable':
      return (a[0] as bigint) === 0n
        ? 'At this leverage the spread alone would put the new position at its liquidation threshold. Lower the leverage.'
        : `Trade #${a[0]} is not liquidatable: its loss is ${usdc(a[1])}, below the ${usdc(a[2])} threshold.`
    case 'LimitNotTriggered':
      return `Neither the take profit nor the stop loss of trade #${a[0]} is reached at ${price(a[1])}.`
    case 'NoLimitSet':
      return `Trade #${a[0]} has no take profit or stop loss to execute.`
    case 'EnforcedPause':
      return 'The protocol owner has paused this action for now.'

    // Trading storage
    case 'MaxOpenInterestExceeded':
      return `This would take the pair's open interest to ${formatCompact(a[0] as bigint, 18)} USD, above its ${formatCompact(a[1] as bigint, 18)} USD limit.`
    case 'InvalidTp':
      return `The take profit must be ${a[2] ? 'above' : 'below'} the entry price, ${price(a[1])}.`
    case 'InvalidSl':
      return `The stop loss must be ${a[2] ? 'below' : 'above'} the entry price, ${price(a[1])}.`
    case 'PairNotFound':
      return 'That pair does not exist.'

    // Oracle
    case 'PairFeedNotSet':
      return `The oracle has no price feed for ${ctx.pairName(a[0] as bigint)}.`
    case 'StalePrice':
      return `The price was ${relativeTime(Number((a[2] as bigint) - (a[1] as bigint)))} old when the transaction landed, above the oracle's ${ctx.maxPriceAge} s limit. Try again: the app stamps a fresh price each time.`
    case 'PriceFromFuture':
      return 'The price was timestamped ahead of the chain. Try again in a few seconds.'
    case 'ConfidenceTooWide':
      return 'The price was too uncertain for the oracle to use.'
    case 'ZeroPrice':
      return 'The oracle received no usable price.'
    case 'PriceDeviationTooHigh': {
      const p = a[0] as bigint
      const c = a[1] as bigint
      const diff = p > c ? p - c : c - p
      return `The price was ${formatPct((diff * 10n ** 18n) / c, 2)} away from its Chainlink anchor, above the oracle's 3% limit.`
    }
    case 'ChainlinkStalePrice':
      return `The Chainlink ${ctx.pairOfChainlinkFeed(a[0] as string)} feed last updated ${relativeTime(Number((a[2] as bigint) - (a[1] as bigint)))} ago, longer than its window, so the oracle refuses every price that needs it. Try again once it updates.`
    case 'SequencerDown':
      return 'The network sequencer is reported down, so the oracle refuses prices until it is back.'
    case 'SequencerGracePeriodNotOver':
      return 'The network sequencer came back up recently; new positions open again once its grace period ends.'
    case 'InsufficientFee':
      return 'The price update fee was not covered.'

    // DemoPyth
    case 'PriceNotChainlinkAnswer':
      return `Chainlink published a new ${ctx.pairOfFeedId(a[0] as Hex)} price while the transaction was pending, so the Pyth stand-in refused the old one. Try again.`
    case 'ExponentMismatch':
    case 'ConfidenceMismatch':
      return 'The price update did not have the format the Pyth stand-in requires.'
    case 'FeedNotRegistered':
      return `The Pyth stand-in has no Chainlink feed registered for ${ctx.pairOfFeedId(a[0] as Hex)}.`
    case 'FuturePublishTime':
      return 'The price update was timestamped ahead of the chain. Try again in a few seconds.'
    case 'PriceFeedNotFound':
      return `The Pyth stand-in has no stored price for ${ctx.pairOfFeedId(a[0] as Hex)} yet.`

    // Vault
    case 'InsufficientShares':
      return `You hold ${shares(a[1])}, less than the ${shares(a[0])} requested.`
    case 'WithdrawalLocked': {
      const opens = new Date(Number(ctx.epochStart(a[0] as bigint)) * 1000)
      return `Your withdrawal unlocks at ${opens.toLocaleString()}, at the start of epoch ${a[0]}.`
    }
    case 'WithdrawalExpired':
      return 'Your request passed the end of its one-day window. Cancel it, or request again to start a new wait.'
    case 'NoWithdrawalRequest':
      return 'You have no withdrawal request.'
    case 'StalePnlSnapshot':
      return "The vault's snapshot of open PnL is stale, so it cannot price shares. The app refreshes it in the same call; try again."
    case 'BondingRoundOpen':
      return "Deposits are closed while a bonding round is open or due: the vault's realised ratio is below 95%."
    case 'UseRequestWithdrawalFlow':
      return 'Withdrawals go through a request, a three-day wait and an execution.'
    case 'InsufficientVaultBalance':
      return `The vault holds ${usdc(a[1])}, less than the ${usdc(a[0])} payout.`
    case 'DepositMoreThanMax':
    case 'MintMoreThanMax':
      return 'The vault does not accept deposits right now.'

    // Bonds and the reserve
    case 'NoActiveRound':
      return 'No bonding round is open, or the vault is already back at 100%.'
    case 'ZeroAmount':
      return 'Enter an amount above zero.'
    case 'NothingToClaim':
      return 'Nothing has vested since your last claim.'
    case 'InvalidBondId':
      return 'That bond does not exist.'
    case 'InsufficientFunds':
      return `The reserve fund holds ${usdc(a[1])}, less than the ${usdc(a[0])} requested.`

    // Faucet and tokens
    case 'ClaimTooSoon': {
      const next = new Date(Number(a[1] as bigint) * 1000)
      return `You already claimed today. The faucet opens again for you at ${next.toLocaleTimeString()} on ${next.toLocaleDateString()}.`
    }
    case 'InsufficientBalance':
      return a.length === 0
        ? 'Your balance is too low for this amount.'
        : `The protocol's collateral account holds ${usdc(a[1])}, less than the ${usdc(a[0])} this settlement needs.`
    case 'InsufficientAllowance':
      return 'The contract is not approved to move this amount yet. Approve it first.'
    case 'TransferFromFailed':
      return 'The USDC transfer failed: check your balance and the approval.'
    case 'TransferFailed':
    case 'ETHTransferFailed':
      return 'A transfer inside the call failed.'
    case 'Reentrancy':
      return 'The call tried to re-enter the contract and was stopped.'
    case 'Unauthorized':
      return 'Only the protocol owner can do that.'
  }

  if (reverted) return `The transaction would revert${name ? ` (${name})` : ''}.`
  return err.shortMessage || 'The request failed.'
}
