import { erc20Abi, parseAbi } from 'viem'
import {
  assistantFundAbi,
  bondDepositoryAbi,
  chainlinkAbi,
  demoPythAbi,
  faucetAbi,
  oracleAbi,
  solvencyManagerAbi,
  spreadManagerAbi,
  synthTokenAbi,
  testnetUsdcAbi,
  tradingEngineAbi,
  tradingStorageAbi,
  vaultAbi,
} from '../abi'

const errorsOf = <T extends readonly { type: string }[]>(abi: T) =>
  abi.filter((item): item is Extract<T[number], { type: 'error' }> => item.type === 'error')

// Solady reverts these from assembly, so they are not in the generated ABIs.
const soladyErrors = parseAbi([
  'error TransferFromFailed()',
  'error TransferFailed()',
  'error ETHTransferFailed()',
  'error ApproveFailed()',
  'error Overflow()',
])

// Every error a call can raise, from any contract it reaches: a trade reaches the engine, storage, Vault, spread
// manager, oracle, DemoPyth and the token; a deposit reaches the Vault, oracle, DemoPyth, solvency manager, fund
// and bond depository. One list lets viem decode any revert into a named error with its arguments.
const allErrors = [
  ...errorsOf(tradingEngineAbi),
  ...errorsOf(tradingStorageAbi),
  ...errorsOf(vaultAbi),
  ...errorsOf(oracleAbi),
  ...errorsOf(spreadManagerAbi),
  ...errorsOf(solvencyManagerAbi),
  ...errorsOf(assistantFundAbi),
  ...errorsOf(bondDepositoryAbi),
  ...errorsOf(synthTokenAbi),
  ...errorsOf(demoPythAbi),
  ...errorsOf(faucetAbi),
  ...errorsOf(testnetUsdcAbi),
  ...soladyErrors,
] as const

export const engineAbi = [...tradingEngineAbi, ...allErrors] as const
export const storageAbi = tradingStorageAbi
export const vaultCallAbi = [...vaultAbi, ...allErrors] as const
export const solvencyAbi = [...solvencyManagerAbi, ...allErrors] as const
export const bondAbi = [...bondDepositoryAbi, ...allErrors] as const
export const faucetCallAbi = [...faucetAbi, ...allErrors] as const
export const tokenAbi = [...erc20Abi, ...errorsOf(testnetUsdcAbi), ...soladyErrors] as const

export { assistantFundAbi, chainlinkAbi, demoPythAbi, oracleAbi, spreadManagerAbi, vaultAbi }
