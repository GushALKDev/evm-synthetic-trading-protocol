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
5. [Pause Flags](#5-pause-flags)
6. [Incident Playbook](#6-incident-playbook)
7. [Before an Audit](#7-before-an-audit)
8. [Trust Assumptions and Known Limitations](#8-trust-assumptions-and-known-limitations)

---

## 1. Threat Model

### Actors

| Actor | Trust | What they can do |
|:---|:---|:---|
| Trader | Untrusted | Open and close own trades, choose the Pyth update within `maxPriceAge` (5 s by default), set TP/SL |
| LP | Untrusted | Deposit (fresh snapshot, no bonding round open or due; the pending AssistantFund injection lands first), request and execute withdrawals (fresh snapshot), time entries and exits, choose whether to act on the stored snapshot or refresh first |
| Anyone | Untrusted | Refresh the PnL snapshot with a Pyth update of their choice, run `checkAndAct` |
| Liquidator / executor bot | Untrusted | Call `liquidate` and `executeLimit` on any trade, choose the Pyth update |
| Volatility keeper | Trusted for spread input | Set per-pair volatility within the relative change bound |
| Owner (one per contract) | Fully trusted | See section 2; can redirect all funds |
| Pyth publishers, Wormhole, Chainlink | Trusted for prices | Prices that pass the oracle checks are used as is |
| L2 sequencer, Chainlink uptime feed | Trusted for liveness | While the feed reports the sequencer down no price is accepted; for 1 hour after it comes back, no position can be opened |
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
| `deposit`, `mint`, `refreshAndDeposit`, `refreshAndMint` | Anyone | `PAUSE_DEPOSIT` |
| `requestWithdrawal` | Share holder (shares move into escrow) | `PAUSE_WITHDRAW` |
| `executeWithdrawal`, `refreshAndExecuteWithdrawal` | Requester | `PAUSE_WITHDRAW` |
| `cancelWithdrawal` | Requester | Not blocked |
| `refreshPnlSnapshot` | Anyone | Not blocked |
| `withdraw`, `redeem` | Anyone | Always revert |
| `sendPayout` | `tradingEngine` | Not blocked |
| `setTradingEngine`, `setSolvencyManager`, `setMaxPnlSnapshotAge` (1 to 3,600 s), `setPauseFlags` | Owner | |

### TradingEngine

| Function | Caller | Pause |
|:---|:---|:---|
| `openTrade` | Anyone | `PAUSE_OPEN` |
| `closeTrade` | Trade owner | `PAUSE_SETTLE` |
| `executeLimit`, `liquidate` | Anyone | `PAUSE_SETTLE` |
| `updateTp`, `updateSl` | Trade owner | Not blocked |
| `setTreasury`, `setFundingFactor` (within 1e12 to 1e15), `setPauseFlags` | Owner | |

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
- Set `solvencyManager` on the vault to any address; every deposit path calls it before minting. Until it is
  set (`DeployLib.wire` sets it), deposits skip the rescue step: they neither run a pending injection first
  nor stop for bonding.
- Set the $SYNTH minter to any address, which can mint without limit.
- Set oracle feeds and the price age limit (up to 30 s), spread parameters and keeper, pair leverage (up to
  `MAX_LEVERAGE` = 100) and OI caps, the funding factor (within bounds; the per-hour ceiling is a
  constant), the treasury, the reserve cap, and the bond reference price, discount (up to 10%) and vesting period (up
  to 7 days).
- Set the maximum PnL snapshot age between 1 s and the immutable ceiling of 3,600 s, which widens or narrows
  the window in which an LP can act on an older snapshot.
- Add pairs up to `MAX_PAIRS` (20), the bound on the snapshot loop.
- Set and clear the pause flags of the engine and the vault (section 5), which can also keep users from
  closing, liquidating or exiting for as long as the owner wants.

---

## 3. Invariants in the Test Suite

Stateful invariants (`invariant_*` functions), run with Foundry's defaults (256 runs of 500 calls). There
are 32 distinct properties (19 protocol, 5 bonding, 8 solvency integration; `grep -c "function invariant_"`
on each suite file) and 51 campaigns per full run: `ProtocolKeeperLatencyInvariantTest` inherits the 19
protocol properties and runs them in a second configuration, which adds campaigns, not properties
(`forge test --list --json 2>/dev/null | jq '[.[][][] | select(startswith("invariant_"))] | length'`). Call
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
| Protocol | `invariant_DepositsFollowRescueRule` | No deposit on a stale snapshot or while a bonding round is open, each deposit settles the pending injection first and mints shares worth at most the assets paid in, no withdrawal on a stale snapshot |
| Protocol | `invariant_BondingNeverStartsAboveCriticalRealisedRatio` | `checkAndAct` never opened a round with the realised ratio at or above 95% |
| Protocol | `invariant_NoSettlementWhileSettlePaused` | No close, TP/SL execution or liquidation succeeds while `PAUSE_SETTLE` is set |
| Protocol | `invariant_WithdrawPauseDoesNotExpireRequests` | No withdrawal request expires because of time spent under `PAUSE_WITHDRAW` |
| Protocol | `invariant_NoFundingAccruesWhileSettlePaused` | No funding accrues for time spent under `PAUSE_SETTLE` |
| Bonding | `invariant_EscrowCoversUnclaimedSynth`, `invariant_SupplyEqualsPromised`, `invariant_ClaimedNeverExceedsPromised` | Vesting escrow and supply |
| Bonding | `invariant_RaisedWithinCap` | Round raise within its cap, total within the sum of caps, vault USDC equals the raise |
| Bonding | `invariant_BondsNeverExceedDeficit` | Each bond takes `min(amount, cap, realised deficit)` and closes the round when it takes all of it |
| Solvency (integration) | `invariant_VaultBalanceMatchesModelledFlows`, `invariant_AssistantFundBalanceMatchesModelledFlows`, `invariant_FlowsMatchModel` | Same equations over the wired solvency contracts |
| Solvency (integration) | `invariant_RescueNeverOvershootsTarget` | A rescue never lifts CR above 100% (tolerance 0) |
| Solvency (integration) | `invariant_RescueAlwaysCallable`, `invariant_ReserveNeverExceedsCapAfterSkim`, `invariant_EscrowSolventUnderFullSystem`, `invariant_SynthSupplyOnlyFromBonding` | Rescue liveness, skim, escrow, supply |

Properties that are **not** checked by any invariant:

- The vault can pay every open position at its settlement value at once (the NAV subtracts the net
  profit; it does not check liquidity against the winners alone).
- Total OI across pairs stays below a global limit (there is no global limit).

The protocol suite runs three pairs with `MockOracle` (confidence band 0.5% of the price at start, then 0%
to 2% as the handler moves prices) and a fixed 5 BPS `MockSpreadManager`. `ProtocolKeeperLatencyInvariantTest` runs the same invariants
with a keeper that liquidates one day after a position becomes liquidatable, so the snapshot's
conservativeness bound is checked with positions past 100% loss.

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
- A deposit runs the pending reserve injection before it mints and reverts while a bonding round is open or
  due, so a new LP cannot take part of a rescue pending when it deposits.
- Remaining: deposits are immediate and the NAV does not add net trader losses, so a new LP can enter while
  traders are net losing and share in those losses when they are realised; and within the snapshot age
  window an LP can choose between the stored snapshot and a refresh with a Pyth update of their choice,
  worth the price move since the snapshot times the open quantity.

### 4.5 Liquidation incentives

The liquidator reward is between 0.5% and 1% of the collateral, also past a 100% loss
(`test_MinCollateralLiquidatedPastFullLossPaysRewardFloor` pays the floor on a 10 USDC position). `deleteTrade` removes
a trade from its user's list in constant time, so many open trades do not make a liquidation more
expensive (`test_Regression_DeleteTrade_CostIndependentOfOpenTrades`). There is no limit on trades per
user.

### 4.6 Funding

Funding is zero-sum between traders and capped at 0.01% of the heavier side's notional per hour; see
[Guide 2](./02-mathematics.md#6-funding). A small light side receives a high per-unit rate, bounded in total
by what the heavy side pays ([thin-side funding](./02-mathematics.md#thin-side-funding)). An account holding both sides nets its own funding to zero
(`test_Regression_Funding_CannotDrainVaultWithOffsettingPositions`). The remaining exposure is the funding
a payer cannot pay when it is liquidated late, which the vault carries; its formula and worst case are in
Guide 2.

### 4.7 Solvency layers

`checkAndAct` is permissionless. It injects the reserve below a 100% NAV ratio, only with a fresh snapshot,
and opens a bonding round only below a 95% realised ratio, so an unrealised trader profit that reverses
cannot trigger a discounted $SYNTH sale (`test_Regression_Solvency_UnrealisedTraderProfitInjectsButDoesNotBond`).
A bond never raises more than the current realised deficit, and an open round closes once the realised ratio
is back at 100%. Deposits run the pending injection first and revert while a bonding round is open or due,
which lasts until the round fills or the realised ratio recovers (see
[Guide 7](./07-vault-ssl.md#known-biases-and-the-deposit-freeze)). `referencePrice` is set by the owner.

---

## 5. Pause Flags

Each of the two pausable contracts has independent flags, set and cleared together by the owner with
`setPauseFlags(uint8)`, which emits `PauseFlagsUpdated(flags)` and rejects unknown bits. A blocked call
reverts with `EnforcedPause(flag)`. From the `whenNotPaused(flag)` modifiers in the code:

| Contract | Flag | Blocks | Not blocked by any flag |
|:---|:---|:---|:---|
| `TradingEngine` | `PAUSE_OPEN` (1) | `openTrade` | `updateTp`, `updateSl` (they still go through the oracle checks), owner setters |
| `TradingEngine` | `PAUSE_SETTLE` (2) | `closeTrade`, `executeLimit`, `liquidate`, always together | |
| `Vault` | `PAUSE_DEPOSIT` (1) | `deposit`, `mint`, `refreshAndDeposit`, `refreshAndMint`; `maxDeposit` and `maxMint` return 0 | `cancelWithdrawal`, `refreshPnlSnapshot`, `sendPayout`, sUSDC transfers, owner setters |
| `Vault` | `PAUSE_WITHDRAW` (2) | `requestWithdrawal`, `executeWithdrawal`, `refreshAndExecuteWithdrawal`; `canExecuteWithdrawal` returns false | |

`SolvencyManager` (`checkAndAct`, `refreshAndCheckAndAct`), `AssistantFund` (`skim`), `BondDepository`
(`bond`, `claim`), `SpreadManager`, `SynthToken`, `TradingStorage` and the oracle have no flag.

**Settlement is paused as a whole.** `liquidate` is blocked together with `closeTrade`, so no position is
liquidated while its owner cannot close it (`test_Regression_Pause_SettleBlocksLiquidation`).

**Funding under `PAUSE_SETTLE`.** No funding accrues while `PAUSE_SETTLE` is set. The accrual uses a factor
of 0 while the flag is set; setting it first accrues every pair up to that moment, and clearing it moves each
pair's timestamp to that moment without accruing, so the paused interval is never charged
(`TradingEngine.setPauseFlags`, `_activeFundingFactor`). An `openTrade` or a `setFundingFactor` during the
pause accrues nothing either. Tests: `test_Regression_Pause_SettleFreezesFunding`,
`test_SetPauseFlags_SettleAccruesThenFreezesFunding`, `test_OpenTrade_WhileSettlePausedDoesNotAccrue`,
`test_SetFundingFactor_WhileSettlePausedDoesNotAccrue`, invariant `NoFundingAccruesWhileSettlePaused`.

**Withdrawal expiry under `PAUSE_WITHDRAW`.** The expiry clock of pending requests stops while the flag is
set. Each request stores the seconds the vault had spent under `PAUSE_WITHDRAW` when it was made; its expiry
epoch is `requestEpoch + 3 + 1 + ceil(paused seconds since the request / 1 day)`. The granularity is one epoch
(one day), rounded up, so after the pause a request has at least the time to expiry it had when the pause
started, and up to one day more. The unlock epoch does not move: the three-epoch delay keeps running during
a pause. `getWithdrawalExpiryEpoch(user)` returns the extended expiry. Tests:
`test_Regression_Pause_WithdrawPauseDoesNotExpireRequest`, `test_WithdrawPause_ExtendsExpiryByWholeEpochs`,
invariant `WithdrawPauseDoesNotExpireRequests`.

**Engine and vault flags are independent.** Vault flags do not stop settlements: with `PAUSE_WITHDRAW` set,
winning traders are still paid from the vault through `sendPayout` unless the engine's `PAUSE_SETTLE` is also
set. Engine flags do not stop LP flows: with `PAUSE_SETTLE` set, prices keep moving, positions past 100% loss
cannot be liquidated, and the NAV's optimistic bias (the excess loss of those positions, which offsets winners
on their side; [Guide 2, section 8.2](./02-mathematics.md#82-known-biases-of-the-nav)) can grow while LPs can
still exit at that NAV unless `PAUSE_WITHDRAW` is also set. The playbook below says which combination each
incident needs.

What does not exist: automatic circuit breakers (price jump, volume, solvency), an emergency withdrawal
path for LPs, a switch that disables one pair's oracle feed, or an on-chain emergency mode. Any response to
an incident relies on the owner.

---

## 6. Incident Playbook

Derived from the code as it is. "Other levers" are existing owner functions; none of them is a flag.

**Oracle returns a wrong price that passes every check.**
- Set: engine `PAUSE_OPEN | PAUSE_SETTLE`; vault `PAUSE_DEPOSIT | PAUSE_WITHDRAW`.
- Why: every trade action prices at the oracle, and the PnL snapshot does too, so the NAV used by deposits
  and withdrawal executions is wrong. When the wrong price makes traders look like losers, the snapshot
  liability drops to 0 and the NAV rises to the full balance, so an LP exiting then takes value from the LPs
  who stay. This case closes LP exits as well as the NAV bug below.
- Other levers: `setPairFeed` can point the pair to other Pyth and Chainlink feeds (there is no switch that
  disables a feed); `updatePair(..., isActive = false)` blocks opens on that pair only.
  `AssistantFund.setSolvencyManager` to an address that is not the SolvencyManager stops injections sized on
  the wrong NAV; `checkAndAct` then reverts whenever it would inject.
- Stays open: `updateTp`, `updateSl`, `cancelWithdrawal`, `refreshPnlSnapshot`, `checkAndAct`, `bond`,
  `claim`, `skim`. Bonding uses the realised ratio (USDC balance per share), which does not depend on prices.
- Residual: positions are frozen and cannot be liquidated; when the flags are cleared, positions that passed
  100% loss meanwhile settle with bad debt for the vault. A snapshot refreshed at the wrong price stays until
  the next refresh.

**Oracle down, or Pyth and Chainlink disagreeing by more than 3%, or the sequencer down.**
- Set: nothing is required. `getPrice` reverts, so `openTrade`, `closeTrade`, `executeLimit`, `liquidate`,
  updates with a new TP or SL, and every snapshot refresh revert. With a trade open, deposits and withdrawal
  executions revert with `StalePnlSnapshot` once the snapshot is older than `maxPnlSnapshotAge` (60 s by
  default), and `checkAndAct` skips the injection on a stale snapshot.
- Optional: `PAUSE_SETTLE` for a long outage, to stop funding from accruing while nobody can close.
  `setPauseFlags` does not read prices, so it works during the outage.
- Stays open: `requestWithdrawal`, `cancelWithdrawal`, bonding and claims.
- Residual: no liquidations during the outage; positions can pass 100% loss and settle with bad debt when
  prices return, and the first liquidations then race each other.

**Bug in trade execution or PnL math (engine settlement).**
- Set: engine `PAUSE_OPEN | PAUSE_SETTLE`.
- Why: stops every payout computed by the engine (`sendPayout` is only called by settlements) and every new
  position.
- Stays open: LP deposits and withdrawals. The vault NAV comes from `OpenPnlLib` and the USDC balance, not
  from the engine's settlement code, and losses already paid out are in the balance.
- Residual: the NAV bias described in section 5 grows while settlement is paused; if prices move far, add
  `PAUSE_WITHDRAW`. The engine is not upgradeable: a fix means a new `TradingEngine` wired with
  `Vault.setTradingEngine` and `TradingStorage.setTradingEngine`; open positions and funding state stay in
  `TradingStorage`.

**Bug in vault accounting or the NAV.**
- Set: vault `PAUSE_DEPOSIT | PAUSE_WITHDRAW`.
- Why: deposits and withdrawal executions are the only calls that move value at the NAV. Confirmed as a case
  that closes LP exits; the wrong-price case above is another.
- Other levers: `AssistantFund.setSolvencyManager` away from the SolvencyManager if the injection size (from
  the NAV) is wrong; `checkAndAct` then reverts whenever it would inject. `Vault.setSolvencyManager` rejects the
  zero address, so the deposit-path wiring cannot be removed, only paused with `PAUSE_DEPOSIT`.
- Stays open: settlements (`sendPayout` checks the USDC balance, not the NAV), `cancelWithdrawal`, sUSDC
  transfers. Add `PAUSE_SETTLE` if the bug is in `sendPayout` or the balance check.
- Residual: LPs cannot exit until the flags are cleared; pending requests do not expire meanwhile.

**Bug in bonding or the AssistantFund.**
- Set: no flag covers it. Levers: `BondDepository.setSolvencyManager(owner)` then `closeBonding()` closes the
  round, after which `bond` reverts with `NoActiveRound`; `SynthToken.setMinter` to another address makes
  every `bond` revert on the mint. `AssistantFund.setSolvencyManager` away from the SolvencyManager stops
  injections, and `setTargetCap(type(uint256).max)` stops `skim`. Add vault `PAUSE_DEPOSIT`: while an
  injection is pending, a deposit runs `checkAndAct`, which then reverts anyway.
- Stays open: `claim`, by decision. No lever stops claims: a bug in the vesting math can move escrowed $SYNTH
  between bonders (the escrow holds only $SYNTH; no USDC is at risk from `claim`). A pause on `claim` would
  itself trap bonders' vested $SYNTH, so none was added.
- Residual: with the depository or the fund redirected, every `checkAndAct` that would open or close a round,
  or inject, reverts until the wiring is restored.

**Funding bug.**
- Set: engine `PAUSE_SETTLE`, which also stops funding from accruing; `PAUSE_OPEN` if new positions should
  not take on the bug.
- Why: funding is paid and charged only when a position settles, and it moves the liquidation threshold.
  `setFundingFactor` can only lower the factor to 1e12, not to 0. The vault NAV does not include funding.
- Stays open: LP flows, `updateTp`, `updateSl`.
- Residual: no settlement while the flag is set, and the NAV bias of section 5 grows. The fix needs a new
  engine (see the execution bug above); the funding indexes stay in `TradingStorage`.

**Owner key compromise.**
- No flag stops it. The flags are set by the same owner. A compromised owner can point `tradingEngine` on
  the vault and on storage to its own contract and take all LP USDC and all trader collateral, set the $SYNTH
  minter, re-point oracle feeds, and set flags to keep users from closing or exiting. There is no timelock,
  multisig requirement or second role in code (section 2).

---

## 7. Before an Audit

Figures measured at commit `47d848f`; the commands and the full output are in the
[test suite documentation](./tests/README.md).

| Item | State |
|:---|:---|
| Code freeze | No |
| Coverage on `src/` (`FORK_RPC_URL= FOUNDRY_PROFILE=coverage forge coverage --report summary`) | 100% of lines, statements, branches and functions on every contract; the table is in the [coverage section](./tests/README.md#coverage) |
| Fuzz tests | 54 `testFuzz_*` functions, 256 runs each |
| Invariants | 32 distinct properties (19 protocol, 5 bonding, 8 solvency integration) run as 51 campaigns, since the protocol properties also run with a one-day keeper latency; checks include the pause flags; vault, reserve and funding accounting modelled; open PnL aggregates and the snapshot checked against a brute-force valuation on three pairs with a confidence band |
| Regression tests | 70 tests in `test/regression/` (round 1 findings, rounds 2b, 3 and 3b) |
| Slither 0.11.6 | 199 results (4 High, 15 Medium, 46 Low, 134 Informational): 14 false positives, 185 accepted by design; 2 fixed in round 3. [Triage](./tests/README.md#triage) |
| Aderyn 0.6.8 | 3 High issues (11 instances) and 8 Low issues (53 instances): 3 false-positive instances, 61 accepted by design; 4 fixed in round 3. [Triage](./tests/README.md#triage) |
| Contract size | `TradingEngine` 17,701 bytes with the optimizer (200 runs), 6,875 under the limit (`forge build --sizes`) |
| Architecture documentation | This set of guides |
| External audit | Not done |

---

## 8. Trust Assumptions and Known Limitations

What the design accepts rather than defends. The owner's powers are listed in [section 2](#what-the-owner-can-do).

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
  its collateral per hour ([Guide 2](./02-mathematics.md#residual-funding-a-payer-cannot-pay)).
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
  ([Guide 2, section 8.2](./02-mathematics.md#82-known-biases-of-the-nav)).
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
  ([Guide 7](./07-vault-ssl.md#known-biases-and-the-deposit-freeze)).
- **Pause flags.** `PAUSE_SETTLE` stops closes, TP/SL execution and liquidations together and freezes
  funding, but prices keep moving: positions can pass 100% loss while it is set and settle with bad debt when
  it is cleared, and the NAV's optimistic bias (the excess loss `E` above) grows meanwhile. Vault flags do not
  stop settlements, and engine flags do not stop LP flows, so the owner has to set both when an incident
  affects both sides. `PAUSE_WITHDRAW` extends pending requests' expiry in whole epochs, rounded up. No flag
  protects against the owner ([sections 5 and 6](#5-pause-flags)).
- **`claim` has no pause lever, by decision.** A bug in the vesting math could move escrowed $SYNTH between
  bonders; the depository's escrow holds only $SYNTH, so no USDC is at risk from `claim`. A pause on `claim`
  would itself trap bonders' vested $SYNTH ([section 6](#6-incident-playbook)).
- **Thin-side funding.** When one side of a pair is small, each unit on that side receives the heavier side's
  rate times `OI_heavy / OI_light` per hour; the total credited to the light side is at most what the heavy
  side pays ([Guide 2](./02-mathematics.md#thin-side-funding)).
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

**See also:**
- [Guide 4: Trade-offs and Risks](./04-tradeoffs.md)
- [Guide 5: Implementation](./05-implementation.md)
- [Test suite](./tests/README.md)
