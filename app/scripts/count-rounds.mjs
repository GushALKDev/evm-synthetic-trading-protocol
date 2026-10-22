// Counts the Chainlink rounds each Base Sepolia feed of the demo published in the last 24 hours, the cadence the price
// chart is built from. Read-only, against the public RPC: node scripts/count-rounds.mjs
import { createPublicClient, http, parseAbi } from 'viem'
import { baseSepolia } from 'viem/chains'

const client = createPublicClient({ chain: baseSepolia, transport: http('https://sepolia.base.org') })
const abi = parseAbi([
  'function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)',
  'function getRoundData(uint80) view returns (uint80, int256, uint256, uint256, uint80)',
])
// The anchors DeployTestnet uses on Base Sepolia
const feeds = {
  'BTC/USD': '0x0FB99723Aee6f420beAD13e6bBB79b7E6F034298',
  'ETH/USD': '0x4aDC67696bA383F43DD60A9e78F2C97Fbbfc7cb1',
  'LINK/USD': '0xb113F5A928BCfF189C998ab20d753a47F9dE5A61',
}

for (const [name, address] of Object.entries(feeds)) {
  const [latestId, , , latestAt] = await client.readContract({ address, abi, functionName: 'latestRoundData' })
  const ids = Array.from({ length: 400 }, (_, i) => latestId - BigInt(i + 1))
  const results = await client.multicall({
    contracts: ids.map((id) => ({ address, abi, functionName: 'getRoundData', args: [id] })),
    allowFailure: true,
    batchSize: 32_768,
  })
  const times = results.filter((r) => r.status === 'success').map((r) => r.result[3])
  const inDay = 1 + times.filter((t) => t >= latestAt - 86_400n).length
  console.log(`${name}: ${inDay} rounds in the 24 hours before the latest one (${new Date(Number(latestAt) * 1000).toISOString()})`)
}
