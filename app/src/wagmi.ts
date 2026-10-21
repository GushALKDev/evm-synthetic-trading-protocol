import { createConfig, http } from 'wagmi'
import { injected, mock } from 'wagmi/connectors'
import { chain, rpcUrl } from './config/chain'

// Browser wallets are discovered through EIP-6963 (MetaMask, Rabby, Coinbase Wallet, ...). The mock
// connector exists only for the end-to-end tests against a local anvil chain.
const e2eAccount = import.meta.env.VITE_E2E_ACCOUNT as `0x${string}` | undefined

export const wagmiConfig = createConfig({
  chains: [chain],
  connectors: e2eAccount ? [mock({ accounts: [e2eAccount], features: { reconnect: true } })] : [injected()],
  transports: { [chain.id]: http(rpcUrl, { batch: { wait: 16 } }) },
  // The positions page reads a window of trades in one go: larger multicall chunks keep it to a few requests.
  batch: { multicall: { batchSize: 32_768 } },
  pollingInterval: 4_000,
})

declare module 'wagmi' {
  interface Register {
    config: typeof wagmiConfig
  }
}
