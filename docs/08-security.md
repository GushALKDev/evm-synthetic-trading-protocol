# Guide 8: Security

**Prerequisites:** [Guide 7: Vault and Solvency](./07-vault-ssl.md)
**Next:** [Documentation Index](./README.md)

**Status:** Proof of concept. Not audited and not deployed. There is no bug bounty.

Earlier versions of this guide described roles, a timelock, circuit breakers, an emergency withdrawal and
a bug bounty. None of those exist in the code; this version describes what does.

---

## Table of Contents

1. [Threat Model](#1-threat-model)
2. [Access Control as Implemented](#2-access-control-as-implemented)
3. [Invariants in the Test Suite](#3-invariants-in-the-test-suite)
4. [Attack Vectors](#4-attack-vectors)
5. [Pause and Emergency Handling](#5-pause-and-emergency-handling)
6. [Before an Audit](#6-before-an-audit)

---

## 1. Threat Model

### Actors

| Actor | Trust | What they can do |
|:---|:---|:---|
| Trader | Untrusted | Open and close own trades, choose the Pyth update within `maxPriceAge` (5 s by default), set TP/SL |
| LP | Untrusted | Deposit, request and execute withdrawals, time entries and exits |
| Liquidator / executor bot | Untrusted | Call `liquidate` and `executeLimit` on any trade, choose the Pyth update |
| Volatility keeper | Trusted for spread input | Set per-pair volatility within the relative change bound |
| Owner (one per contract) | Fully trusted | See section 2; can redirect all funds |
| Pyth publishers, Wormhole, Chainlink | Trusted for prices | Prices that pass the oracle checks are used as is |
| L2 sequencer, Chainlink uptime feed | Trusted for liveness | While the feed reports the sequencer down, and for 1 hour after, no price is accepted |
| Bonder | Untrusted | Buy discounted $SYNTH during a round |

### Assets

| Asset | Location | Protection in code |
|:---|:---|:---|
| LP USDC | `Vault.sol` | `sendPayout` only by `tradingEngine`; withdrawals through requests |
| Trader collateral | `TradingStorage.sol` | `sendCollateral` only by `tradingEngine` |
| Reserve USDC | `AssistantFund.sol` | `injectFunds` only by `solvencyManager`; `skim` only to the vault |
| Trade and pair data | `TradingStorage.sol` | Writes only by `tradingEngine` or the owner |
| Prices | `PythChainlinkOracle.sol` | Age limit, future timestamp, confidence, Chainlink deviation and heartbeat, sequencer uptime checks |
| $SYNTH supply | `SynthToken.sol` | `mint` only by `minter` |

---

## 2. Access Control as Implemented

Every contract inherits Solady `Ownable` (single owner, two-step handover available through Solady).
There are no roles, no multisig requirement and no timelock in code.

### Vault

| Function | Caller | Pause |
|:---|:---|:---|
| `deposit`, `mint` | Anyone | Blocked when paused |
| `requestWithdrawal` | Share holder (shares move into escrow) | Blocked when paused |
| `executeWithdrawal`, `cancelWithdrawal` | Requester | Not blocked |
| `withdraw`, `redeem` | Anyone | Always revert |
| `sendPayout` | `tradingEngine` | Not blocked |
| `setTradingEngine`, `pause`, `unpause` | Owner | |

### TradingEngine

| Function | Caller | Pause |
|:---|:---|:---|
| `openTrade` | Anyone | Blocked |
| `closeTrade`, `updateTp`, `updateSl` | Trade owner | Blocked |
| `executeLimit` | Anyone | Blocked |
| `liquidate` | Anyone | Not blocked |
| `setTreasury`, `setFundingFactor` (within 1e12 to 1e15), `pause`, `unpause` | Owner | |

### TradingStorage

All state-changing functions except the admin ones are `onlyTradingEngine`. Owner: `setTradingEngine`,
`addPair`, `updatePair`. No pause.

### Other contracts

| Contract | Restricted function | Caller |
|:---|:---|:---|
| `PythChainlinkOracle` | `setPairFeed`, `setMaxPriceAge` (1 to 30 s) | Owner |
| `SpreadManager` | `updateVolatility` | Keeper |
| `SpreadManager` | `setBaseSpreadBps`, `setImpactFactor`, `setVolFactor`, `setMaxSpreadBps`, `setMaxVolatilityChangeBps`, `setKeeper` | Owner |
| `AssistantFund` | `injectFunds` | SolvencyManager |
| `AssistantFund` | `setSolvencyManager`, `setTargetCap` | Owner |
| `SolvencyManager` | none (`checkAndAct` is public) | |
| `BondDepository` | `activateBonding`, `closeBonding` | SolvencyManager |
| `BondDepository` | `setSolvencyManager`, `setReferencePrice`, `setDiscountBps`, `setVestingPeriod` | Owner |
| `SynthToken` | `mint` | Minter |
| `SynthToken` | `setMinter` | Owner |

### What the owner can do

- Set `tradingEngine` on the vault and on storage to any address, which can then transfer all LP USDC and
  all trader collateral.
- Set the $SYNTH minter to any address, which can mint without limit.
- Set oracle feeds and the price age limit (up to 30 s), spread parameters and keeper, pair leverage (up to
  `MAX_LEVERAGE` = 100) and OI caps, the funding factor (within bounds; the per-hour ceiling is a
  constant), the treasury, the reserve cap, and bond price, discount and vesting.
- Pause trading (liquidations continue) and the vault.

---

## 3. Invariants in the Test Suite

Stateful invariants (`invariant_*` functions), run with Foundry's defaults (256 runs of 500 calls). Call
summaries are logged from `afterInvariant` hooks and are not counted as invariants. The full list, the
equations and the handler call distribution are in the [test suite documentation](./tests/README.md).

| Suite | Invariant | Property asserted |
|:---|:---|:---|
| Protocol | `invariant_VaultBalanceMatchesModelledFlows` | Vault USDC equals deposits minus withdrawals plus fee share, modelled trader losses minus profits, injections, skims and bond proceeds |
| Protocol | `invariant_AssistantFundBalanceMatchesModelledFlows` | Reserve USDC equals the treasury fee share minus injections and skims |
| Protocol | `invariant_FlowsMatchModel` | Every trader, keeper, LP, injection, skim and bond amount equals the model |
| Protocol | `invariant_FundingCreditsNeverExceedCharges` | Settled plus accrued funding of a pair is between 0 and one unit per position |
| Protocol | `invariant_VaultFundingExposureBoundedByBadDebt` | Vault's net funding result plus accrued funding is at least minus the tracked bad debt |
| Protocol | `invariant_StorageHoldsExactlyOpenCollateral` | TradingStorage USDC equals the open collateral |
| Protocol | `invariant_OpenInterestMatchesPositionsAndCap` | OI per side equals open positions; long + short `<= maxOI` |
| Protocol | `invariant_EscrowedSharesMatchRequests` | Shares held by the vault equal pending withdrawal requests |
| Protocol | `invariant_RescueNeverOvershootsTarget` | A rescue never lifts CR above 100% |
| Protocol | `invariant_SharePricePositive`, `invariant_SharesBackedByAssets` | Share price and assets positive while shares exist |
| Bonding | `invariant_EscrowCoversUnclaimedSynth`, `invariant_SupplyEqualsPromised`, `invariant_ClaimedNeverExceedsPromised` | Vesting escrow and supply |
| Bonding | `invariant_RaisedWithinCap` | Round raise within its cap, total within the sum of caps, vault USDC equals the raise |
| Bonding | `invariant_BondsNeverExceedDeficit` | Each bond takes `min(amount, cap, deficit)` and closes the round when it takes all of it |
| Solvency (integration) | `invariant_VaultBalanceMatchesModelledFlows`, `invariant_AssistantFundBalanceMatchesModelledFlows`, `invariant_FlowsMatchModel` | Same equations over the wired solvency contracts |
| Solvency (integration) | `invariant_RescueNeverOvershootsTarget` | A rescue never lifts CR above 100% (tolerance 0) |
| Solvency (integration) | `invariant_RescueAlwaysCallable`, `invariant_ReserveNeverExceedsCapAfterSkim`, `invariant_EscrowSolventUnderFullSystem`, `invariant_SynthSupplyOnlyFromBonding` | Rescue liveness, skim, escrow, supply |

Properties that are **not** checked by any invariant:

- Vault assets plus open collateral cover open trader PnL (the model tracks realised flows only).
- Total OI across pairs stays below a global limit (there is no global limit; the suite has one pair).

The protocol suite uses `MockOracle` and a fixed 5 BPS `MockSpreadManager`.

---

## 4. Attack Vectors

### 4.1 Reentrancy

`TradingEngine.openTrade`, `closeTrade`, `liquidate`, `executeLimit`, `updateTp`, `updateSl` and the
vault's deposit, mint, withdrawal-request, withdrawal-execution and payout functions are `nonReentrant`.
USDC transfers happen after the trade is deleted and OI is reduced, and the ETH refund to the caller is the
last interaction; `test/regression/ReentrancyRegression.t.sol` re-enters from that refund. The oracle is
an owner-configured external contract called before state changes.

### 4.2 Oracle manipulation and price choice

Pyth updates are verified on-chain and checked for age (`maxPriceAge`, 5 s by default), a publish time
after the block, confidence (2%) and deviation from Chainlink (3%). The caller still chooses which valid
update to submit, as long as it is newer than the one stored on-chain. See [Guide 4](./04-tradeoffs.md#1-latency-arbitrage). The oracle design note is in
[Guide 3](./03-architecture.md#3-oracle-design-note).

### 4.3 Latency arbitrage

Open with an older update, close with a newer one; no minimum holding time. The window is `maxPriceAge`
(5 s by default, 30 s before round 2). The round-trip cost with the deploy parameters is about 26 BPS of
notional.

### 4.4 LP timing

- Withdrawal requests escrow the shares and expire one epoch after they unlock, so an LP cannot keep a
  standing option to exit; staggering requests across addresses keeps at most a quarter of a position
  executable at any time.
- Deposits are immediate, so a new LP can enter just before a known trader loss or a reserve injection
  (current limitation).
- The share price ignores unrealised PnL, which makes the timing visible from public state (current
  limitation; planned for a later round).

### 4.5 Liquidation incentives

The liquidator reward is between 0.5% and 1% of the collateral, also past a 100% loss. `deleteTrade` removes
a trade from its user's list in constant time, so many open trades do not make a liquidation more
expensive (`test_Regression_DeleteTrade_CostIndependentOfOpenTrades`). There is no limit on trades per
user.

### 4.6 Funding

Funding is zero-sum between traders and capped at 0.01% of the heavier side's notional per hour; see
[Guide 2](./02-mathematics.md#6-funding). An account holding both sides nets its own funding to zero
(`test_Regression_Funding_CannotDrainVaultWithOffsettingPositions`). The remaining exposure is the funding
a payer cannot pay when it is liquidated late, which the vault carries; its formula and worst case are in
Guide 2.

### 4.7 Solvency layers

`checkAndAct` is permissionless; it recapitalises below 100% CR and closes an open bonding round at or
above it. A bond never raises more than the current deficit. Anyone depositing when the share price is
below 1.0 shares in any reserve injection or bond proceeds that follow. `referencePrice` is set by the
owner.

---

## 5. Pause and Emergency Handling

What exists:

- `TradingEngine.pause` blocks opening, closing, TP/SL execution and TP/SL updates. Liquidations continue.
- `Vault.pause` blocks deposits, mints and new withdrawal requests. Pending requests can still be executed.

What does not exist: automatic circuit breakers (price jump, volume, solvency), an emergency withdrawal
path for LPs, or an on-chain emergency mode. Any response to an incident relies on the owner.

---

## 6. Before an Audit

Figures measured at commit `aaceb08` ([test suite documentation](./tests/README.md)).

| Item | State |
|:---|:---|
| Code freeze | No |
| Coverage on `src/` (`forge coverage --report summary`) | Lines 100% on every contract except `Vault` (98.18%, the two `return 0` bodies of `maxWithdraw`/`maxRedeem`); branches below 100% on `BondDepository` (75.00%) and `TradingEngine` (95.65%) |
| Fuzz tests on math | 39 `testFuzz_*` functions |
| Invariants | 24 invariant functions over three suites; vault, reserve and funding accounting modelled; unrealised PnL not modelled |
| Regression tests for the round 1 findings | 33 tests in `test/regression/` |
| Slither | 0 High, 8 Medium, 20 Low, 128 Informational; not triaged |
| Aderyn | 3 High (13 instances), 5 Low (47 instances); not triaged |
| Contract size | `TradingEngine` 24,563 bytes, 13 under the limit |
| Architecture documentation | This set of guides |
| External audit | Not done |

---|:---|
| Code freeze | No |
| Line coverage on `src/` | 100% (`forge coverage --report summary`); branch coverage below 100% for `BondDepository` and `TradingEngine` |
| Fuzz tests on math | 35 `testFuzz_*` functions |
| Invariants | 14 asserting invariant functions; the gaps in section 3 remain |
| Slither | 0 High, 6 Medium, 14 Low, 121 Informational; not triaged |
| Aderyn | 2 High, 7 Low; not triaged |
| Architecture documentation | This set of guides |
| External audit | Not done |

---

**See also:**
- [Guide 4: Trade-offs and Risks](./04-tradeoffs.md)
- [Guide 5: Implementation](./05-implementation.md)
- [Test suite](./tests/README.md)
