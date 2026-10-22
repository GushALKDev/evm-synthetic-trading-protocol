// Prints a week of past Chainlink-style rounds for a symbol from Coinbase's public hourly candles, for local-chain.sh to
// seed a local feed with: two lines, the answers and the times, as cast arrays. Three rounds per hour, 1,200 s apart
// like the Base Sepolia feeds' heartbeat: the hour's open, its midpoint and its close. 8 decimals, like the USD feeds.
// node scripts/market-rounds.mjs BTC [now]
const [symbol, nowArg] = process.argv.slice(2)
const now = Number(nowArg ?? Math.floor(Date.now() / 1000))
const res = await fetch(`https://api.exchange.coinbase.com/products/${symbol}-USD/candles?granularity=3600`)
if (!res.ok) throw new Error(`Coinbase answered ${res.status}`)
// [time, low, high, open, close, volume], newest first; 168 hours is the chart's longest view
const hours = (await res.json()).slice(0, 168).reverse()
const answers = []
const times = []
for (const [t, , , open, close] of hours) {
  for (const [offset, price] of [[0, open], [1_200, (open + close) / 2], [2_400, close]]) {
    // Rounds stay before the current block, which publishes the current answer
    if (t + offset >= now - 60) continue
    answers.push(Math.round(price * 1e8))
    times.push(t + offset)
  }
}
if (answers.length === 0) throw new Error('No candles')
console.log(`[${answers.join(',')}]`)
console.log(`[${times.join(',')}]`)
