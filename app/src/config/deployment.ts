import type { Address } from 'viem'

// Deployment files are written by script/testnet/DeployTestnet.s.sol, one per chain id. They hold addresses
// only: pair names, feeds and limits are read from TradingStorage and the oracle, so an owner change shows.
interface RawDeployment {
  chainId: number
  deployBlock: number
  deployer: Address
  vault: Address
  tradingStorage: Address
  engine: Address
  spreadManager: Address
  oracle: Address
  assistantFund: Address
  synth: Address
  bondDepository: Address
  solvencyManager: Address
  faucet: Address
  usdc: Address
  pyth: Address
}

export interface Deployment extends Omit<RawDeployment, 'deployBlock'> {
  deployBlock: bigint
}

const files = import.meta.glob<RawDeployment>('./deployments/*.json', { eager: true, import: 'default' })

export function loadDeployment(chainId: number): Deployment | null {
  const raw = files[`./deployments/${chainId}.json`]
  if (!raw) return null
  return { ...raw, deployBlock: BigInt(raw.deployBlock) }
}
