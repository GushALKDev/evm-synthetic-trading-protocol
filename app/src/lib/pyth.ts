import { encodeAbiParameters, type Hex } from 'viem'
import { BPS } from './trading'

// One DemoPyth update entry: an abi-encoded PythStructs.PriceFeed, the same encoding as Pyth's MockPyth.
const priceStruct = {
  type: 'tuple',
  components: [
    { name: 'price', type: 'int64' },
    { name: 'conf', type: 'uint64' },
    { name: 'expo', type: 'int32' },
    { name: 'publishTime', type: 'uint256' },
  ],
} as const

const priceFeedParams = [
  {
    type: 'tuple',
    components: [{ name: 'id', type: 'bytes32' }, { ...priceStruct, name: 'price' }, { ...priceStruct, name: 'emaPrice' }],
  },
] as const

export interface FeedReading {
  pythFeedId: Hex
  answer: bigint
  decimals: number
}

/**
 * Builds the update the app sends with every call that reads a price: each Chainlink answer becomes a DemoPyth
 * entry with `confBps` of confidence, published at the latest block's timestamp. DemoPyth accepts an entry only if
 * it carries the aggregator's current answer, its exponent and exactly this confidence, and rejects a future
 * publishTime; the oracle rejects one older than its maxPriceAge. So the timestamp comes from the chain, not from
 * the visitor's clock.
 */
export function buildPriceUpdate(feeds: FeedReading[], confBps: bigint, publishTime: bigint): Hex[] {
  return feeds.map((f) => {
    const price = { price: f.answer, conf: (f.answer * confBps) / BPS, expo: -f.decimals, publishTime }
    return encodeAbiParameters(priceFeedParams, [{ id: f.pythFeedId, price, emaPrice: price }])
  })
}

/** The oracle's view of a mirrored answer: price and confidence at 18 decimals (PythUtils.convertToUint) */
export function mirroredPrice(answer: bigint, decimals: number, confBps: bigint): { price: bigint; conf: bigint } {
  const scale = 10n ** BigInt(18 - decimals)
  return { price: answer * scale, conf: ((answer * confBps) / BPS) * scale }
}
