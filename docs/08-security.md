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
| LP | Untrusted | Deposit (fresh snapshot, coverage >= 100%), request and execute withdrawals (fresh snapshot), time entries and exits, choose whether to act on the stored snapshot or refresh first |
| Anyone | Untrusted | Refresh the PnL snapshot with a Pyth update of their choice, run `checkAndAct` |
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
| `deposit`, `mint`, `refreshAndDeposit`, `refreshAndMint` | Anyone | Blocked when paused |
| `requestWithdrawal` | Share holder (shares move into escrow) | Blocked when paused |
| `executeWithdrawal`, `refreshAndExecuteWithdrawal`, `cancelWithdrawal` | Requester | Not blocked |
| `refreshPnlSnapshot` | Anyone | Not blocked |
| `withdraw`, `redeem` | Anyone | Always revert |
| `sendPayout` | `tradingEngine` | Not blocked |
| `setTradingEngine`, `setMaxPnlSnapshotAge` (1 to 3,600 s), `pause`, `unpause` | Owner | |

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
| `SolvencyManager` | none (`checkAndAct` and `refreshAndCheckAndAct` are public) | |
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
- Set the maximum PnL snapshot age between 1 s and the immutable ceiling of 3,600 s, which widens or narrows
  the window in which an LP can act on an older snapshot.
- Add pairs up to `MAX_PAIRS` (20), the bound on the snapshot loop.
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
| Protocol | `invariant_RescueNeverOvershootsTarget` | An injection never lifts the NAV ratio above 100%, a bond never lifts the realised ratio above 100% |
| Protocol | `invariant_SharePricePositive`, `invariant_SharesBackedByAssets` | Share price and assets positive while shares exist |
| Protocol | `invariant_TotalAssetsIsBalanceMinusSnapshotLiability` | `totalAssets` equals the balance minus the positive part of the latest snapshot, floored at 0 |
| Protocol | `invariant_OpenTotalsMatchPositions` | Per side, the open PnL aggregates equal the positions rebuilt one by one, exactly |
| Protocol | `invariant_SnapshotMatchesBruteForceAndIsConservative` | At every refresh the snapshot equals the brute-force valuation, and the brute-force liability (8x cap, floor at minus collateral) is at most `max(0, snapshot)` plus the excess loss |
| Protocol | `invariant_NoDepositBelowParOrStaleAction` | No deposit went through below 100% coverage, no deposit or withdrawal on a stale snapshot |
| Protocol | `invariant_BondingNeverStartsAboveCriticalRealisedRatio` | `checkAndAct` never opened a round with the realised ratio at or above 95% |
| Bonding | `invariant_EscrowCoversUnclaimedSynth`, `invariant_SupplyEqualsPromised`, `invariant_ClaimedNeverExceedsPromised` | Vesting escrow and supply |
| Bonding | `invariant_RaisedWithinCap` | Round raise within its cap, total within the sum of caps, vault USDC equals the raise |
| Bonding | `invariant_BondsNeverExceedDeficit` | Each bond takes `min(amount, cap, realised deficit)` and closes the round when it takes all of it |
| Solvency (integration) | `invariant_VaultBalanceMatchesModelledFlows`, `invariant_AssistantFundBalanceMatchesModelledFlows`, `invariant_FlowsMatchModel` | Same equations over the wired solvency contracts |
| Solvency (integration) | `invariant_RescueNeverOvershootsTarget` | A rescue never lifts CR above 100% (tolerance 0) |
| Solvency (integration) | `invariant_RescueAlwaysCallable`, `invariant_ReserveNeverExceedsCapAfterSkim`, `invariant_EscrowSolventUnderFullSystem`, `invariant_SynthSupplyOnlyFromBonding` | Rescue liveness, skim, escrow, supply |

Properties that are **not** checked by any invariant:

- The vault can pay every open position at its settlement value at once (the NAV subtracts the net
  profit; it does not check liquidity against the winners alone).
