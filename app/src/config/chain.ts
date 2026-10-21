import { defineChain, type Chain } from 'viem'
import { baseSepolia } from 'viem/chains'
import { loadDeployment } from './deployment'

const localChain = defineChain({
  id: 31_337,
  name: 'Local anvil',
  nativeCurrency: { name: 'Ether', symbol: 'ETH', decimals: 18 },
  rpcUrls: { default: { http: ['http://127.0.0.1:8545'] } },
})

export const chainId = Number(import.meta.env.VITE_CHAIN_ID ?? baseSepolia.id)

export const chain: Chain = chainId === localChain.id ? localChain : baseSepolia

export const rpcUrl: string = import.meta.env.VITE_RPC_URL || chain.rpcUrls.default.http[0]

export const deployment = loadDeployment(chain.id)

export const explorer = chain.blockExplorers?.default.url

export const links = {
  repo: 'https://github.com/GushALKDev/evm-synthetic-trading-protocol',
  docs: 'https://github.com/GushALKDev/evm-synthetic-trading-protocol/blob/main/docs/README.md',
  author: 'https://www.linkedin.com/in/gustavomaral/',
  ethFaucet: 'https://docs.base.org/base-chain/network-information/network-faucets',
  pythUpgrade: 'https://docs.pyth.network/price-feeds/core/upgrade/preparing',
}

export function explorerAddress(address: string) {
  return explorer ? `${explorer}/address/${address}` : undefined
}

export function explorerTx(hash: string) {
  return explorer ? `${explorer}/tx/${hash}` : undefined
}
