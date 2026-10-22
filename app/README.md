# Synthetic Trading demo app

A web app for the synthetic trading protocol in this repository, running on Base Sepolia with testnet USDC. Visitors can
read the whole protocol without a wallet, and with one they can open and close leveraged longs and shorts on BTC, ETH and
LINK, set take profit and stop loss, liquidate or execute other traders' positions, deposit into the vault, request and
execute withdrawals, and bond when a bonding round opens.

Proof of concept, not audited. The USDC is a testnet stand-in with no value.

<!-- Live: https://synthetic-trading-poc.<account>.workers.dev -->

## What it shows

- **A trading terminal.** The layout of a perpetuals exchange: a pair selector and the market's figures on top (oracle
  price, 24 hour change, open interest per side, funding, spread, leverage), the chart with the trade box at its right,
  and the account panel underneath with Positions, Orders and History.
- **The chart is the oracle.** Candles are built from the Chainlink rounds of the pair on the chain
  (`getRoundData`, `src/hooks/usePriceHistory.ts`, `src/lib/chart.ts`), the prices the protocol executes at, not an
  exchange's. They move when the feed publishes a round: in the 24 hours before the latest round on 22 October 2026, the
  Base Sepolia feeds published 210 rounds for BTC/USD, 201 for ETH/USD and 185 for LINK/USD (`node
  scripts/count-rounds.mjs`, read-only). The account's entry, liquidation, take profit
  and stop loss are drawn on it, and the position being typed is previewed with dashed lines. The chart is TradingView's
  Lightweight Charts (Apache License 2.0), with its attribution logo and the notice in [`NOTICE`](./NOTICE).
- **Positions as the contracts see them.** Entry price with the spread, funding projected to the latest block, the payout
  if closed now with the close fee, and the liquidation price found by searching the Chainlink answers the app would push
  through the contract's own formulas. All of it mirrors the contracts' scales and rounding (`src/lib/trading.ts`,
  `src/lib/vault.ts`), checked to the wei against a local deployment (`scripts/parity.test.ts`).
- **Orders are the TP and SL.** The protocol has no limit orders to open a position (ROADMAP 13.8). The Orders tab lists
  each position's take profit and stop loss as trigger orders, with the distance to the price, and lets the trader edit,
  cancel or, once reached, execute them.
- **History in the browser.** As a proof of concept, the app runs no indexer, and the public Base Sepolia RPC answers log
  queries over 200 blocks at most (`eth_getLogs is limited to a 200 range`), about 40 seconds of chain. So the History tab
  keeps its records in the visitor's browser: the settlements of the calls sent from it, exact, from their receipts, and
  positions that close while the page is open (liquidated or executed by someone else), found by their settlement event.
  A position that closed while the page was closed is listed without amounts, with a link to the explorer. A production
  frontend would read the history from an indexer.
- **Previews before every call.** The trade box shows entry price, size, fee, liquidation price, funding for the side and
  the payout cap; a deposit shows the shares at the NAV after the refresh and the reserve top-up the deposit runs first.
  Every call is simulated before the wallet asks for a signature, so a revert arrives as a sentence (`src/lib/errors.ts`)
  instead of a failed transaction.
- **Earn.** The vault against every open trade (what it holds against what it owes to liquidity providers and traders,
  with the NAV and realised ratios on the solvency thresholds), deposits and withdrawals, the solvency layers and bonds.
- **Liquidations by hand.** Every open position, with a liquidate or execute button where one applies and the reward the
  caller earns. Here they are manual, as a teaching device; in production a keeper or liquidation bot watches every
  position and calls them as soon as they qualify, for the same reward. The page reads the latest 500 trade ids.

## Where prices come from

