import { defineConfig, devices } from '@playwright/test'

// The account the wagmi mock connector signs with: anvil's default account 2, unlocked on the local node.
// The suite needs a local chain with a fresh deployment: ./scripts/local-chain.sh
export const E2E_ACCOUNT = '0x3C44CdDdB6a900fa2b585dd299e03d12FA4293BC'
const PORT = 5174
export const MARKET_PORT = 5175

export default defineConfig({
  testDir: 'e2e',
  timeout: 180_000,
  expect: { timeout: 30_000 },
  // One chain, one account: the flows run in order and share its state
  workers: 1,
  fullyParallel: false,
  reporter: [['list']],
  use: { baseURL: `http://127.0.0.1:${PORT}`, trace: 'retain-on-failure' },
  projects: [{ name: 'chromium', use: { ...devices['Desktop Chrome'] } }],
  webServer: [
    {
      command: `VITE_CHAIN_ID=31337 VITE_CHART_SOURCE=oracle VITE_E2E_ACCOUNT=${E2E_ACCOUNT} npx vite --port ${PORT} --strictPort --host 127.0.0.1`,
      url: `http://127.0.0.1:${PORT}`,
      reuseExistingServer: !process.env.CI,
      timeout: 60_000,
    },
    // The same app with the market chart a public network shows, for e2e/market.spec.ts (Coinbase is stubbed there).
    // Its mode gives it its own optimizer cache (vite.config.ts): sharing the first server's, it replaced the deps that
    // server had handed out, and a chunk the page loads later (viem's ccip, on the first revert) answered 504.
    {
      command: `VITE_CHAIN_ID=31337 npx vite --mode market --port ${MARKET_PORT} --strictPort --host 127.0.0.1`,
      url: `http://127.0.0.1:${MARKET_PORT}`,
      reuseExistingServer: !process.env.CI,
      timeout: 60_000,
    },
  ],
})