- Total OI across pairs stays below a global limit (there is no global limit; the suite has one pair, so
  the aggregate and snapshot invariants run on one pair; several pairs are covered by unit tests and by
  the gas benchmark at `MAX_PAIRS`).

The protocol suite uses `MockOracle` and a fixed 5 BPS `MockSpreadManager`.

---

## 4. Attack Vectors

### 4.1 Reentrancy

`TradingEngine.openTrade`, `closeTrade`, `liquidate`, `executeLimit`, `updateTp`, `updateSl` and the
vault's deposit, mint, withdrawal-request, withdrawal-execution, snapshot refresh, refresh-and-act and
payout functions are `nonReentrant`. The vault's refresh calls the oracle before it writes the snapshot and
refunds the ETH surplus last; `SolvencyManager.refreshAndCheckAndAct` has no guard of its own, calls the
vault (guarded) first and refunds last.
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
- Deposits and withdrawals are priced at the conservative NAV, which subtracts unrealised trader profit;
  they need a snapshot at most `maxPnlSnapshotAge` old (60 s by default) with no open or close since.
- Deposits revert below 100% coverage, so a new LP cannot enter ahead of a reserve injection or bond
  proceeds.
- Remaining: deposits are immediate and the NAV does not add net trader losses, so a new LP can enter while
  traders are net losing and share in those losses when they are realised; and within the snapshot age
  window an LP can choose between the stored snapshot and a refresh with a Pyth update of their choice,
  worth the price move since the snapshot times the open quantity.

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

`checkAndAct` is permissionless. It injects the reserve below a 100% NAV ratio, only with a fresh snapshot,
and opens a bonding round only below a 95% realised ratio, so an unrealised trader profit that reverses
cannot trigger a discounted $SYNTH sale (`test_Regression_Solvency_UnrealisedTraderProfitInjectsButDoesNotBond`).
A bond never raises more than the current realised deficit, and an open round closes once the realised ratio
is back at 100%. Deposits revert while the NAV ratio is below 100%, which can last indefinitely (see
[Guide 7](./07-vault-ssl.md#known-biases-and-the-deposit-freeze)). `referencePrice` is set by the owner.

---

## 5. Pause and Emergency Handling

What exists:

- `TradingEngine.pause` blocks opening, closing, TP/SL execution and TP/SL updates. Liquidations continue.
- `Vault.pause` blocks deposits, mints (including the refresh-and-act variants) and new withdrawal requests.
  Pending requests can still be executed and the PnL snapshot can still be refreshed.

What does not exist: automatic circuit breakers (price jump, volume, solvency), an emergency withdrawal
path for LPs, or an on-chain emergency mode. Any response to an incident relies on the owner.

---

## 6. Before an Audit

Figures measured at commit `2e390d7` ([test suite documentation](./tests/README.md)).

| Item | State |
|:---|:---|
| Code freeze | No |
| Coverage on `src/` (`FOUNDRY_PROFILE=coverage forge coverage --report summary`) | Lines 100% on every contract except `Vault` (98.99%, the two `return 0` bodies of `maxWithdraw`/`maxRedeem`); branches below 100% on `BondDepository` (75.00%) and `TradingEngine` (95.65%) |
| Fuzz tests on math | 45 `testFuzz_*` functions |
| Invariants | 29 invariant functions over three suites; vault, reserve and funding accounting modelled; open PnL aggregates and the snapshot checked against a brute-force valuation |
| Regression tests | 50 tests in `test/regression/` (round 1 findings and round 2b) |
| Slither | 4 High, 16 Medium, 43 Low, 134 Informational; not triaged (the four High results are one line, see the test suite documentation) |
| Aderyn | 3 High (14 instances), 6 Low (53 instances); not triaged |
| Contract size | `TradingEngine` 17,311 bytes with the optimizer (200 runs), 7,265 under the limit (`forge build --sizes`) |
| Architecture documentation | This set of guides |
| External audit | Not done |

---

**See also:**
- [Guide 4: Trade-offs and Risks](./04-tradeoffs.md)
- [Guide 5: Implementation](./05-implementation.md)
- [Test suite](./tests/README.md)
