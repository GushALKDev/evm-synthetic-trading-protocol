# Synthetic Trading Protocol

[![Foundry Tests](https://github.com/GushALKDev/evm-synthetic-trading-protocol/actions/workflows/test.yml/badge.svg?branch=main)](https://github.com/GushALKDev/evm-synthetic-trading-protocol/actions/workflows/test.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](./LICENSE)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.24-363636.svg)](https://docs.soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)

A leveraged synthetic trading protocol written in Solidity. Traders open long or short positions on
oracle-priced markets using USDC collateral. A single ERC-4626 vault, funded by liquidity providers
(LPs), is the counterparty to every trade: trader losses and 80% of trading fees go to the vault, and
trader profits are paid out of it. Execution prices come from Pyth pull updates, checked against a
Chainlink feed, with a spread that grows with open interest and a keeper-supplied volatility value.
The architecture follows gTrade by Gains Network (single vault as counterparty, oracle execution,
separate storage and trading contracts).

**Status:** Proof of concept. The findings of the internal review rounds are fixed or documented (see
[Review notes](#review-notes)). Not audited by a third party and not deployed. It is an educational project
and must not be used with real funds.

---

## Implementation status

Status legend: **Implemented** (code and tests exist), **Partial** (implemented with limits described in
the row), **Designed only** (described in the docs, no code), **Not found**. File references point to
`src/`; test names point to `test/`.

| Feature | Status | Evidence |
| :------ | :----- | :------- |
| ERC-4626 vault, sUSDC shares (18 decimals, `_decimalsOffset() = 12`) | Implemented | `Vault.sol` (Solady `ERC4626`); `test/unit/Vault.t.sol` |
| 3-epoch withdrawal lock (1 epoch = 1 day) with escrow and a 1-epoch execution window | Implemented | `Vault.requestWithdrawal` escrows the shares in the vault; `executeWithdrawal` works only in the epoch after unlock, then reverts `WithdrawalExpired`; `cancelWithdrawal` returns the shares. `test/regression/WithdrawalRegression.t.sol`, `Vault.t.sol` |
| ERC-4626 conformity and `max*` functions | Implemented | `maxWithdraw` and `maxRedeem` return 0 (the actions always revert); `maxDeposit` and `maxMint` return 0 under `PAUSE_DEPOSIT`, with a stale PnL snapshot, or while a bonding round is open or due. Previews, rounding direction, non-reverting views and escrowed shares in `test/unit/VaultErc4626.t.sol`; `max*` against their actions in `Vault.t.sol` and `test/unit/VaultDepositRule.t.sol` |
| Share price at a conservative NAV with open trader PnL | Implemented | `Vault.totalAssets` = USDC balance minus the positive net unrealised trader PnL of the latest snapshot. Per pair and side aggregates in `TradingStorage` (`getPairOpenTotals`), math in `libraries/OpenPnlLib.sol`, snapshot in `Vault.refreshPnlSnapshot` (at most `MAX_PAIRS` = 20 pairs). `deposit`, `mint` and `executeWithdrawal` need a snapshot at most `maxPnlSnapshotAge` old (60 s by default) with no open or close since; `refreshAndDeposit`, `refreshAndMint`, `refreshAndExecuteWithdrawal` refresh in the same call. `test/unit/VaultNav.t.sol`, `test/regression/OpenPnlNavRegression.t.sol` |
| Deposit rule: pending AssistantFund injection first, no deposits while bonding is open or due | Implemented | Every deposit path calls `SolvencyManager.checkAndActBeforeDeposit` before minting and reverts with `BondingRoundOpen` when a round is open afterwards; below 100% coverage a deposit is otherwise allowed at the NAV. `test/regression/DepositRuleRegression.t.sol`, `test/unit/VaultDepositRule.t.sol` |
| Pyth pull integration: update data, caller-paid fee with refund, 5 s price age (owner-set up to 30 s), 2% confidence cap | Implemented | `PythChainlinkOracle.getPrice`; `test/unit/PythChainlinkOracle.t.sol` (MockPyth); fork suite on Arbitrum One at a pinned block, 21 tests |
| L2 sequencer uptime check (Chainlink feed, 1 hour grace period for openings) | Implemented | `PythChainlinkOracle` constructor parameter, `address(0)` disables it. While the sequencer is down every price read reverts; for one hour after it comes back only `openTrade` reverts (`IOracle.checkOpenAllowed`). `test/regression/SequencerRegression.t.sol`, `test/regression/SequencerGraceScopeRegression.t.sol` and the fork suite |
| Chainlink deviation anchor (3%) and Chainlink heartbeat check | Implemented | `PythChainlinkOracle.getPrice`, `_getChainlinkPrice18`. On disagreement above 3% or a stale Chainlink answer the call reverts; there is no fallback price |
| Dynamic spread: base + OI term + volatility term, capped | Implemented | `SpreadManager.getSpreadBps`; volatility is set by a keeper (`updateVolatility`); `test/unit/SpreadManager.t.sol` |
| Funding between traders | Implemented | `FundingLib`, `TradingEngine._updateFundingIndex`: rate proportional to the relative skew, capped at 0.01% of the heavier side's notional per hour; the lighter side receives what the heavier side pays, through per-side indexes; the vault only carries the bad-debt residual described below |
| Liquidations: 90% loss threshold, reward `max(10% of remaining collateral, 0.5% of collateral)` | Implemented | `TradingEngine.liquidate`; loss includes funding and uses the trader-favourable edge of the Pyth confidence band; the reward is paid from the position's collateral, also past 100% loss; blocked by `PAUSE_SETTLE` together with closes |
| Automatic TP/SL (`executeLimit`) with executor reward (0.1% of notional, taken from the trader payout) | Implemented | `TradingEngine.executeLimit`; permissionless. Limit orders that open positions are not implemented |
| Open interest limit | Partial | Static per-pair cap on long + short OI (`TradingStorage.increaseOpenInterest`), set by the owner. No global cap |
| Open interest limits that adapt to volatility | Designed only | Described in `docs/02-mathematics.md` and `docs/07-vault-ssl.md`; no code |
| Profit cap | Implemented | `TradingEngine._calculatePayout`: collateral plus price PnL capped at 9x collateral (maximum price profit 8x); funding is settled after the cap in both directions |
| Max leverage | Implemented | Global `MAX_LEVERAGE = 100`, checked in `addPair`/`updatePair` and on open; per-pair limits below it |
| Opening guard | Implemented | `_validateNotPreLiquidatable` rejects a position `liquidate` would accept in the same block at an unchanged price (close spread at the post-open OI, collateral net of the open fee) |
| Asset classes (crypto, forex, commodities) | Partial | Any pair with a Pyth feed ID and a Chainlink feed can be configured. No per-class logic (no market hours, no weekend handling). The fork suite uses BTC and ETH; the mock invariant suites run three pairs |
| Fee split: 0.08% open and close fee on notional, 80% vault / 20% treasury | Implemented | `TradingEngine._distributeFees`; `script/Deploy.s.sol` sets the treasury to the `AssistantFund` |
| `SolvencyManager.checkAndAct`: inject reserve below a 100% NAV ratio, open a bonding round below a 95% realised ratio, close it at 100% realised | Implemented | `SolvencyManager.sol`. The injection needs a fresh PnL snapshot (`refreshAndCheckAndAct` takes one); bonding uses the USDC balance per share, so an unrealised move does not sell discounted $SYNTH. `test/regression/SolvencySplitRegression.t.sol` |
| `AssistantFund.injectFunds` and permissionless `skim` | Implemented | `AssistantFund.sol`; `test/unit/AssistantFund.t.sol` |
| `BondDepository`: discounted $SYNTH sale with linear vesting | Implemented | `BondDepository.bond` / `claim`. A bond takes at most the current realised vault deficit and the round closes when the realised ratio is back at 100%. Price comes from an owner-set `referencePrice`, not from a market |
| `SynthToken` minter gating | Implemented | `SynthToken.mint` (`onlyMinter`); the owner can change the minter at any time |
| Surplus buyback of $SYNTH above 110% CR | Designed only | Described in `docs/02-mathematics.md`; no code |
| Independent pause flags | Implemented | `TradingEngine`: `PAUSE_OPEN`, `PAUSE_SETTLE` (closes, TP/SL and liquidations together; no funding accrues while set). `Vault`: `PAUSE_DEPOSIT`, `PAUSE_WITHDRAW` (the expiry clock of pending requests stops). `setPauseFlags`, owner only. `test/regression/PauseFlagsRegression.t.sol`; incident playbook in `docs/08-security.md` section 6 |
| Circuit breakers, emergency withdrawal, role-based access control, timelock | Designed only | Earlier design documents only. Every contract uses a single `Ownable` owner |
| Liquidation lookbacks | Designed only | Listed as V2 in `docs/ROADMAP.md` |
| Custom oracle network (DON) | Not found | Dropped in the design phase; no code remains |

---

## How it works

- **Traders** deposit USDC collateral and open a long or short position with a chosen leverage. The
  collateral is held by `TradingStorage`, not by the vault.
- **LPs** deposit USDC into the vault and receive sUSDC shares. The vault is the counterparty to every
  trade: trader profits are paid from the vault and trader losses are sent to it. The share price uses a
  conservative NAV: the USDC balance minus the net unrealised trader profit recorded in the latest PnL
  snapshot (net trader losses are not added), so it falls when a snapshot shows traders in profit and
  rises when losing positions settle. There is no impermanent loss in the AMM sense because the vault
  holds only USDC, but LPs can lose part of their deposit when traders are net profitable.
- **Keepers and bots** are needed for liveness: liquidations and TP/SL execution are permissionless and
  paid from trader collateral, `SolvencyManager.checkAndAct` and `AssistantFund.skim` are permissionless
  and unpaid, and the spread volatility input is set by a single keeper address.
- **Funding** moves value between the long and short traders of a pair, from the heavier side to the
  lighter side, at most 0.01% of the heavier side's notional per hour.

---

## Architecture

```mermaid
flowchart TD
    Trader([Trader]) -->|openTrade, closeTrade, updateTp, updateSl| Engine
    Bot([Liquidator / executor bot]) -->|liquidate, executeLimit| Engine
    Engine[TradingEngine] -->|trades, OI, funding index| Storage[TradingStorage]
    Engine -->|getPrice, fee in msg.value| Oracle[PythChainlinkOracle]
    Oracle -->|updatePriceFeeds, getPriceUnsafe| Pyth[(Pyth)]
    Oracle -->|latestRoundData| Chainlink[(Chainlink feed)]
    Oracle -->|latestRoundData| Sequencer[(Chainlink sequencer uptime feed)]
    Engine -->|getSpreadBps| Spread[SpreadManager]
    Keeper([Keeper]) -->|updateVolatility| Spread
    Storage -->|collateral held for open trades, returned on close| Trader
    Storage -->|trader losses, 80% of fees| Vault[Vault ERC-4626]
    Storage -->|20% of fees to treasury| AF[AssistantFund]
    Engine -->|sendPayout: trader profit| Vault
    LP([LP]) -->|deposit, mint, requestWithdrawal, executeWithdrawal, refreshAnd*| Vault
    Anyone([Anyone]) -->|checkAndAct, refreshAndCheckAndAct| SM[SolvencyManager]
    Anyone -->|refreshPnlSnapshot + Pyth update data| Vault
    Vault -->|open PnL aggregates, positions nonce| Storage
    Vault -->|getPrice per pair with open interest| Oracle
    SM -->|reads NAV and realised ratios and deficits, snapshot freshness| Vault
    SM -->|injectFunds| AF
    AF -->|injected USDC, skim above targetCap| Vault
    SM -->|activateBonding, closeBonding| BD[BondDepository]
    Bonder([Bonder]) -->|bond: USDC| BD
    BD -->|USDC transferred to the Vault| Vault
    BD -->|mint| Synth[SynthToken]
```

Notes on the diagram:

- The treasury address is a constructor argument of `TradingEngine`. `script/Deploy.s.sol` sets it to the
  `AssistantFund`; the unit tests use a plain address.
- `TradingStorage` pays the liquidator reward and the TP/SL executor reward out of the position's
  collateral. The vault never pays these rewards.
- `SolvencyManager` holds no funds. It reads the vault ratios and calls `AssistantFund.injectFunds` and
  `BondDepository.activateBonding`, which only accept calls from it.
- The vault reads the open PnL aggregates from `TradingStorage` and prices them with the same oracle as the
  engine when its PnL snapshot is refreshed.

### Oracle design

Each price-consuming call carries Pyth update data from the caller, who pays the Pyth update fee in
`msg.value`; the engine refunds `msg.value` minus the fee actually paid. The oracle rejects prices older
than `maxPriceAge` (5 seconds by default, owner-set up to a 30 second ceiling), published after the
current block, or with a confidence interval wider than 2% of the price, and reverts if the Pyth price
differs from the Chainlink answer by more than 3% or if the Chainlink answer is older than the configured
heartbeat. On L2s it also reverts while the Chainlink sequencer uptime feed reports the sequencer down and
for one hour after it comes back. Chainlink is never used as a fallback price.

Design note: a custom oracle network (a set of nodes publishing a median price) was considered early on
and dropped, because keeping it live requires running and monitoring backend services. Pyth pull
updates anchored to Chainlink are used instead.

### Solvency layers

- **Layer 1, preventive:** payout cap, static per-pair OI cap and dynamic spread; volatility-adaptive OI
  caps are designed only. The payout cap limits collateral plus price PnL to 9x the collateral.
- **Layer 2, reserve:** `AssistantFund` receives the 20% fee share (when it is set as the treasury) and
  `SolvencyManager.checkAndAct` injects it into the vault when the NAV ratio is below 100% and the PnL
  snapshot is fresh.
- **Layer 3, bonding:** below a 95% realised ratio, `checkAndAct` opens a round in which anyone can buy
  $SYNTH at a discount; the USDC goes to the vault and the $SYNTH vests linearly.

The NAV ratio, called the LP principal coverage ratio in the docs, is `totalAssets * 1e12 * 1e18 /
totalSupply` with the conservative NAV: the share price relative to its 1.0 starting value. It measures
whether the NAV covers the principal LPs would have paid in at 1.0; it does not measure whether the vault can
pay every open trade at its cap, or how much of the NAV is liquid USDC. Deposits revert while it is below
100%. The realised ratio is the same formula on the USDC balance alone and is never below the NAV ratio;
bonding uses it so that $SYNTH is not sold at a discount because of an unrealised move that can reverse.
Formulas: [Guide 2, section 8](./docs/02-mathematics.md#8-collateralization-ratio-and-solvency-actions).

---

## Trust assumptions and limitations

**Owner powers.** Each contract has one `Ownable` owner, with no timelock or multisig in code. The owner
can:

- Point `Vault.tradingEngine` and `TradingStorage.tradingEngine` at any address. That address can then
  move all vault USDC (`sendPayout`) and all trader collateral (`sendCollateral`).
- Point `Vault.solvencyManager` at any address; every deposit path calls it before minting. Until it is set
  (`DeployLib.wire` sets it), deposits skip the rescue step: they neither run a pending injection first nor
  stop for bonding.
- Set independent pause flags: on `TradingEngine`, `PAUSE_OPEN` (blocks `openTrade`) and `PAUSE_SETTLE`
  (blocks `closeTrade`, `executeLimit` and `liquidate` together, and stops funding from accruing); on the
  vault, `PAUSE_DEPOSIT` (blocks `deposit`, `mint` and their refresh-and-act variants) and `PAUSE_WITHDRAW`
  (blocks `requestWithdrawal`, `executeWithdrawal` and `refreshAndExecuteWithdrawal`, and stops the expiry
  clock of pending requests). `updateTp`, `updateSl`, `cancelWithdrawal`, `refreshPnlSnapshot`,
  `checkAndAct`, `bond`, `claim`, `skim` and sUSDC transfers are never paused. Which flags to set for each
  incident: [Guide 8, section 6](./docs/08-security.md#6-incident-playbook).
- Add pairs (up to `MAX_PAIRS`, 20) with any `maxLeverage` up to `MAX_LEVERAGE` (100) and any `maxOI`, and
  change or deactivate them.
- Set the maximum PnL snapshot age (`setMaxPnlSnapshotAge`, 1 s to the immutable 3,600 s ceiling).
- Set oracle feeds (`setPairFeed`), the Pyth price age (`setMaxPriceAge`, 1 to 30 s), the funding factor
  (`setFundingFactor`, within 1e12 to 1e15; the 0.01% per hour ceiling is a constant), all `SpreadManager`
  parameters and its keeper, the treasury address, the `AssistantFund` target cap, the bond
  `referencePrice`, discount (up to 10%) and vesting period (up to 7 days), and the $SYNTH minter (which
  can mint without limit).

**Keepers and off-chain actors.** Liquidation and TP/SL execution rely on third-party bots. The
liquidator reward is `max(10% of the collateral left after the loss, 0.5% of the collateral)`: 1% at the
threshold, never below 0.5%, also past a 100% loss, always paid from the position's collateral. The
spread volatility input depends on one keeper address. `checkAndAct` and `skim` have no reward.

**Oracle assumptions.** Prices depend on Pyth publishers, Wormhole-signed updates and Chainlink. If the
Pyth price is too old, its confidence band is too wide, the Chainlink answer is stale, the two disagree
by more than 3%, or the L2 sequencer is down, every price-consuming call reverts, including
`closeTrade`, `executeLimit` and `liquidate`. For one hour after the sequencer comes back, only `openTrade`
reverts: a position cannot be topped up, so a liquidation realises the same loss as a close (only the reward
differs), and blocking liquidations would let positions run past 100% loss at the vault's expense. Fetching Pyth updates from Hermes requires an API key since
the Pyth Core upgrade of 2026-08-26.

**LP risk.** LPs are the counterparty to trader PnL and can lose part of their deposit.

**Withdrawal lock.** Withdrawals go through `requestWithdrawal`, which escrows the shares, and
`executeWithdrawal` in the epoch that starts 3 epochs later, which pays at the conservative NAV of the
execution moment and needs a fresh PnL snapshot. After that epoch the request expires, later by the time
spent under `PAUSE_WITHDRAW` since the request (whole epochs, rounded up); `cancelWithdrawal` or a new
request returns the shares.

**Known limitations.**

- **Funding bad debt.** Funding receivers are credited as it accrues, while a payer settles at close or
  liquidation. If a payer ends with a loss above its collateral, the unpaid part of its funding is covered
  by the vault: `unpaid = max(0, fundingOwed - max(0, collateral + min(PnL, 8 x collateral) - reward))`.
  At a flat price, with the 0.01% per hour ceiling, 100x and liquidation at 90%, this needs the payer to
  stay unliquidated for more than 9.5 hours after crossing the threshold, and then grows by at most 1% of
  its collateral per hour ([Guide 2](./docs/02-mathematics.md#residual-funding-a-payer-cannot-pay)).
- **Oracle latency window.** Within `maxPriceAge` (5 s) the caller still chooses which Pyth update to
  submit, so a trader can open on a price up to 5 seconds old and close on the current one. The round trip
  costs about 26 BPS of notional with the deploy parameters.
- **Deposits have no lock.** A deposit first runs the pending AssistantFund injection and mints at the NAV,
  so a new LP cannot take part of an injection pending when it deposits, or enter at a price that ignores
  open trader profit. Two effects remain. The NAV does not add net trader losses, so a new LP can enter
  while traders are net losing and share in those losses when they settle: a deposit `D` into a NAV `A` takes
  `D x L / (A + D)` of a later realised loss `L`, from the LPs already in. And below 100% coverage with the
  AssistantFund empty, a new LP also shares in injections that fees fund later.
- **NAV biases.** The NAV ignores the 9x payout cap (it overstates trader profit by
  `sum max(0, pnl_i - 8 x collateral_i)`, conservative) and clamps losses per pair side, not per position:
  a position past 100% loss that is not yet liquidated offsets winners on its side, understating the
  liability by at most its excess loss `E = sum max(0, -pnl_i - collateral_i)`. E is zero until a position
  passes 100% loss without being liquidated, so it is bounded by liquidation latency
  ([Guide 2, section 8.2](./docs/02-mathematics.md#82-known-biases-of-the-nav)).
- **Snapshot age window.** `deposit`, `mint` and `executeWithdrawal` accept a snapshot up to
  `maxPnlSnapshotAge` old (60 s by default, owner-set up to 3,600 s) if no position opened or closed since.
  Within that window an LP can act on the stored snapshot or refresh first with a Pyth update of their
  choice (within the oracle's `maxPriceAge`); the difference is the price move since the snapshot times the
  open quantity. `totalAssets` and the previews use the latest snapshot even when it is stale.
- **Deposits are refused while bonding is open or due.** A deposit reverts with `BondingRoundOpen` while a
  round is open, or when the realised ratio is below 95% and the AssistantFund cannot cover the realised
  deficit (the check would open a round). A round that finds no bonders (for example with an unattractive
  `referencePrice`) keeps deposits closed until the realised ratio recovers through fees or trader losses, or
  the round fills. Withdrawals keep working at the NAV. There is no owner override
  ([Guide 7](./docs/07-vault-ssl.md#known-biases-and-the-deposit-freeze)).
- **Pause flags.** `PAUSE_SETTLE` stops closes, TP/SL execution and liquidations together and freezes
  funding, but prices keep moving: positions can pass 100% loss while it is set and settle with bad debt when
  it is cleared, and the NAV's optimistic bias (the excess loss `E` above) grows meanwhile. Vault flags do not
  stop settlements, and engine flags do not stop LP flows, so the owner has to set both when an incident
  affects both sides. `PAUSE_WITHDRAW` extends pending requests' expiry in whole epochs, rounded up. No flag
  protects against the owner ([Guide 8, sections 5 and 6](./docs/08-security.md#5-pause-flags)).
- **`claim` has no pause lever, by decision.** A bug in the vesting math could move escrowed $SYNTH between
  bonders; the depository's escrow holds only $SYNTH, so no USDC is at risk from `claim`. A pause on `claim`
  would itself trap bonders' vested $SYNTH ([Guide 8, section 6](./docs/08-security.md#6-incident-playbook)).
- **Thin-side funding.** When one side of a pair is small, each unit on that side receives the heavier side's
  rate times `OI_heavy / OI_light` per hour; the total credited to the light side is at most what the heavy
  side pays ([Guide 2](./docs/02-mathematics.md#thin-side-funding)).
- **ERC-4626 integrators.** `deposit`, `mint` and `executeWithdrawal` need a fresh PnL snapshot while trades
  are open, and any open or close invalidates it, so a plain call usually reverts with `StalePnlSnapshot`.
  Integrators should use `refreshAndDeposit`, `refreshAndMint` and `refreshAndExecuteWithdrawal`, which
  refresh and act in one transaction.
- **Aggregate scale.** A position whose quantity (size / open price, 18 decimals) does not fit a uint128
  reverts on open (at a 1 wei price the bound is 340.282366 USDC of notional,
  `test_StoreTrade_QuantityAtUint128Bound`); the snapshot math overflows only when (price + conf) times a
  side's quantity exceeds 2^256, which needs the price to move by a factor above about 1e20 from the open
  price (`test_PairPnl_OverflowOnlyAboveTwoToThe256`).
- **A winning close can revert.** `closeTrade` and `executeLimit` revert with `InsufficientVaultBalance`
  when the vault holds less USDC than the profit owed, until the vault is refilled.

---

## Testing

Measured on 2026-09-29 at commit `47d848f` (branch `fix/pause-flags`) with forge 1.7.1 and solc 0.8.24
(fixed by the pragma in every source file; `foundry.toml` does not pin `solc`), after `npm ci`. Later
commits change documentation and, in `ca89c02`, the `file:line` references of cast comments (same line
count, same runtime sizes). Details, including the invariant call distributions
and the static analysis triage: [docs/tests/README.md](./docs/tests/README.md).

| Command | Result |
| :------ | :----- |
| `forge build` | Compiles (optimizer on, 200 runs). It fails before `npm ci` because the Pyth SDK is an npm dependency |
| `forge build --sizes` | Exits 0. Runtime bytes: `TradingEngine` 17,701 (6,875 under the 24,576 byte limit), `Vault` 14,080, `TradingStorage` 10,286, `BondDepository` 5,217, `PythChainlinkOracle` 5,120, `SolvencyManager` 4,759, `SynthToken` 3,561, `SpreadManager` 2,660, `AssistantFund` 2,090 |
| `FORK_RPC_URL= forge test` | 818 tests: 797 passed, 0 failed, 21 skipped (the fork suite) |
| `forge test --list --json 2>/dev/null \| jq '[.[][][]] \| length'` | 818: unit 659, regression 70, integration 17, invariant campaigns 51 (43 in `test/invariant/`, 8 in `test/integration/`), fork 21 |
| `forge test --list --json 2>/dev/null \| jq '[.[][][] \| select(startswith("testFuzz_"))] \| length'` | 54 functions named `testFuzz_*` (256 runs each, Foundry default): 13,824 fuzz cases per full run |
| `forge test --list --json 2>/dev/null \| jq '[.[][][] \| select(startswith("invariant_"))] \| length'` | 51 invariant campaigns (256 runs x 500 calls each, Foundry default): 6,528,000 invariant calls per full run. They check 32 distinct properties (`grep -c "function invariant_"` per suite: 19 protocol, 5 bonding, 8 solvency integration); the keeper latency suite reruns the 19 protocol properties in a second configuration |
| `FORK_RPC_URL=<arbitrum-one-archive-rpc> forge test --match-path "test/fork/*"` | 21 passed at the pinned block 504,522,171 |
| `FOUNDRY_PROFILE=gas forge test` | 14 gas benchmarks passed, written to `snapshots/*.json`; not part of the 818 |
| `forge fmt --check` | Exits 0 |
| `forge lint src` | 8 `block-timestamp` warnings, all intentional comparisons with `block.timestamp`; no other lint |
| `FORK_RPC_URL= FOUNDRY_PROFILE=coverage forge coverage --report summary` | Per contract below. The `coverage` profile only lifts the contract size limit, since coverage builds run without the optimizer |

| Contract | Lines | Statements | Branches | Functions |
| :------- | :---- | :--------- | :------- | :-------- |
| AssistantFund | 100% (33/33) | 100% (37/37) | 100% (6/6) | 100% (9/9) |
| BondDepository | 100% (92/92) | 100% (116/116) | 100% (23/23) | 100% (18/18) |
| PythChainlinkOracle | 100% (56/56) | 100% (89/89) | 100% (16/16) | 100% (8/8) |
| SolvencyManager | 100% (57/57) | 100% (82/82) | 100% (13/13) | 100% (9/9) |
| SpreadManager | 100% (54/54) | 100% (58/58) | 100% (13/13) | 100% (12/12) |
| SynthToken | 100% (23/23) | 100% (18/18) | 100% (4/4) | 100% (9/9) |
| TradingEngine | 100% (281/281) | 100% (412/412) | 100% (69/69) | 100% (38/38) |
| TradingStorage | 100% (153/153) | 100% (159/159) | 100% (34/34) | 100% (34/34) |
| Vault | 100% (213/213) | 100% (284/284) | 100% (34/34) | 100% (50/50) |
| FundingLib | 100% (16/16) | 100% (28/28) | 100% (4/4) | 100% (3/3) |
| OpenPnlLib | 100% (21/21) | 100% (32/32) | 100% (5/5) | 100% (4/4) |

Every branch of `src/` is taken by at least one test; line coverage says a line ran, not that its result was checked.

The protocol invariant suites run the whole system (engine, vault, AssistantFund, SolvencyManager wired as
the vault's deposit check, bonding) with `MockOracle` on three pairs with a nonzero confidence band. They
model every settlement and LP or solvency flow and check the vault and reserve balances against the model,
that funding credits never exceed charges, that the vault's funding exposure stays within the tracked bad
debt, that storage holds exactly the open collateral, that escrowed shares match pending requests, that an
injection never lifts the NAV ratio above 100% and a bond never lifts the realised ratio above 100%, that
`totalAssets` is the balance minus the snapshot liability, that the open PnL aggregates equal the open
positions per pair and side, that every snapshot equals a brute-force valuation and stays within the
excess-loss bound, that deposits follow the rescue rule, that no bonding round opens at a realised ratio of
95% or more, that no close, TP/SL execution or liquidation succeeds under `PAUSE_SETTLE`, that no withdrawal
request expires because of time under `PAUSE_WITHDRAW`, and that no funding accrues under `PAUSE_SETTLE`. The
handler sets and clears each of the four pause flags on its own. The keeper latency suite reruns the same
properties with liquidations one day late. In the last run of every campaign of both suites some snapshot
refreshes had positions past 100% loss (excess loss `E > 0`): 9 to 19 of 23 refreshes with a largest `E`
between 514 and 55,199 USD in the latency suite, 3 to 18 of 28 with a largest `E` between 2,462 and 27,776
USD in the default suite, where `PAUSE_SETTLE` holds liquidations back while prices move (from
`FOUNDRY_INVARIANT_SHOW_METRICS=true forge test --match-contract "^ProtocolKeeperLatencyInvariantTest$" -vv`
and the same command with `"^ProtocolInvariantTest$"`).

Gas of one call per entry point, from `FOUNDRY_PROFILE=gas forge test` (`snapshots/*.json`), with the real
`PythChainlinkOracle` on `MockPyth` (no Wormhole signature verification) and the real `SpreadManager`. CI
runs the benchmarks as a pass/fail job and does not compare gas values.

| Function | Gas |
| :------- | --: |
| `TradingEngine.openTrade` (with TP and SL) | 300,422 |
| `TradingEngine.closeTrade` (profit) | 129,992 |
| `TradingEngine.liquidate` | 127,387 |
| `TradingEngine.executeLimit` (TP) | 159,046 |
| `Vault.deposit` (fresh snapshot, runs `checkAndActBeforeDeposit`) | 65,782 |
| `Vault.refreshAndDeposit` | 187,280 |
| `Vault.requestWithdrawal` | 64,293 |
| `Vault.executeWithdrawal` (fresh snapshot) | 34,384 |
| `Vault.refreshAndExecuteWithdrawal` | 157,878 |
| `Vault.refreshPnlSnapshot`, 1 pair | 126,603 |
| `Vault.refreshPnlSnapshot`, 20 pairs (`MAX_PAIRS`), a long and a short on each | 640,715 |
| `SolvencyManager.checkAndAct` (injects the reserve, opens a bonding round) | 64,396 |
| `SolvencyManager.refreshAndCheckAndAct` (same path) | 197,121 |
| `BondDepository.bond` | 139,037 |

**Fork tests.** `test/fork/PythChainlinkOracle.fork.t.sol` runs against Arbitrum One at
`FORK_BLOCK_NUMBER` (default 504,522,171), a block right after an on-chain Pyth update of BTC/USD and
ETH/USD, so the stored prices are fresh and no Hermes call or `ffi` is needed (`ffi = false`). It checks
that every address has code, that the Pyth proxy runs the implementation installed by the Pyth Core
upgrade, the update fee (0 wei), a recorded signed update, the sequencer uptime feed and its grace period
(openings refused, closes allowed), an open and close through `TradingEngine`, and a snapshot refresh and
`refreshAndDeposit` on the vault.

**Static analysis.** Slither 0.11.6 and Aderyn 0.6.8 at commit `47d848f` (commands in
[docs/tests/README.md](./docs/tests/README.md#static-analysis)). Slither: 199 results, of which 14 are false
positives and 185 accepted by design; 2 results of the round 3 baseline were fixed and 4 disappeared with the
removed pause events. Aderyn: 64 instances (3 High issues, 8 Low), of which 3 are false positives and 61
accepted by design; 4 instances were fixed in round 3. Every result has a verdict and a reason in the
[triage table](./docs/tests/README.md#triage).

---

## Review notes

Findings from the round 1 review, fixed in round 2 on branch `fix/review-findings` (entries 1 to 14) and in
round 2b on branch `fix/open-pnl-nav` (entries 15 and 16), the round 3 hardening on branch
`hardening/final` (entries 17 to 25) and round 3b on branch `fix/pause-flags` (entries 26 to 28). The tests named `test_Regression_*` (and `testFuzz_Regression_*`)
failed against the code before their fix; the other tests in the same files pass before and after.

1. **Funding paid by the vault, not normalised (High).** Cause: the index moved by the absolute USD
   imbalance (a 1,000 USD imbalance gave 3.6% of notional per hour) and settled against the vault, so a
   10 USDC x100 short next to a 1,000 USDC x100 long closed with 57.82 USDC after 60 seconds at a flat
   price, and one account holding a long and 50 shorts drained 2,294.14 USDC in 160 seconds. Fix: rate
   proportional to the relative skew, capped at 0.01% per hour, per-side indexes, the lighter side
   receives what the heavier side pays, payers round up and receivers down, funding settled after the 9x
   cap. Tests: `test/regression/FundingRegression.t.sol`, `test/unit/FundingLib.t.sol`,
   `testFuzz_Funding_FundsConservation`. Commit `2dcf3ff`.
2. **Withdrawal requests without expiry or escrow; `max*` functions (Medium).** Cause: a request stayed
   executable forever after 3 epochs and its shares stayed transferable; `maxWithdraw`/`maxRedeem` and
   `maxDeposit`/`maxMint` did not match what the vault accepts. Fix: shares escrowed in the vault, a
   1-epoch execution window, `max*` aligned with the actions. Tests:
   `test/regression/WithdrawalRegression.t.sol`, `Vault.t.sol` max* and window tests. Commit `ad38b4f`.
3. **Oracle latency (Medium).** Cause: any update up to 30 seconds old was accepted, so a trade could open
   on a 25 second old price and close on the current one; a future `publishTime` underflowed. Fix:
   `maxPriceAge` (default 5 s, owner-set up to 30 s) and `PriceFromFuture`. Tests:
   `test/regression/OracleLatencyRegression.t.sol`. Commit `b62e786`.
4. **No L2 sequencer uptime check; fork suite not reproducible.** Cause: no sequencer check; the fork tests
   targeted HyperEVM at the latest block and called Hermes through `ffi`. Fix: Chainlink sequencer uptime
   feed with a 1 hour grace period (constructor parameter, `address(0)` disables it); fork suite on
   Arbitrum One at a pinned block without Hermes, `ffi = false`. Tests:
   `test/regression/SequencerRegression.t.sol`, `test/fork/PythChainlinkOracle.fork.t.sol`. Commits
   `b657eb9`, `2aa12c2`.
5. **No global leverage cap.** Cause: leverage was limited only by each pair's owner-set `maxLeverage`. Fix: `MAX_LEVERAGE = 100` in pair configuration and on open. Tests:
   `test/regression/LeverageRegression.t.sol`. Commit `c7e702f`.
6. **Opening guard (Low).** Cause: the guard used the open spread and the gross collateral, so with a
   50 BPS spread a 100x position could be liquidated in the block it opened. Fix: close spread at the
   post-open OI and collateral net of the open fee. Tests: `test/regression/OpenGuardRegression.t.sol`,
   and `test_OpenTrade_RevertWhenPreLiquidatable`, which reverted on slippage instead of the guard. Commit
   `dc027f8`.
7. **Zero liquidator reward past 100% loss (Medium).** Cause: the reward was 10% of the collateral left
   after the loss, which is zero once the loss reaches the collateral, so nobody was paid to liquidate
   positions past 100% loss. Fix: reward `max(10% of remaining, 0.5% of
   collateral)`, paid from the position's collateral. Tests:
   `test/regression/LiquidationRewardRegression.t.sol`. Commit `977ba1e`.
8. **Linear `deleteTrade` (Low).** Cause: `deleteTrade` searched the user's trade list, so a user with
   many open trades made each of its liquidations more expensive. Fix: swap and pop with the position stored in `Trade.userIndex`. Tests:
   `test/regression/DeleteTradeRegression.t.sol`. Commit `7475469`.
9. **Force-sent ETH paid to the next caller (Low).** Cause: the engine refunded its whole ETH balance, so
   ETH sent to it outside a call went to the next caller. Fix: refund `msg.value` minus the fee actually paid,
   with the entry balance kept in transient storage. Tests: `test/regression/EthRefundRegression.t.sol`.
   Commit `52aa4ee`.
10. **`updateTp`/`updateSl` without `nonReentrant` (Low).** Cause: both call the oracle and refund ETH
    without the guard the other entry points have. Fix: guard added. Tests:
    `test/regression/ReentrancyRegression.t.sol`. Commit `a236103`.
11. **Bonding round not closed when CR recovers (Low).** Cause: a round closed only when its cap was used
    up, so after the vault recovered by other means bonders could keep buying discounted $SYNTH. Fix: a bond takes at most the current deficit and
    closes the round when it covers it; `checkAndAct` closes the round at CR >= 100%. Tests:
    `test/regression/BondingRoundRegression.t.sol`. Commit `6668365`.
12. **Stale NatSpec and unused error (Info).** Cause: comments described earlier designs. Fix: `TradingEngine` header (fixed spread), `IOracle` (custom
    DON example), `BondDepository` header (keeper-maintained price); `ZeroFeeRecipient` removed. Commits
    `e42bd1b`, `6668365`, `8726c55`.
13. **A winning close reverts when the vault is short of USDC (Info).** Cause: `sendPayout` needs the USDC
    in the vault. No code change; documented under Known limitations.
14. **Test suite (Info).** Weak or tautological invariants replaced, call summaries moved to
    `afterInvariant`, tolerances tightened, `test_CloseTrade_UsesSpreadOnClose` given an assertion,
    compiler warnings removed. Commits `37119cf`, `7a51384`, `857580a`, `0577333`, `aaceb08`.
15. **LP timing, part c: the share price ignored unrealised PnL.** Cause: `totalAssets` was the USDC
    balance, so withdrawals, deposits and previews were priced without the open trader PnL; an LP could exit
    ahead of a large unrealised trader profit and leave it to the LPs who stayed
    (`test_Regression_Nav_WithdrawalPaidAtConservativeNav`, run against the `src/` of commit `c359a1b`, paid
    500,159.999999 USDC instead of 488,780.689655 at the NAV). Fix: per pair and side aggregates in `TradingStorage` (size, collateral, quantity, removal
    exact), a PnL snapshot refreshed permissionlessly through the oracle checks (confidence edge that shows
    the most trader profit, at most `MAX_PAIRS` = 20 pairs), `totalAssets` = balance minus the positive
    snapshot, a maximum snapshot age for `deposit`, `mint` and `executeWithdrawal` with refresh-and-act entry
    points, and `sendPayout` checked against the balance. Tests: `test/regression/OpenPnlNavRegression.t.sol`,
    `test/regression/MaxPairsRegression.t.sol`, `test/unit/VaultNav.t.sol`, `test/unit/OpenPnlLib.t.sol`, the
    aggregate tests in `test/unit/TradingStorage.t.sol`. Commits `c359a1b`, `e225c14`.
16. **LP timing, the ratio: deposits below 100% and solvency triggers on the balance.** Cause: the
    collateralization ratio ignored open PnL, a deposit below 1.0 took part of the next injection (in
    `test_Regression_DepositBelowPar_InjectionSettledFirst`, run against commit
    `e225c14`, a 1,000,000 USDC deposit at a 90% ratio was worth 1,052,631.578947 USDC after a 100,000 USDC
    injection), and once the ratio included open PnL, an unrealised move could have opened a discounted
    $SYNTH round. Fix: the ratio (LP
    principal coverage ratio) uses the NAV; deposits and mints reverted below 100% (`CoverageBelowPar`,
    replaced in round 3 by entry 18); the injection follows the NAV ratio with a fresh snapshot; bonding
    opens, sizes, clamps and closes on the realised ratio. Tests:
    `test/regression/DepositCoverageRegression.t.sol`, `test/regression/SolvencySplitRegression.t.sol`,
    `test/unit/SolvencyManager.t.sol`. Commits `1ccbe10`, `d83c52b`.
17. **The sequencer grace period blocked closes and liquidations (Medium).** Cause: for one hour after the
    L2 sequencer came back, `getPrice` reverted for every caller, so closes, TP/SL execution, liquidations,
    snapshot refreshes, LP withdrawals and `checkAndAct` were blocked; a position cannot be topped up, so a
    blocked liquidation could let it run past 100% loss at the vault's expense. Fix: `getPrice` reverts only
    while the sequencer is down; `IOracle.checkOpenAllowed`, called by `openTrade` only, reverts during the
    grace period. Tests: `test/regression/SequencerGraceScopeRegression.t.sol` (six tests failed before with
    `SequencerGracePeriodNotOver`), `test_Fork_TradingEngine_GracePeriodClosesButDoesNotOpen` (failed before
    on the fork). Commit `16baf19`.
18. **Deposits frozen below 100% coverage with no rescue left (Medium).** Cause: round 2b reverted every
    deposit and mint below a 100% coverage ratio; with the AssistantFund empty and no bonding round due,
    nothing lifted the ratio, so deposits stayed closed with no time limit. Fix: every deposit path first calls
    `SolvencyManager.checkAndActBeforeDeposit`, so the pending AssistantFund injection lands and shares are
    minted at the post-injection NAV; the deposit reverts with `BondingRoundOpen` only while a bonding round is
    open or due; `maxDeposit` and `maxMint` follow a view mirror of that check. Tests:
    `test/regression/DepositRuleRegression.t.sol` (six tests failed before with `CoverageBelowPar`),
    `test/regression/DepositCoverageRegression.t.sol` (rewritten; five failed before),
    `test/unit/VaultDepositRule.t.sol`, invariant `DepositsFollowRescueRule`. Commit `21d9361`.
19. **`setFundingFactor` wrote state after external calls (Slither `reentrancy-no-eth`, Aderyn H-2).**
    Cause: it accrued every pair through `TradingStorage` and then wrote the factor. Fix: it writes the factor
    first and accrues at the old factor passed as a parameter; no behaviour change,
    `test_SetFundingFactor_AccruesElapsedTimeAtOldFactor` passes before and after and neither tool reports it.
    Commit `52d7c2b`.
20. **Unreachable `FeeExceedsCollateral` check (Info).** Cause: the open fee rate is a constant and leverage
    above 100 reverts before the fee is computed, so the fee is at most 8% of the collateral. Fix: check and
    error removed. Test: `testFuzz_OpenFee_BelowCollateralForEveryAcceptedLeverage`. Commit `0dcdd6c`.
21. **Entry funding index left after a delete (Info).** Cause: `deleteTrade` kept `_tradeFundingIndex`;
    trade IDs are never reused, so no trade could read another's value. Fix: cleared on delete. Test:
    `test_DeleteTrade_ClearsTradeFundingIndex` (failed before: `42000000000000000000 != 0`). Commit
    `6d99400`.
22. **Downcasts that truncated (Low).** Cause: three casts truncated instead of reverting: the oracle's
    normalized price for a feed with a positive exponent, a bond's $SYNTH above 2^128, and the open-direction
    spread price near 2^128. Fix: `SafeCastLib` for those three; every other downcast or signed cast carries
    a one-line comment with its bound and the `file:line` that enforces it. Tests:
    `test/unit/TypecastBounds.t.sol` (three tests failed before). Commit `4145744`.
23. **`msg.value` inside the snapshot refresh loop (Slither `msg-value-loop`, 4 results).** Cause: flagged
    because `msg.value` appears in a loop. Checked: it is sent to the first priced pair only. No code change.
    Test: `test/unit/VaultRefreshFee.t.sol`. Commit `2d88c2d`.
24. **`maxWithdraw` and `maxRedeem` reported as not covered (Info).** Cause: forge coverage attributed no
    hits to their `return 0;` lines although the functions ran. Fix: empty bodies returning the default 0.
    Commit `120adca`.
25. **`collateralizationRatio` public without internal use (Aderyn L-9, Info).** Fix: `external`. Commit
    `2dd5562`.
26. **One pause per contract blocked the wrong combinations (Medium).** Cause, from the round 3 pause
    review: `TradingEngine.pause` blocked closes and TP/SL execution but not `liquidate`, so a trader who
    could not close could still be liquidated and pay the reward, and funding kept accruing; `Vault.pause`
    blocked withdrawal requests together with deposits, a pause longer than the one-epoch execution window
    let pending requests expire, and it did not stop settlements. Fix: independent flags (`PAUSE_OPEN`,
    `PAUSE_SETTLE` on the engine, with `liquidate` under `PAUSE_SETTLE` and no funding accrual while it is
    set; `PAUSE_DEPOSIT`, `PAUSE_WITHDRAW` on the vault, with the expiry clock stopped under
    `PAUSE_WITHDRAW`); `updateTp` and `updateSl` are never paused. Tests:
    `test/regression/PauseFlagsRegression.t.sol` (five tests failed before: the liquidation went through,
    `EnforcedPause()` on a close and on a withdrawal request, `WithdrawalExpired(4)`, and funding of
    19718181818181621 instead of 81818181818181 index units), invariants `NoSettlementWhileSettlePaused`,
    `WithdrawPauseDoesNotExpireRequests` and `NoFundingAccruesWhileSettlePaused`. Commit `3422f8e`.
27. **Reverts never taken in coverage (Info).** Round 3 coverage listed nine branches never taken, all
    reverts. Fix: tests for eight of them in `BondDepository.t.sol`, `TradingEngine.t.sol` and `Vault.t.sol`
    (commit `1a7442c`); the ninth was the unreachable check of entry 28.
28. **Unreachable `ReferencePriceUnset` check (Info).** Cause: `referencePrice` starts at 2 USDC and
    `setReferencePrice` rejects 0, so the check in `activateBonding` could not revert. Fix: check and error
    removed. Commit `b5e0f1a`.

---

## Getting started

Requirements: [Foundry](https://getfoundry.sh/) forge 1.7.1 (CI pins `v1.7.1`, the version every number in
this README was measured with; forge 1.8.x measures gas and counts invariant campaigns differently), Node.js 22.14 or later with npm (the Pyth SDK declares `engines: node >=22.14.0`; CI uses Node 22),
Git. For the fork tests, an Arbitrum One RPC URL that serves historical state (archive).

```bash
git clone --recursive https://github.com/GushALKDev/evm-synthetic-trading-protocol
cd evm-synthetic-trading-protocol
npm ci                  # required: installs @pythnetwork/pyth-sdk-solidity, remapped from node_modules/
forge build
FORK_RPC_URL= forge test   # mock mode: the fork tests skip
FORK_RPC_URL=<arbitrum-one-archive-rpc> forge test --match-path "test/fork/*"   # fork mode
```

Forge loads a `.env` file from the project root automatically. Mock mode therefore needs
`FORK_RPC_URL` to be absent or empty in both the shell and `.env` (for example `FORK_RPC_URL= forge test`).

Other commands:

```bash
forge test --match-path "test/regression/*"    # regression tests for the review findings
forge test --match-path "test/invariant/*"     # invariant suites
forge test --match-path "test/integration/*"   # full wired system
FORK_RPC_URL= FOUNDRY_PROFILE=coverage forge coverage --report summary   # coverage profile lifts the size limit
FOUNDRY_PROFILE=gas forge test                 # gas benchmarks, written to snapshots/
FORGE_SNAPSHOT_CHECK=true FOUNDRY_PROFILE=gas forge test   # fails if a value differs from snapshots/
forge fmt --check
forge lint src
```

| Variable | Used by | Required |
| :------- | :------ | :------- |
| `FORK_RPC_URL` | fork tests | Only for fork tests (Arbitrum One, archive) |
| `FORK_BLOCK_NUMBER` | fork tests | Optional, defaults to 504,522,171 |
| `PRIVATE_KEY`, `USDC_ADDRESS`, `PYTH_ADDRESS` | `script/Deploy.s.sol` | For deployment |
| `OWNER_ADDRESS`, `KEEPER_ADDRESS` | `script/Deploy.s.sol` | Optional, default to the deployer |
| `SEQUENCER_UPTIME_FEED` | `script/Deploy.s.sol` | Optional, defaults to `address(0)` (no check); on Arbitrum One `0xFdB631F5EE196F0ed6FAa767959853A9F217697D` |

`script/Deploy.s.sol` deploys the nine contracts and, when the owner is the deployer, grants the
cross-contract permissions. Pairs and oracle feeds are left to the owner (`addPair`, `setPairFeed`). The
deploy script was not run in this review.

---

## Documentation

| Document | Content |
| :------- | :------ |
| [docs/README.md](./docs/README.md) | Index |
| [docs/01-fundamentals.md](./docs/01-fundamentals.md) | Model and trade lifecycle |
| [docs/02-mathematics.md](./docs/02-mathematics.md) | Formulas as implemented, with rounding |
| [docs/03-architecture.md](./docs/03-architecture.md) | Contracts, oracle, execution flows |
| [docs/04-tradeoffs.md](./docs/04-tradeoffs.md) | Risks and what the code does about them |
| [docs/05-implementation.md](./docs/05-implementation.md) | Structs, interfaces, precision |
| [docs/06-improvements.md](./docs/06-improvements.md) | Ideas that are not implemented |
| [docs/07-vault-ssl.md](./docs/07-vault-ssl.md) | Vault and solvency layers |
| [docs/08-security.md](./docs/08-security.md) | Threat model, access control, invariants |
| [docs/ROADMAP.md](./docs/ROADMAP.md) | Build log by phase |
| [docs/tests/README.md](./docs/tests/README.md) | Test suite |

## Project structure

```
src/
  Vault.sol                 ERC-4626 LP vault at a conservative NAV, PnL snapshot, withdrawal requests
  TradingStorage.sol        Trades, pairs, open interest, open PnL aggregates, funding index, trader collateral
  TradingEngine.sol         Open, close, liquidate, executeLimit, spread, fees, funding
  PythChainlinkOracle.sol   Pyth price with Chainlink deviation check
  SpreadManager.sol         Spread from OI and keeper-set volatility
  AssistantFund.sol         USDC reserve (solvency layer 2)
  SolvencyManager.sol       checkAndAct orchestration
  BondDepository.sol        Discounted $SYNTH sale with vesting (solvency layer 3)
  SynthToken.sol            $SYNTH ERC-20 with a single minter
  interfaces/               IOracle, ISolvency, ISynthToken, AggregatorV3Interface
  libraries/FundingLib.sol  Funding index math
  libraries/OpenPnlLib.sol  Open PnL of a pair from the per-side aggregates
test/
  unit/  regression/  integration/  invariant/  fork/  gas/  mocks/
script/
  Deploy.s.sol              Deploys and wires the contracts
  analysis/                 Pyth update age measurement (read-only RPC)
snapshots/                  Gas benchmark results
```

## License

MIT, see [LICENSE](./LICENSE).

## Author

[@GushALKDev](https://github.com/GushALKDev), Gustavo Martín ([LinkedIn](https://www.linkedin.com/in/gustavomaral/)).

## Acknowledgments

- [Foundry](https://getfoundry.sh/) and [Solady](https://github.com/Vectorized/solady), used to build the contracts.
- [Pyth](https://pyth.network/) and [Chainlink](https://chain.link/), the oracle sources.
- [gTrade by Gains Network](https://gains.trade/), the architectural reference: a single vault as the
  counterparty, oracle-priced execution, and trading logic separated from trade storage.