In the production configuration (`script/Deploy.s.sol`) the oracle reads Pyth and checks every price against a
Chainlink anchor. Since the Pyth Core upgrade completed on 26 August 2026, Hermes serves price updates only with an API
key ([Pyth's notice](https://docs.pyth.network/price-feeds/core/upgrade/preparing)), and a key in a static page is
readable by every visitor. So the testnet deployment replaces Pyth with
[`DemoPyth`](../script/testnet/DemoPyth.sol), a testnet-only stand-in that takes unsigned updates.

Before each call that needs a price (open, close, setting a TP or SL, liquidate, execute, deposit, withdraw, the solvency
check), the app reads the Chainlink answer of each pair the call prices, encodes it as a Pyth price with a 0.05%
confidence half-width and the latest block's timestamp (`src/lib/pyth.ts`), and sends it with the call. Engine calls
carry one entry for the trade's pair; the vault's refresh paths carry one per pair. Each entry costs DemoPyth's 1 wei fee.

What DemoPyth checks, for every entry, when the call lands, and again for the stored price whenever the oracle reads it:

- the feed id has a Chainlink aggregator registered by the deployer (the same one the oracle uses as the anchor);
- the price equals that aggregator's latest answer, the exponent is minus its decimals, and the confidence is exactly
  answer times 5 / 10,000. A price chosen inside the oracle's 3% band would let anyone open at one edge and close at the
  other at up to 100x, so DemoPyth accepts no other price;
- the publish time is not in the future.

What it does not check: whether the Chainlink answer is fresh (the oracle does, with a 3,600 s window on this
deployment), whether the testnet feeds track the market, signatures, or the EMA price. It keeps the last write rather
than the newest publish time, so the update a call carries is the price that call reads.

The oracle contract is the repository's own, unchanged. The deploy script raises its price age limit from the 5 s default
to 30 s with the owner setter, the most the contract allows, because a wallet signature takes longer than 5 s. It still
rejects a confidence above 2%. Its 3% deviation check still runs, but cannot fire on this deployment, since the price is
the anchor. If Chainlink publishes a new answer between the app's read and the landing, DemoPyth reverts with
`PriceNotChainlinkAnswer` and the app says so; sending again works. So the time to sign is 30 s or until the next
Chainlink round, whichever comes first. A call that brings no update reverts the same way once Chainlink has moved, so no
call reads a previous answer.

Base Sepolia has no Chainlink L2 sequencer uptime feed
([Chainlink's list](https://docs.chain.link/data-feeds/l2-sequencer-feeds)), so the oracle is deployed with
`address(0)` there and its sequencer checks are off.

The other stand-ins: `TestnetUSDC` (6 decimals, minted only by the faucet, with no implicit Permit2 allowance) and
`TestnetFaucet` (10,000 USDC per address per day; the deployer can mint any amount, which the scripts use to seed). The
faucet contract holds the seed liquidity's vault shares and has no function that could withdraw them.

### What a stranger can do on the shared deployment

- **Fill a pair's open interest cap.** BTC and ETH allow 4M USD and LINK 1M. One day's 10,000 USDC at 100x opens
  920,000 USD after the 8% open fee, so about five addresses fill BTC, though a position at 100x is liquidated by a move
  under 1%; a fill that lasts at 10x takes about 40 addresses' claims. New positions on a full pair revert, while closes,
  liquidations and TP/SL still settle (`test_griefing_aFullPairStillSettlesAndTheOwnerCanRaiseIt`), and the owner can
  move the cap with `updatePair`. The caps are sized to the 1M seed liquidity: higher caps would let a one-sided book take
  more than the vault holds, and then every winning close would revert until losers settle or new USDC arrives.
- **Push prices into DemoPyth.** Only the current Chainlink answer is accepted, and a push with an old publish time is
  replaced by the next call's own update (`test_griefing_anEarlierPushIsOverwrittenByTheAppsUpdate`).
- **Win against the vault.** Only at the current Chainlink price: a call that brings no price update reverts once
  Chainlink has moved, so nobody can open at the previous answer and close at the new one. With every pair filled on one
  side at its maximum leverage and a move past the 9x payout cap, the closes take 754,707 USDC net from the vault
  (`test_griefing_aOneSidedBookAtTheCapsStaysWithinTheVault`); larger moves at lower leverage can take more. A testnet feed moves when the answer drifts by its deviation
  threshold (0.1% BTC, 0.15% ETH, 0.2% LINK) or after 1,200 s, so a trader watching the real market sees moves before
  the feed; a round trip costs 0.16% in fees plus the spread twice. If winners take the realised ratio below 95%,
  deposits close until a bonding round brings it back, and the vault page offers the permissionless check that opens the
  round, then bonds.
- **Open many tiny trades.** The positions page reads only the latest 500 trade ids, so it stays bounded.

## Run it locally

Requires Node 22 and, for a local chain, Foundry and the root npm dependencies (`npm ci` at the repository root).

```bash
cd app
npm ci
npm run dev                  # reads the Base Sepolia deployment, or shows that there is none yet
```

Against a local chain instead (anvil, three local Chainlink feeds with a week of rounds for the chart, the full deployment
and the seed trades):

```bash
./app/scripts/local-chain.sh                 # from the repo root; writes src/config/deployments/31337.json
cd app && VITE_CHAIN_ID=31337 npm run dev
```

The script sends from anvil's first account, unlocked by the node, so no private key is involved. The local feeds
([`LocalChainlinkFeed`](../script/testnet/LocalChainlinkFeed.sol), local only) start with 600 past rounds 1,200 s apart,
so the chart has history. They keep the time they were last set at, so after an hour the oracle treats the anchors as
stale and priced calls revert, as they would on a real network. Rerun the script for a fresh deployment.

Checks:

```bash
npm run typecheck
npm test                                              # unit tests of the mirrored math
LOCAL_RPC=http://127.0.0.1:8545 npm run parity        # parity against a local deployment
npx playwright install chromium && npm run e2e         # every user action, against a local deployment
SCREENSHOT_DIR=/tmp/shots npx playwright test e2e/screenshots.spec.ts e2e/app.spec.ts   # optional screenshots
```

The parity suite opens and closes positions, liquidates at the boundary the app computes (one unit above it reverts),
executes a take profit, deposits and withdraws, and compares each figure with the contract's events and views, to the wei.
The end-to-end suite drives the interface with the wagmi mock connector on anvil's account 2, including the failure
paths. Both revert the chain to a snapshot when they finish, so they can run again. CI runs both on every push against a
fresh local deployment.

## Deploy the contracts to Base Sepolia

From the repository root, with a fresh key used only for this demo:

```bash
npm ci
cast wallet import demo-deployer --interactive    # stores the key encrypted, asks for a password
```

Fund that address with a little Base Sepolia ETH from one of the
[Base faucets](https://docs.base.org/get-started/get-funds), then:

```bash
forge script script/testnet/DeployTestnet.s.sol --rpc-url https://sepolia.base.org --account demo-deployer --broadcast
```

The script simulates everything first, including a read of every pair's price through the oracle, so a stale or missing
Chainlink feed stops it before anything is sent. It deploys the faucet and USDC, DemoPyth, and the nine protocol contracts
with the parameters of `script/Deploy.s.sol`, wires them, lists BTC/USD and ETH/USD (100x, 4M USD open interest cap)
and LINK/USD (50x, 1M), raises the oracle's price age limit to 30 s, and deposits 1,000,000 USDC on behalf of the faucet
contract. It refuses any chain other than Base Sepolia and anvil. On a broadcast it writes
`app/src/config/deployments/84532.json`, which the app reads: commit that file. A run without `--broadcast` leaves the
file alone. If a broadcast stops halfway, delete the file and run it again.

Then open the seed trades, with the same account, right after:

```bash
forge script script/testnet/SeedTrades.s.sol --rpc-url https://sepolia.base.org --account demo-deployer --broadcast
```

It opens 200,000 USD long against 100,000 short on BTC/USD and 50,000 long against 150,000 short on ETH/USD, at 5x, so
funding flows and the vault carries open PnL from the start. It is a separate run because each trade carries a price the
oracle rejects once it is older than 30 s. If it reverts with `StalePrice` (a slow RPC) or `PriceNotChainlinkAnswer`
(Chainlink published in between), run it again: trades the deployer already holds are skipped.

To verify the contracts on BaseScan, add `--verify --etherscan-api-key <key>` to both commands.

Checks after deploying, with the addresses from the deployment file:

```bash
cast call <tradingStorage> "getPairsCount()(uint256)" --rpc-url https://sepolia.base.org     # 3
cast call <tradingStorage> "getTradeCounter()(uint32)" --rpc-url https://sepolia.base.org    # 4 after SeedTrades
cast call <oracle> "maxPriceAge()(uint256)" --rpc-url https://sepolia.base.org               # 30
cast call <vault> "balanceOf(address)(uint256)" <faucet> --rpc-url https://sepolia.base.org  # 1e24 seed shares
```

The testnet tooling has its own tests, kept apart so the protocol's test figures stay unchanged:

```bash
FOUNDRY_PROFILE=testnet forge test
```

## Deploy the app to Cloudflare Workers

The app runs as `synthetic-trading-poc`, an assets-only Worker: there is no Worker script. `wrangler.jsonc` points it at
`dist/` and holds the SPA fallback, which serves `index.html` for every page path (`/earn`, `/liquidations`,
`/how-it-works`). `public/_headers` holds the cache and security headers; Vite copies it into `dist/`.

First deploy, from a terminal in `app/`:

```bash
npx wrangler login           # authorizes wrangler on your Cloudflare account, in the browser
npm run deploy               # builds, deploys and prints the workers.dev URL
```

Deploys on push: in the Cloudflare dashboard, connect this repository to the Worker (Workers Builds) with root directory
`app`, build command `npm run build` and deploy command `npx wrangler deploy`. The Worker name in `wrangler.jsonc` must
match the Worker in the dashboard.

`VITE_RPC_URL` is optional, for when the public Base Sepolia RPC rate limits the page. Vite reads it at build time, so on
Workers Builds it goes in the build variables, not in the runtime variables. Any key in it is visible to visitors, so
restrict it to the site's domain at the provider.

## Structure

```
src/
  abi/          generated from the Foundry build (npm run abi after forge build)
  config/       chain, links, and the deployment files written by the script
  lib/          protocol math, chart candles, history records, price update encoding, error messages, formatting, the model
  hooks/        chain reads, price history, the browser history, the model, transactions, toasts, the current page
  components/   the interface
scripts/
  local-chain.sh     local rehearsal of the testnet deployment
  parity.test.ts     app math against a local deployment
  sync-abi.mjs       regenerates src/abi
  contrast.mjs       contrast of the color tokens, for DESIGN.md
  count-rounds.mjs   rounds the Base Sepolia feeds published in the last 24 hours
e2e/            Playwright: every user action, layout at 360 px, optional screenshots
```

Design notes, shared with the other demo apps: [DESIGN.md](./DESIGN.md).
