#!/usr/bin/env bash
# Local rehearsal of the testnet deployment: anvil, three local Chainlink feeds with a week of rounds that follow the
# market, DeployTestnet, SeedTrades.
# Writes app/src/config/deployments/31337.json; start the app with VITE_CHAIN_ID=31337.
# Sends from anvil's first account, unlocked by anvil itself, so no private key is involved.
# The mock feeds keep the timestamp they were last set at: the oracle treats them as stale an hour later,
# so run it again (or call setUpdatedAt on each feed) for a longer session.
# Requires Foundry and the root npm dependencies (npm ci at the repo root). Run from anywhere: ./app/scripts/local-chain.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
RPC="${RPC:-http://127.0.0.1:8545}"
SENDER="0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266"

cd "$ROOT"

if ! cast chain-id --rpc-url "$RPC" >/dev/null 2>&1; then
  echo "Starting anvil on $RPC"
  # Detached from this script's output, so a caller piping it does not wait on anvil
  anvil --silent --chain-id 31337 >/dev/null 2>&1 &
  for _ in $(seq 1 50); do cast chain-id --rpc-url "$RPC" >/dev/null 2>&1 && break; sleep 0.2; done
fi

# Each feed follows the market (Coinbase, 8 decimals like the Chainlink USD feeds), so the oracle line sits on the market
# candles the app draws: a week of past rounds from hourly candles (scripts/market-rounds.mjs), then the current price.
# With LOCAL_PRICES=fixed, or no answer from Coinbase, it gets a fixed price and 600 past rounds 1,200 s apart as a random
# walk of at most 0.25% per round that ends there.
feed() {
  local symbol="$1" fixed="$2" address usd rounds
  address=$(forge create script/testnet/LocalChainlinkFeed.sol:LocalChainlinkFeed --rpc-url "$RPC" --unlocked --from "$SENDER" \
    --broadcast --constructor-args 8 | awk '/Deployed to:/ {print $3}')
  if [ "${LOCAL_PRICES:-market}" != "fixed" ] \
    && usd=$(curl -sf -m 5 "https://api.exchange.coinbase.com/products/$symbol-USD/ticker" | sed -n 's/.*"price":"\([0-9.]*\)".*/\1/p') \
    && [ -n "$usd" ] \
    && rounds=$(node "$ROOT/app/scripts/market-rounds.mjs" "$symbol" "$(cast block latest -f timestamp --rpc-url "$RPC")"); then
    cast send "$address" "seedRounds(int256[],uint256[])" $rounds --rpc-url "$RPC" --unlocked --from "$SENDER" >/dev/null
    cast send "$address" "setAnswer(int256)" "$(awk -v p="$usd" 'BEGIN { printf "%.0f", p * 1e8 }')" --rpc-url "$RPC" --unlocked \
      --from "$SENDER" >/dev/null
  else
    cast send "$address" "seedHistory(int256,uint256,uint256,uint256)" "$fixed" 600 1200 25 --rpc-url "$RPC" --unlocked --from "$SENDER" >/dev/null
    cast send "$address" "setAnswer(int256)" "$fixed" --rpc-url "$RPC" --unlocked --from "$SENDER" >/dev/null
  fi
  echo "$address"
}
export BTC_CL_FEED=$(feed BTC 10000000000000)
export ETH_CL_FEED=$(feed ETH 400000000000)
export LINK_CL_FEED=$(feed LINK 2000000000)
echo "Feeds: BTC $BTC_CL_FEED, ETH $ETH_CL_FEED, LINK $LINK_CL_FEED"

# --slow sends each transaction once the previous one is mined: sent all at once, anvil has been seen to keep a
# transaction queued behind a nonce that was already mined, and the run then waits forever for its receipt
forge script script/testnet/DeployTestnet.s.sol --rpc-url "$RPC" --unlocked --sender "$SENDER" --broadcast --slow -q
echo "Wrote app/src/config/deployments/31337.json"
forge script script/testnet/SeedTrades.s.sol --rpc-url "$RPC" --unlocked --sender "$SENDER" --broadcast --slow -q
echo "Opened the seed trades"
