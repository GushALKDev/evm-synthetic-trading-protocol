#!/usr/bin/env bash
# Local rehearsal of the testnet deployment: anvil, three mock Chainlink feeds, DeployTestnet, SeedTrades.
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

feed() {
  local address
  address=$(forge create test/mocks/MockChainlinkFeed.sol:MockChainlinkFeed --rpc-url "$RPC" --unlocked --from "$SENDER" \
    --broadcast --constructor-args 8 | awk '/Deployed to:/ {print $3}')
  cast send "$address" "setAnswer(int256)" "$1" --rpc-url "$RPC" --unlocked --from "$SENDER" >/dev/null
  echo "$address"
}
export BTC_CL_FEED=$(feed 10000000000000)
export ETH_CL_FEED=$(feed 400000000000)
export LINK_CL_FEED=$(feed 2000000000)
echo "Feeds: BTC $BTC_CL_FEED, ETH $ETH_CL_FEED, LINK $LINK_CL_FEED"

forge script script/testnet/DeployTestnet.s.sol --rpc-url "$RPC" --unlocked --sender "$SENDER" --broadcast -q
echo "Wrote app/src/config/deployments/31337.json"
forge script script/testnet/SeedTrades.s.sol --rpc-url "$RPC" --unlocked --sender "$SENDER" --broadcast -q
echo "Opened the seed trades"
