# Test Suite

**Status:** Proof of concept. Not audited and not deployed.

All numbers below were measured on 2026-09-29 at commit `47d848f` (branch `fix/pause-flags`) after
`npm ci`, with forge 1.7.1 and solc 0.8.24. Mock-mode numbers are taken with `FORK_RPC_URL` empty. Later
commits change documentation and, in `ca89c02`, the `file:line` references of cast comments (same line count,
same runtime sizes from `forge build --sizes`).

| Group | Location | Tests | Command that counts them |
| :---- | :------- | ----: | :----------------------- |
| Unit | `test/unit/` | 659 | `forge test --match-path "test/unit/*" --summary` |
| Regression (review findings, rounds 2, 2b, 3 and 3b) | `test/regression/` | 70 | `forge test --match-path "test/regression/*" --summary` |
| Integration | `test/integration/Solvency.integration.t.sol` | 17 | `forge test --match-path "test/integration/*" --summary` |
| Invariant campaigns (integration) | `test/integration/Solvency.invariant.t.sol` | 8 | same as above |
| Invariant campaigns | `test/invariant/` | 43 | `forge test --match-path "test/invariant/*" --summary` |
| Fork | `test/fork/` | 21 | skipped without `FORK_RPC_URL` |
| **Total (correctness)** | | **818** | `forge test --list --json 2>/dev/null \| jq '[.[][][]] \| length'` |
| Gas benchmarks (not counted above) | `test/gas/` | 14 | `FOUNDRY_PROFILE=gas forge test --list --json 2>/dev/null \| jq '[.[][][]] \| length'` |

`FORK_RPC_URL= forge test` (mock mode): 797 passed, 0 failed, 21 skipped (the fork suite).

There are 54 functions named `testFuzz_*` (49 in `test/unit/`, 3 in `test/integration/`, 2 in
`test/regression/`). Stateful invariants are counted two ways:

- **Distinct properties: 32.** 19 in `Protocol.invariant.t.sol`, 5 in `Bonding.invariant.t.sol`, 8 in
  `Solvency.invariant.t.sol` (`grep -c "function invariant_" <file>`). `ProtocolKeeperLatency.invariant.t.sol`
  defines none: it inherits the 19 protocol properties and runs them with a one-day keeper latency.
- **Campaigns per full run: 51.** Forge runs one campaign per `invariant_*` function of each test contract, so
  the 19 protocol properties run twice (19 + 19 + 5 + 8).

```bash
forge test --list --json 2>/dev/null | jq '[.[][][] | select(startswith("testFuzz_"))] | length'   # 54
forge test --list --json 2>/dev/null | jq '[.[][][] | select(startswith("invariant_"))] | length'  # 51 campaigns
grep -c "function invariant_" test/invariant/*.invariant.t.sol test/integration/Solvency.invariant.t.sol  # 5, 19, 0, 8
```

`foundry.toml` has no `[fuzz]` or `[invariant]` section, so Foundry defaults apply: 256 runs per fuzz test,
and 256 runs of 500 calls per campaign (forge reports 128,000 calls per campaign). A full `forge test`
therefore runs 54 x 256 = 13,824 fuzz cases and 51 x 128,000 = 6,528,000 invariant calls. The default profile
skips `test/gas`; the `gas` profile runs only it.

```bash
forge test                                    # correctness suite (fork tests skip without FORK_RPC_URL)
forge test --match-path "test/regression/*"   # regression tests
forge lint src                                # 8 block-timestamp warnings, all intentional
forge test --match-path "test/invariant/*"    # invariants
FORK_RPC_URL=<arbitrum-one-archive-rpc> forge test --match-path "test/fork/*"
FOUNDRY_PROFILE=gas forge test                # gas benchmarks, written to snapshots/*.json
FORK_RPC_URL= FOUNDRY_PROFILE=coverage forge coverage --report summary
```

**Coverage profile.** The default profile builds with the optimizer (200 runs) and keeps the EIP-170
contract size limit, which `forge build --sizes` enforces in CI. `forge coverage` compiles without the
optimizer, where contracts are larger, so `foundry.toml` has a `coverage` profile that only raises
`code_size_limit`; run coverage with `FOUNDRY_PROFILE=coverage`. Do not pass `--no-match-path` on the command
line: it replaces the profile's `no_match_path` and runs the gas benchmarks, which rewrite
`snapshots/*.json`.

---

## Regression tests (rounds 2, 2b, 3 and 3b)

One file per finding, in [`test/regression/`](../../test/regression/). The tests named `test_Regression_*`
and `testFuzz_Regression_*` failed against the code before their fix (the failing output is in the round 2,
2b, 3 and 3b reports); the other tests in these files pass before and after. Most use only functions that
existed before the fix, so they compile against it; new functions are called with low-level calls and new
errors are matched by selector literal.

| File | Finding | Tests |
| :--- | :------ | ----: |
| `FundingRegression.t.sol` | Funding paid by the vault, unnormalised rate | 2 |
| `WithdrawalRegression.t.sol` | Withdrawal requests without expiry or escrow; `max*` functions | 5 |
| `OracleLatencyRegression.t.sol` | 30 s price window; future `publishTime` underflow | 3 |
| `SequencerRegression.t.sol` | No L2 sequencer uptime check (grace period narrowed to openings in round 3) | 6 |
| `LeverageRegression.t.sol` | No global leverage cap | 3 |
| `OpenGuardRegression.t.sol` | Opening guard ignored the close spread and the open fee | 3 |
| `LiquidationRewardRegression.t.sol` | Zero liquidator reward past 100% loss | 1 |
| `DeleteTradeRegression.t.sol` | Linear search in `deleteTrade` | 2 |
| `EthRefundRegression.t.sol` | Force-sent ETH paid to the next caller | 2 |
| `ReentrancyRegression.t.sol` | `updateTp`/`updateSl` without `nonReentrant`; re-entry through the ETH refund | 4 |
| `BondingRoundRegression.t.sol` | Bonding round not closed when CR recovers | 3 |
| `MaxPairsRegression.t.sol` | No bound on the number of pairs the PnL snapshot iterates (2b) | 1 |
| `OpenPnlNavRegression.t.sol` | Share price ignored unrealised trader PnL; stale snapshot; payout check against the NAV (2b) | 7 |
| `DepositCoverageRegression.t.sol` | Deposits below 100% coverage took part of the next injection (2b; rewritten to the round 3 rule) | 5 |
| `SolvencySplitRegression.t.sol` | Bonding on an unrealised move; bond clamp and round close on the realised ratio; injection on a stale snapshot (2b) | 4 |
| `SequencerGraceScopeRegression.t.sol` | The grace period after a sequencer outage blocked closes, liquidations, refreshes, withdrawals and `checkAndAct` (3) | 8 |
| `DepositRuleRegression.t.sol` | Deposits frozen below 100% coverage with no rescue left; injection settled before minting; refused while bonding is open or due (3) | 6 |
| `PauseFlagsRegression.t.sol` | One pause per contract: liquidations under the engine pause, withdrawals blocked with deposits, requests expired and funding accrued during a pause (3b) | 5 |

Round 3 also added unit tests that failed before their change: `test_DeleteTrade_ClearsTradeFundingIndex`
(`TradingStorage.t.sol`) and the three `*AboveUint128Reverts` tests of `TypecastBounds.t.sol`, and a fork test,
`test_Fork_TradingEngine_GracePeriodClosesButDoesNotOpen`.

---

## Invariant suites

Each invariant is checked after every call of a random sequence. Call summaries are logged from
`afterInvariant` hooks (forge prints the last run's logs with `-vv`), not from invariant functions.

### Protocol: [`Protocol.invariant.t.sol`](../../test/invariant/Protocol.invariant.t.sol) and [`ProtocolKeeperLatency.invariant.t.sol`](../../test/invariant/ProtocolKeeperLatency.invariant.t.sol)

Deploys the engine, storage, vault, `AssistantFund` (as treasury), `SolvencyManager` (wired as the vault's
deposit check), `BondDepository` and `SynthToken` with `MockOracle` and `MockSpreadManager(5)`, on three pairs
(BTC 50,000, ETH 3,000 and SOL 150 in the mock, each with a 0.5% confidence band at start); the vault starts
with 1,000,000 USDC. Two handlers:

- [`ProtocolHandler`](../../test/invariant/handlers/ProtocolHandler.sol): open on any pair (collateral 10 to
  5,000 USDC, leverage 1 to 100, optional TP/SL), close, liquidate, `executeLimit`, `updateTp`, `updateSl`,
  and `refreshSnapshot`. It models every settlement from the documented formulas, with liquidations priced at
  price + conf (longs) or price - conf (shorts) before the spread, and compares the trader and keeper payouts
  with the model. Target selection: `liquidate` picks a position the model sees as liquidatable (for at least
  the keeper latency), `executeLimit` one whose TP or SL is triggered at the oracle price; for both, one call in
  five (a seed divisible by `RANDOM_PICK_ONE_IN` = 5) picks uniformly among open positions instead, to
  exercise the revert paths (a random liquidation pick still inside its latency is skipped). `closeTrade`
  always picks uniformly among open positions. While the engine's `PAUSE_SETTLE` is set, each of the three
  still calls the engine on its target: the expected revert ends the call with `NotSettled`, and an
  unexpected success is recorded in `ghostSettledWhileSettlePaused` and returns without reverting (a revert
  would undo the record). The three also revert with `NotSettled` when there is no eligible target, and
  otherwise with the engine's own error (for example `InsufficientVaultBalance` on a winning close the vault
  cannot pay), so in the metrics tables below calls minus reverts is the number of settlements. `openTrade` is
  skipped under `PAUSE_OPEN`; `updateTp` and `updateSl` run under any flag. At
  each refresh it rebuilds the open totals position by position and checks the snapshot against them
  (exact), and checks the conservativeness bound with the excess loss `E` as a ghost variable.
- [`LiquidityHandler`](../../test/invariant/handlers/LiquidityHandler.sol): deposit, withdrawal request,
  execution and cancellation, epoch advance, warp (1 minute to 1 day), price moves of one pair up or down by
  up to 5% per call within 60% to 140% of its start with a new confidence band of 0% to 2% of the price,
  `togglePause` (sets or clears one of the four flags, engine `PAUSE_OPEN` or `PAUSE_SETTLE`, vault
  `PAUSE_DEPOSIT` or `PAUSE_WITHDRAW`; a set flag is always cleared, a clear one is set one call in four),
  `checkAndAct`, `bond`, `skim`. It keeps its own `PAUSE_WITHDRAW` clock in seconds and the funding indexes of
  every pair when `PAUSE_SETTLE` is set. Each flow is modelled before the call
  and compared with the measured amount, including the AssistantFund injection a deposit makes. `deposit`,
  `executeWithdrawal` and `checkAndAct` take a mode seed: act on the current snapshot (possibly stale),
  refresh first, or go through the refresh-and-act entry point. A deposit or execution rejected for a
  documented reason (`PAUSE_DEPOSIT`, stale snapshot, bonding open or due, nothing to execute, `PAUSE_WITHDRAW`) ends with
  `NotExecuted`, so calls minus reverts is the number that went through; a deposit whose outcome differs from
  `maxDeposit`, or an unexpected revert, counts as a mismatch.

`ProtocolKeeperLatencyInvariantTest` runs the same invariant properties in a second configuration, with a keeper latency of one day: the handler
liquidates a position only one day after it first sees it liquidatable, and every pair starts with a 1,000
USDC 100x long and short without TP or SL, so positions pass 100% loss before liquidation.

| Invariant | What it asserts |
| :-------- | :-------------- |
| `invariant_VaultBalanceMatchesModelledFlows` | vault USDC = 1,000,000 + deposits - withdrawals + vault fee share + modelled trader losses - modelled trader profits + injections (from `checkAndAct` and from deposits) + skims + bond proceeds |
| `invariant_AssistantFundBalanceMatchesModelledFlows` | reserve USDC = treasury fee share - injections - skims |
| `invariant_FlowsMatchModel` | no trader, keeper, withdrawal, injection, skim or bond amount differed from the model, and every deposit matched `maxDeposit` |
| `invariant_FundingCreditsNeverExceedCharges` | 0 <= sum over the pairs of settled `fundingOwed` + funding accrued by open positions <= number of positions counted |
| `invariant_VaultFundingExposureBoundedByBadDebt` | collected - credited + accrued + tracked bad debt >= 0 (the vault pays funding only up to the bad-debt residual) |
| `invariant_StorageHoldsExactlyOpenCollateral` | TradingStorage USDC = sum of open collateral |
| `invariant_OpenInterestMatchesPositionsAndCap` | on every pair, long and short OI equal the open positions of each side, and long + short <= `maxOI` |
| `invariant_EscrowedSharesMatchRequests` | shares held by the vault = shares of all pending withdrawal requests |
| `invariant_RescueNeverOvershootsTarget` | the NAV ratio after an injection that raised it, and the realised ratio after a bond that raised it, are <= 100% |
| `invariant_SharePricePositive` | `convertToAssets(1e18) > 0` while shares exist |
| `invariant_SharesBackedByAssets` | shares outstanding imply assets > 0 |
| `invariant_TotalAssetsIsBalanceMinusSnapshotLiability` | `totalAssets` = max(balance - max(0, snapshot), 0), and the balance while no trade is open |
| `invariant_OpenTotalsMatchPositions` | per pair and side, size, collateral and quantity aggregates = the sums over open positions, exactly; open trade count = open positions |
| `invariant_SnapshotMatchesBruteForceAndIsConservative` | at every refresh: snapshot = `toUsdcUp` of the sum over pairs of `pairPnl(price, conf, brute-force totals)` exactly, and L <= max(0, snapshot) + E, where L is the positive part of the sum of per-position PnL at the oracle price, capped at 8x collateral and floored at minus collateral, and E the excess loss of positions past 100% loss (tolerance 0) |
| `invariant_DepositsFollowRescueRule` | no deposit on a stale snapshot or while a bonding round is open after the check; each deposit injects exactly the injection pending before it; minted shares are worth at most the assets paid in; no withdrawal execution on a stale snapshot (replaces round 2b's `NoDepositBelowParOrStaleAction`) |
| `invariant_BondingNeverStartsAboveCriticalRealisedRatio` | no `checkAndAct` opened a bonding round with the realised ratio at or above 95% |
| `invariant_NoSettlementWhileSettlePaused` | no close, TP/SL execution or liquidation succeeded while `PAUSE_SETTLE` was set (the handler calls the engine anyway) |
| `invariant_WithdrawPauseDoesNotExpireRequests` | with `PAUSE_WITHDRAW` clear, every request inside its window by the handler's model (unlocked, before the unextended expiry plus the exact seconds paused since the request) can be executed (`canExecuteWithdrawal`) |
| `invariant_NoFundingAccruesWhileSettlePaused` | while `PAUSE_SETTLE` is set, every pair's funding indexes equal those right after it was set; clearing it left them unchanged; no pair's `fundingLastUpdated` is before the last time it was cleared |

Call distribution and revert rates for the `invariant_VaultBalanceMatchesModelledFlows` campaign of each suite
(256 runs x 500 calls), from
`FOUNDRY_INVARIANT_SHOW_METRICS=true forge test --match-contract "^ProtocolInvariantTest$" -vv` and the same
command with `"^ProtocolKeeperLatencyInvariantTest$"` (forge runs one campaign per invariant function; the
range over all 19 campaigns of each suite is given after the table):

| Handler | Action | Calls (default / latency) | Reverts (default / latency) | Went through (default / latency) | Revert rate (default / latency) |
| :------ | :----- | ----: | ------: | ------: | ----: |
| ProtocolHandler | openTrade | 7,098 / 7,300 | 0 / 0 | 7,098 / 7,300 | 0.0% / 0.0% |
| ProtocolHandler | closeTrade | 7,105 / 7,013 | 3,464 / 2,163 | 3,641 / 4,850 | 48.8% / 30.8% |
| ProtocolHandler | liquidate | 7,185 / 7,100 | 6,801 / 7,095 | 384 / 5 | 94.7% / 99.9% |
| ProtocolHandler | executeLimit | 6,990 / 7,006 | 6,784 / 6,564 | 206 / 442 | 97.1% / 93.7% |
| ProtocolHandler | refreshSnapshot | 7,145 / 7,082 | 0 / 0 | 7,145 / 7,082 | 0.0% / 0.0% |
| LiquidityHandler | deposit | 7,076 / 7,074 | 2,367 / 2,381 | 4,709 / 4,693 | 33.5% / 33.7% |
| LiquidityHandler | executeWithdrawal | 7,042 / 7,161 | 6,895 / 7,008 | 147 / 153 | 97.9% / 97.9% |
| both | updateTp, updateSl, requestWithdrawal, cancelWithdrawal, advanceEpoch, warp, movePrice, togglePause, checkAndAct, bond, skim | 6,958 to 7,306 each | 0 | | 0% |

In the default suite, of the 4,231 settlements 384 (9.1%) were liquidations, 3,641 (86.1%) closes and 206
(4.9%) TP/SL executions; with the one-day keeper latency, of 5,297 settlements 5 (0.1%) were liquidations,
4,850 (91.6%) closes and 442 (8.3%) TP/SL executions. forge's metrics do not split reverts by reason. From
the handler code, a `liquidate` or `executeLimit` call reverts when it finds no eligible target, when its
random pick is rejected by the engine, or while `PAUSE_SETTLE` is set; `closeTrade` while `PAUSE_SETTLE` is
set, with no open position, or on a winning close the vault cannot pay; `executeWithdrawal` when no request
is in its execution window, while `PAUSE_WITHDRAW` is set, or when the snapshot is stale. `deposit` went
through in 66.5% of calls in the default suite; round 3 measured 69.1% before the flags (the deposit pause is
now one of four flags, each set one call in four when clear).

Over the 19 campaigns of each suite (same logs), the calls that went through ranged as follows:

| Action | Default suite | Keeper latency suite |
| :----- | ------------: | -------------------: |
| closeTrade | 3,537 to 3,655 | 4,746 to 4,859 |
| liquidate | 381 to 428 | 1 to 15 |
| executeLimit | 189 to 218 | 407 to 478 |
| deposit | 4,684 to 4,831 | 4,618 to 4,756 |
| executeWithdrawal | 140 to 171 | 133 to 166 |

**Excess loss.** From the `refreshes / refreshes with E > 0 / max E` line of the `-vv` logs, last run of each
campaign:

- Keeper latency suite: all 19 campaigns logged refreshes with `E > 0`, between 9 and 19 out of 23, with a
  largest `E` between 513.79 and 55,198.73 USD.
- Default suite: all 19 campaigns also logged refreshes with `E > 0`, between 3 and 18 out of 28, with a
  largest `E` between 2,462.02 and 27,776.33 USD. In round 3, 14 of 16 default campaigns logged none: the
  difference is `PAUSE_SETTLE`, under which prices keep moving and no position can be liquidated, so
  positions pass 100% loss even with an immediate keeper. This is the interaction described in
  [Guide 8, section 5](../08-security.md#5-pause-flags).

The conservativeness bound held with tolerance 0 in every campaign of both suites. Liquidatable payers left
open also produce unpaid funding: the residual described in
[Guide 2](../02-mathematics.md#residual-funding-a-payer-cannot-pay).

Mutation checks: each of these temporary changes to `src/` made at least one invariant fail with 20 runs of
200 calls (`FOUNDRY_INVARIANT_RUNS=20 FOUNDRY_INVARIANT_DEPTH=200 forge test --match-contract ProtocolInvariantTest`):
funding applied before the 9x cap (`FlowsMatchModel`, `VaultBalanceMatchesModelledFlows`), liquidator
reward without its floor (same two), receivers credited 1% more than payers pay
(`FundingCreditsNeverExceedCharges`, `VaultFundingExposureBoundedByBadDebt`). `bond()` without the
deficit clamp made `BondsNeverExceedDeficit` (bonding suite) and `VaultBalanceMatchesModelledFlows`
(solvency suite) fail with 100 runs.

Round 2b mutation checks, run on the single-pair suite of that round, each with the default configuration
and `forge test --match-contract ProtocolInvariantTest --match-test <invariant>`: deposits without the
coverage check (`NoDepositBelowParOrStaleAction`, replaced in round 3: `deposit below 100% coverage: 1 != 0`), bonding triggered on the
NAV ratio (`BondingNeverStartsAboveCriticalRealisedRatio`: `1 != 0`), quantity removed with the short
rounding for longs (`OpenTotalsMatchPositions`: `long quantity: 1 != 0`), and the snapshot halved
(`SnapshotMatchesBruteForceAndIsConservative`: `snapshot differs from the brute-force valuation: 1 != 0`).

Round 3 and 3b mutation checks, run on the final code of round 3b with the default configuration (256 runs
of 500 calls). Each mutation was applied to `src/` alone, the command below was run, then `git checkout src`
and `rm -rf cache/invariant/failures`; none was committed.

```bash
FORK_RPC_URL= forge test --match-contract "^ProtocolInvariantTest$" --match-test <invariant>
```

| Mutation (file) | Invariant | Failure |
| :-------------- | :-------- | :------ |
| Deposits check bonding without running the pending injection: `checkAndActBeforeDeposit()` replaced by `bondingRoundOpenAfterCheck()` (`Vault.sol`) | `invariant_DepositsFollowRescueRule` | `deposit did not settle the pending injection first: 1 != 0` |
| The snapshot refresh skips pair 1 (`Vault._refreshPnlSnapshot`) | `invariant_SnapshotMatchesBruteForceAndIsConservative` | `snapshot differs from the brute-force valuation: 1 != 0` |
| The snapshot prices at the mid price: `pairPnl(price, 0, totals)` (`Vault._refreshPnlSnapshot`) | `invariant_SnapshotMatchesBruteForceAndIsConservative` | `snapshot differs from the brute-force valuation: 1 != 0` |
| `liquidate` without `whenNotPaused(PAUSE_SETTLE)` (`TradingEngine.sol`) | `invariant_NoSettlementWhileSettlePaused` | `settlement succeeded under PAUSE_SETTLE: 1 != 0` |
| No expiry extension under `PAUSE_WITHDRAW`: `extension = paused * 0` (`Vault._expiryEpoch`) | `invariant_WithdrawPauseDoesNotExpireRequests` | `request expired by time spent under PAUSE_WITHDRAW` |
| Extension rounded down instead of up: `extension = paused / EPOCH_LENGTH` (`Vault._expiryEpoch`) | `invariant_WithdrawPauseDoesNotExpireRequests` | `request expired by time spent under PAUSE_WITHDRAW` |
| Funding accrues under `PAUSE_SETTLE`: `_activeFundingFactor()` returns `fundingFactor` (`TradingEngine.sol`) | `invariant_NoFundingAccruesWhileSettlePaused` | `funding index changed across a settlement pause: 2 != 0` |

### Bonding: [`Bonding.invariant.t.sol`](../../test/invariant/Bonding.invariant.t.sol)

Driven by [`BondingHandler`](../../test/invariant/handlers/BondingHandler.sol): open rounds, bond, claim,
warp, change price, discount and vesting, set the vault's realised deficit (`MockSolvencyVault`) and close
recovered rounds as `checkAndAct` would.

| Invariant | What it asserts |
| :-------- | :-------------- |
| `invariant_EscrowCoversUnclaimedSynth` | depository $SYNTH >= promised - claimed |
| `invariant_SupplyEqualsPromised` | `synth.totalSupply()` = total bonded |
| `invariant_ClaimedNeverExceedsPromised` | per position, `claimedSynth <= totalSynth` |
| `invariant_RaisedWithinCap` | current round raise <= its cap, total raise <= sum of caps, vault USDC = total raise |
| `invariant_BondsNeverExceedDeficit` | each bond took `min(amount, cap, realised deficit)` and the bond that took all of it closed the round |

### Solvency (integration): [`Solvency.invariant.t.sol`](../../test/integration/Solvency.invariant.t.sol)

Driven by [`SolvencyHandler`](../../test/integration/handlers/SolvencyHandler.sol) on the wired
`DeployLib` deployment: LP deposits, simulated trader payouts (`sendPayout`), fee accrual, rescues, bonding,
claims and skims. No trade is opened, so the NAV and realised ratios are equal in this suite.

| Invariant | What it asserts |
| :-------- | :-------------- |
| `invariant_VaultBalanceMatchesModelledFlows` | vault USDC = 1,000,000 + deposits - payouts + vault fees + injections + skims + bond proceeds |
| `invariant_AssistantFundBalanceMatchesModelledFlows` | reserve USDC = reserve fees - injections - skims |
| `invariant_FlowsMatchModel` | every injection, bond and skim moved the modelled amount |
| `invariant_RescueNeverOvershootsTarget` | CR after a rescue that raised it is <= 100% (replaces the round 1 bound CR < 100x) |
| `invariant_RescueAlwaysCallable` | deficit <= nominal liabilities and `checkAndAct` does not revert (on a snapshot) |
| `invariant_ReserveNeverExceedsCapAfterSkim` | after `skim` (on a snapshot) the reserve is <= `targetCap` |
| `invariant_EscrowSolventUnderFullSystem` | depository $SYNTH covers unclaimed vesting |
| `invariant_SynthSupplyOnlyFromBonding` | $SYNTH supply = total bonded |

---

## Tolerances

| Test | Round 1 | Round 2 | Why |
| :--- | :------ | :------ | :-- |
| `SolvencyManager.t.sol` `testFuzz_DeficitRestoresToHundred` | 2 | 0 | the mock deficit and the expected value use the same floor division |
| `BondDepository.t.sol` `test_Claim_HalfwayLinear` (two assertions) | 1 | 0 | `VESTING` is even, so half the vesting floors exactly to `synthOut / 2` |
| `Solvency.integration.t.sol` `test_Deficit_ReserveCoversWithoutBonding` | 1e12 | 0 | supply is 1e24 shares, a multiple of 1e12, so CR returns to exactly 1e18 |
| `Solvency.invariant.t.sol` rescue bound | CR < 100x | CR <= 100% after a rescue | the rescue is sized from `floor(totalSupply / 1e12)` |
| `Vault.t.sol` `test_DirectTransfer_IncreasesShareValue` | 1 | 1 (kept) | Solady's virtual `+1` asset does not double with the donation |
| `FundingLib.t.sol` `testFuzz_FundingOwed_LinearWithSize` | 1 | 1 (kept) | each call rounds once, so twice the single result can differ by one unit |

---

## Fuzz tests

A selection of the 54 `testFuzz_*` functions, by area (the ones added in round 3 are the last four rows and
`testFuzz_OpenFee_BelowCollateralForEveryAcceptedLeverage`).

| Area | Tests | Property |
| :--- | :---- | :------- |
| PnL and payouts | `testFuzz_CloseTrade_PnL`, `testFuzz_ProfitCap`, `testFuzz_OpenTrade` | PnL symmetry, payout cap |
| Open fee | `testFuzz_OpenFee_BelowCollateralForEveryAcceptedLeverage` | For every leverage the engine accepts, the open fee is below the collateral (why `FeeExceedsCollateral` was removed) |
| Liquidations | `testFuzz_Liquidate_TotalConserved`, `testFuzz_Liquidate_ShortRoundingFavorsPool` | Reward plus vault share equals collateral; short rounding favours the pool |
| Opening guard | `testFuzz_Regression_OpenGuard_NoSameBlockLiquidation` | No open position is liquidatable in the same block at the same price |
| Funding | `testFuzz_IndexDeltas_Symmetry`, `testFuzz_IndexDeltas_CreditsNeverExceedCharges`, `testFuzz_IndexDeltas_MonotonicWithTime`, `testFuzz_FundingOwed_LinearWithSize`, `testFuzz_Funding_FundsConservation` | Zero sum at the index level, ceiling, conservation with unbalanced OI (long 1.5x to 10x the short) |
| Spread | `testFuzz_GetSpreadBps_NeverExceedsMax`, `testFuzz_GetSpreadBps_MonotonicInOI` | Cap and monotonicity |
| Vault | `testFuzz_DepositAndWithdraw`, `testFuzz_SendPayout`, `testFuzz_CR_TracksTotalAssets`, `testFuzz_MaxWithdraw_MatchesWithdraw`, `testFuzz_MaxRedeem_MatchesRedeem` | Share accounting, CR, `max*` against their actions |
| Storage | `testFuzz_DeleteTrade_UserListStaysConsistent` | The user's trade list holds exactly the open trades after random deletions |
| Bonding | `testFuzz_Bond_ConservesCapAndInjects`, `testFuzz_Vested_MonotonicAndBounded`, `testFuzz_Claim_NoDustAfterFullVesting` | Vesting bounds, no dust |
| Limit orders | `testFuzz_ExecuteLimit_ConservesFunds` | Executor reward comes from the payout, not the vault |
| Open PnL math | `testFuzz_Quantity_LongAtMostOneAboveShort`, `testFuzz_SidePnl_OverstatesPerPositionSum`, `testFuzz_PairPnl_AtLeastAnyPriceInBand` | Rounding direction, aggregate at least the per-position sum, band edge choice (2 wei tolerance) |
| Open PnL aggregates | `testFuzz_Aggregates_NoDriftAfterManyOpensAndCloses` | Totals return exactly to the brute-force sums after random opens and closes |
| NAV | `testFuzz_PreviewsMatchActionsAtNav`, `testFuzz_Ratios_RealisedAtLeastNav` | `previewDeposit`/`previewMint` equal `deposit`/`mint` with a fresh snapshot; realised ratio >= NAV ratio |
| Open PnL bounds | `testFuzz_PairPnl_NoOverflowWithinOracleBounds`, `testFuzz_Quantity_NoOverflowAtLargestSize` | `pairPnl` does not revert for prices up to 1e36 with confidence within 2% and any uint128 totals; `quantity` does not overflow up to the largest size TradingStorage can store (uint64 collateral x 100 x 1e12) |
| ERC-4626 at the NAV | `testFuzz_PreviewsEqualActions`, `testFuzz_RoundingDirection`, `testFuzz_ExecuteWithdrawalPaysPreviewRedeem` | Previews equal actions; `convertTo*`, `previewDeposit` and `previewRedeem` round down, `previewMint` and `previewWithdraw` round up; a withdrawal pays `previewRedeem` of its shares |
| sUSDC with escrow | `testFuzz_EscrowedSharesFollowNavAndCannotMove` | Escrowed shares stay in the supply, follow the NAV, and cannot be moved directly or through an allowance |
| Deposit rule | `testFuzz_MaxDepositMatchesDeposit`, `testFuzz_MaxMintMatchesMint` | `maxDeposit`/`maxMint` are 0 exactly when `deposit`/`mint` revert, with the `SolvencyManager` wired |

---

## Unit tests by contract

Counts from `forge test --match-path "test/unit/*" --summary`.

| Contract | Test file | Tests |
| :------- | :-------- | ----: |
| TradingEngine | [`TradingEngine.t.sol`](../../test/unit/TradingEngine.t.sol) | 165 |
| TradingStorage | [`TradingStorage.t.sol`](../../test/unit/TradingStorage.t.sol) | 119 |
| Vault | [`Vault.t.sol`](../../test/unit/Vault.t.sol) | 76 |
| Vault (NAV, snapshot, ratios) | [`VaultNav.t.sol`](../../test/unit/VaultNav.t.sol) | 35 |
| Vault (ERC-4626 conformity at the NAV, sUSDC with escrow) | [`VaultErc4626.t.sol`](../../test/unit/VaultErc4626.t.sol) | 7 |
| Vault (snapshot refresh with a nonzero Pyth fee, 3 pairs) | [`VaultRefreshFee.t.sol`](../../test/unit/VaultRefreshFee.t.sol) | 6 |
| Vault (deposit rule with the `SolvencyManager` wired) | [`VaultDepositRule.t.sol`](../../test/unit/VaultDepositRule.t.sol) | 3 |
| SpreadManager | [`SpreadManager.t.sol`](../../test/unit/SpreadManager.t.sol) | 48 |
| BondDepository | [`BondDepository.t.sol`](../../test/unit/BondDepository.t.sol) | 49 |
| PythChainlinkOracle | [`PythChainlinkOracle.t.sol`](../../test/unit/PythChainlinkOracle.t.sol) | 37 |
| SolvencyManager | [`SolvencyManager.t.sol`](../../test/unit/SolvencyManager.t.sol) | 29 |
| SynthToken | [`SynthToken.t.sol`](../../test/unit/SynthToken.t.sol) | 20 |
| AssistantFund | [`AssistantFund.t.sol`](../../test/unit/AssistantFund.t.sol) | 19 |
| FundingLib | [`FundingLib.t.sol`](../../test/unit/FundingLib.t.sol) | 17 |
| OpenPnlLib | [`OpenPnlLib.t.sol`](../../test/unit/OpenPnlLib.t.sol) | 14 |
| Downcasts at their bounds | [`TypecastBounds.t.sol`](../../test/unit/TypecastBounds.t.sol) | 8 |
| Griefing paths and edge cases on the wired protocol | [`EdgeCases.t.sol`](../../test/unit/EdgeCases.t.sol) | 7 |

Total: 659.

### Mocks: [`test/mocks/`](../../test/mocks/)

`MockOracle` (preset prices and confidence, payable fee flow, optional revert), `MockChainlinkFeed`
(configurable answer, decimals, `startedAt` and `updatedAt`; also plays the sequencer uptime feed),
`MockSpreadManager` (fixed spread), `MockSolvencyVault` (settable realised collateralization deficit for the
bonding tests). `MockUSDC` is defined in each test file. `MockOracle` charges its fee on every call, so the
multi-pair refresh tests run it with a zero fee; the gas benchmark at `MAX_PAIRS` uses the real oracle.

---

## Fork tests

[`PythChainlinkOracle.fork.t.sol`](../../test/fork/PythChainlinkOracle.fork.t.sol) has 21 tests against
Arbitrum One (chain 42161). They fork `FORK_RPC_URL` at `FORK_BLOCK_NUMBER`, default 504,522,171
(2026-09-12 21:25:49 UTC), a block that contains an on-chain Pyth update of BTC/USD and ETH/USD published
1 second earlier (tx `0x0c93c1c31a58b7c97eb3a3a2541aa38dd331e9c0bf1e7e0a154bf25b40a84349`). The stored
prices are therefore fresh and `getPrice` runs with empty update data: there is no Hermes call and no
`ffi` (`ffi = false` in `foundry.toml`). The RPC must serve historical state (an archive node).

| Address | Contract | Checked by |
| :------ | :------- | :--------- |
| `0xff1a0f4744e8582DF1aE09D5611b887B6a12925C` | Pyth (ERC-1967 proxy) | `test_Fork_AddressesHaveCode`, `test_Fork_PythProxyRunsUpgradedImplementation` |
| `0x8391e5e91d27D1d89139bc94b27Ed8B67a17a6cB` | Pyth implementation set by the Pyth Core upgrade (`Upgraded` event at block 498,630,307, 2026-08-26 16:11:30 UTC); `version()` returns `1.4.6` | same |
| `0x6ce185860a4963106506C203335A2910413708e9` | Chainlink BTC/USD, 8 decimals, heartbeat 1,755 s | `test_Fork_ChainlinkDecimals_Are8` |
| `0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612` | Chainlink ETH/USD, 8 decimals, heartbeat 1,755 s | same |
| `0xFdB631F5EE196F0ed6FAa767959853A9F217697D` | Chainlink L2 sequencer uptime feed | `test_Fork_Sequencer_IsUpPastGracePeriod` |

The heartbeats come from Chainlink's reference data for Arbitrum One:

```bash
curl -s https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-arbitrum-1.json \
  | jq -r '.[] | select(.proxyAddress=="0x6ce185860a4963106506C203335A2910413708e9" or .proxyAddress=="0x639Fe6ab55C921f74e7fac1ee960C0B6293ba612") | "\(.name) \(.heartbeat) \(.decimals)"'
```

The Pyth Core upgrade of the Arbitrum One proxy is the `Upgraded(address)` event at block 498,630,307:

```bash
cast logs --rpc-url https://arb1.arbitrum.io/rpc --from-block 498427544 --to-block 498827543 \
  --address 0xff1a0f4744e8582DF1aE09D5611b887B6a12925C 0xbc7cd75a20ee27fd9adebab32041f755214dbc6bffa90cc0225b39da2e5c2d3b
cast block 498630307 --field timestamp --rpc-url https://arb1.arbitrum.io/rpc   # 1787760690, 2026-08-26 16:11:30 UTC
```

The tests cover the
price path for both feeds, the Chainlink deviation (2 BPS for BTC and 1 BPS for ETH at the pinned block),
confidence, staleness after a warp, the update fee (0 wei on Arbitrum One, for empty and real update data),
a recorded signed update taken from the calldata of the updating transaction (verified with
`parsePriceFeedUpdates` and passed through `getPrice`), the sequencer feed (live, and mocked down or in its
grace period), an open and close through `TradingEngine` on the real oracle, and, added in round 3, the
sequencer grace period on the real oracle (`test_Fork_Sequencer_GracePeriodBlocksOpeningOnly`:
`checkOpenAllowed` reverts, `getPrice` returns a price) and through the engine
(`test_Fork_TradingEngine_GracePeriodClosesButDoesNotOpen`: a close goes through, an open reverts with
`SequencerGracePeriodNotOver`), and, with one position open, `Vault.refreshPnlSnapshot` followed by
`Vault.refreshAndDeposit` on the stored BTC price (`test_Fork_Vault_RefreshSnapshotAndDeposit`).

`FORK_RPC_URL=<arbitrum-one-archive-rpc> forge test --match-path "test/fork/*"`: 21 passed at block
504,522,171. Without `FORK_RPC_URL` the 21 tests skip. Forge loads `.env` from the project root, so mock
mode needs `FORK_RPC_URL` absent or empty.

---

## Gas benchmarks

[`test/gas/GasBenchmarks.t.sol`](../../test/gas/GasBenchmarks.t.sol) records the gas of one successful call
per entry point with `vm.snapshotGasLastCall` into [`snapshots/`](../../snapshots/). The contracts are wired
as in `DeployLib` with the real `PythChainlinkOracle` on `MockPyth` (no Wormhole signature verification, so
the Pyth part costs less than on a live chain), a sequencer uptime feed and the real `SpreadManager`; one
position is already open on the pair, so `deposit`, `executeWithdrawal` and `checkAndAct` run after a
snapshot refresh that is not measured. The build uses the optimizer with 200 runs.

| Call | Gas (`FOUNDRY_PROFILE=gas forge test`, `snapshots/*.json`) |
| :--- | --: |
| `TradingEngine.openTrade` (with TP and SL) | 300,422 |
| `TradingEngine.closeTrade` (profit) | 129,992 |
| `TradingEngine.liquidate` | 127,387 |
| `TradingEngine.executeLimit` (TP) | 159,046 |
| `Vault.deposit` (runs `SolvencyManager.checkAndActBeforeDeposit`, nothing to inject) | 65,782 |
| `Vault.refreshAndDeposit` | 187,280 |
| `Vault.requestWithdrawal` | 64,293 |
| `Vault.executeWithdrawal` | 34,384 |
| `Vault.refreshAndExecuteWithdrawal` | 157,878 |
| `Vault.refreshPnlSnapshot`, 1 pair | 126,603 |
| `Vault.refreshPnlSnapshot`, 20 pairs (`MAX_PAIRS`), a long and a short on each | 640,715 |
| `SolvencyManager.checkAndAct` (injects the reserve and opens a bonding round) | 64,396 |
| `SolvencyManager.refreshAndCheckAndAct` (same path) | 197,121 |
| `BondDepository.bond` | 139,037 |

`Vault.deposit` went from 49,605 in round 2b to 65,737 in round 3: it calls the `SolvencyManager` set on the
vault before minting (`checkAndActBeforeDeposit`), which reads the reserve and the bonding state. Round 3b
moved the other rows by the pause flags: `requestWithdrawal` (61,818 to 64,293) and `executeWithdrawal`
(33,073 to 34,384) read the withdrawal pause clock, and the engine's settlement calls read the flags.
`checkAndAct` fell from 66,606 to 64,396 because `activateBonding` no longer reads `referencePrice`, and
`bond` rose from 137,037 to 139,037 because its benchmark runs `checkAndAct` first in the same transaction,
so `bond` now reads `referencePrice` cold (on a live chain the two calls are separate transactions). The `gas` job in
[`.github/workflows/test.yml`](../../.github/workflows/test.yml) runs `FOUNDRY_PROFILE=gas forge test` as a
pass/fail check: every benchmark must succeed, and the gas values are not compared with the committed
snapshots (forge compares them only when `FORGE_SNAPSHOT_CHECK` is set). To compare locally:

```bash
FORGE_SNAPSHOT_CHECK=true FOUNDRY_PROFILE=gas forge test
```

---

## Coverage

From `FORK_RPC_URL= FOUNDRY_PROFILE=coverage forge coverage --report summary` at commit `47d848f` (coverage
builds disable the optimizer; the profile excludes `test/gas`). The run executed 818 tests: 797 passed, 21
skipped (the fork suite).

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

Round 3 listed nine branches never taken, all reverts. Eight now have tests (commit `1a7442c`: in
`BondDepository.t.sol` `test_ActivateBonding_RevertWhenSolvencyManagerNotSet`, `test_BondAt_InvalidIdReverts`,
`test_Claimable_InvalidIdReverts`, `test_SetSolvencyManager_ZeroAddressReverts`,
`test_SetDiscountBps_EffectivePriceZeroReverts`; in `TradingEngine.t.sol`
`test_UpdateTp_RevertWhenAlreadyTriggeredForShort`, `test_UpdateSl_RevertWhenAlreadyTriggeredForShort`; in
`Vault.t.sol` `test_SetSolvencyManager_ZeroAddressReverts`). The ninth, `ReferencePriceUnset` in
`activateBonding`, could not be reached and was removed (commit `b5e0f1a`). The "Total" row of the report
also counts `node_modules/`, `script/` and `test/`. Line coverage says a line ran, not that its result was
checked.

---

## Static analysis

Run at commit `47d848f`. The later commits change documentation and cast comments with the same line count,
so the lines cited below are unchanged.

| Tool | Command | Raw result |
| :--- | :------ | :--------- |
| Slither 0.11.6 | `slither . --filter-paths "lib\|node_modules\|test" --json <file>` | 199 results: 4 High, 15 Medium, 46 Low, 134 Informational |
| Aderyn 0.6.8 | `aderyn --src src -o <file>.md` | 3 High issues (11 instances), 8 Low issues (53 instances) |

Slither counts by detector come from
`jq -r '.results.detectors[] | "\(.impact) \(.check)"' <file> | sort | uniq -c`; Aderyn counts from the
"Found Instances" line of each issue in the report. Earlier baselines with the same commands: at `c3d552a`
(start of round 3) Slither 197 and Aderyn 3 High (14 instances) and 6 Low (53); at `2dd5562` (end of round 3)
Slither 196 and Aderyn 3 High (11) and 8 Low (57).

Changes in round 3b, from a line-by-line diff of the two JSON reports: Slither `calls-loop` 17 to 22 (the
`setPauseFlags` loop in `TradingEngine` calls `_updateFundingIndex` for every pair, 5 call sites),
`naming-convention` 123 to 125 (the `_flags` parameter of the two `setPauseFlags`), and
`unindexed-event-address` 4 to 0 (the `Paused(address)` and `Unpaused(address)` events were removed). Aderyn
L-1 36 to 34 and L-5 5 to 3 (`pause`, `unpause` and the `whenPaused` modifiers were removed).

### Triage

Verdicts: **fixed** (the code changed and the result is gone), **false positive** (the pattern the detector
looks for is not there), **accepted by design** (the pattern is there and is intended; the reason says why).
Instances are those of the final run; fixed rows give the count when the result was present.

| Tool | Detector | Instances | Verdict | Reason | Commit |
| :--- | :------- | --------: | :------ | :----- | :----- |
| Slither | `reentrancy-no-eth` (Medium) | 0 (1 at `c3d552a`) | fixed | `TradingEngine.setFundingFactor` wrote the factor after the calls to TradingStorage that accrue each pair; it now writes and emits first, then accrues at the old factor | `52d7c2b` |
| Slither | `reentrancy-events` (Low), `setFundingFactor` | 0 (1 at `c3d552a`) | fixed | same change: `FundingFactorUpdated` is emitted before the loop | `52d7c2b` |
| Slither | `unindexed-event-address` (Informational) | 0 (4 at `2dd5562`) | removed with the code | `Paused(address)` and `Unpaused(address)` no longer exist; `PauseFlagsUpdated(uint8)` has no address | `3422f8e` |
| Slither | `msg-value-loop` (High) | 4 | false positive | one line, `Vault.sol:290`, reported once per caller of `_refreshPnlSnapshot`; `msg.value` goes only to the first priced pair, and the `pythUpdated` flag sends later pairs through `getPrice` without value (`Vault.sol:287`). `test/unit/VaultRefreshFee.t.sol` checks the ETH accounting with a nonzero fee on three pairs | `2d88c2d` (test) |
| Slither | `incorrect-equality` (Medium) | 6 | false positive | equality with values no one can steer by sending tokens: `deltaTime == 0` (`TradingEngine.sol:339`), `supply == 0` (`Vault.sol:609`, `619`), `shares == 0` of the caller's request (`Vault.sol:494`), `claimed == 0` (`BondDepository.sol:247`) and the position nonce (`Vault.sol:640`), which must match exactly | |
| Slither | `pyth-unchecked-confidence` (Medium) | 1 | false positive | the confidence is checked against 2% of the price at `PythChainlinkOracle.sol:154` (`ConfidenceTooWide`) | |
| Slither | `uninitialized-local` (Medium) | 3 | false positive | `noUpdate`, `pythUpdated` and `netWad` in `_refreshPnlSnapshot` (`Vault.sol:279` to `281`) start at their default values on purpose: an empty update, no update sent yet, zero sum | |
| Slither | `unused-return` (Medium) | 5 | accepted by design | the ignored fields are not needed: Chainlink round ids and times the checks do not use (`PythChainlinkOracle.sol:202`, `210`), the confidence outside liquidations (`TradingEngine.sol:186`), and the half of `getPositionState` a caller does not need (`Vault.sol:264`, `295`) | |
| Slither | `timestamp` (Low) | 18 | accepted by design | staleness, sequencer grace, epochs, vesting and funding use `block.timestamp`; a timestamp shifted by a few seconds moves these by the same few seconds | |
| Slither | `calls-loop` (Low) | 22 | accepted by design | loops over pairs, at most `MAX_PAIRS` (20): funding accrual in `setFundingFactor` and `setPauseFlags`, and the snapshot refresh; the callees are TradingStorage and the owner-set oracle, and a revert on any pair is meant to revert the whole call | |
| Slither | `reentrancy-events` (Low) | 5 | accepted by design | events after calls to protocol contracts set at deploy (`SynthToken.mint` in `bond`, `AssistantFund` and `BondDepository` in `_checkAndAct`); those contracts do not call back | |
| Slither | `reentrancy-benign` (Low) | 1 | accepted by design | `_refreshPnlSnapshot` writes the snapshot (`Vault.sol:298`) after the oracle calls; every caller is `nonReentrant` (`Vault.sol:648` and the `refreshAnd*` entry points) | |
| Slither | `assembly` (Informational) | 4 | accepted by design | `tstore`/`tload` of the ETH baseline in `_recordEthBaseline`/`_refundEth` of TradingEngine and Vault (transient storage has no high-level syntax in Solidity 0.8.24) | |
| Slither | `missing-inheritance` (Informational) | 5 | accepted by design | the interfaces in `src/interfaces/` declare only what a caller uses; the contracts do not inherit them | |
| Slither | `naming-convention` (Informational) | 125 | accepted by design | 105 parameters with a leading underscore and 20 immutables in upper case, both project conventions ([Guide 5](../05-implementation.md)) | |
| Aderyn | H-2 Reentrancy: state change after external call, `setFundingFactor` | 0 (1 at `c3d552a`) | fixed | same change as the Slither row above | `52d7c2b` |
| Aderyn | H-3 Unsafe casting of integers, `BondDepository` `synthOut` and the oracle's normalized price | 0 (2 at `c3d552a`) | fixed | both use `SafeCastLib` and revert instead of truncating; `test/unit/TypecastBounds.t.sol` tests each at its bound | `4145744` |
| Aderyn | L "Public function not used internally", `Vault.collateralizationRatio` | 0 (1 after `21d9361`) | fixed | `external` again | `2dd5562` |
| Aderyn | H-1 Contract locks Ether without a withdraw function | 9 | accepted by design | every contract inherits Solady's `Ownable`, whose ownership functions are `payable`; ETH sent with them stays in the contract. The fee paths (engine, vault, `SolvencyManager`, oracle) refund what the oracle does not use (`test/regression/EthRefundRegression.t.sol`, `test/unit/VaultRefreshFee.t.sol`) | |
| Aderyn | H-2 Reentrancy: state change after external call | 1 | false positive | `BondDepository.sol:207` is a `view` call (STATICCALL) to the vault's `realisedCollateralizationDeficit` before `remainingCap` is written | |
| Aderyn | H-3 Unsafe casting of integers | 1 | false positive | `Vault.sol:320` casts the constant 60 to `uint32` | |
| Aderyn | L-1 Centralization risk | 34 | accepted by design | owner-set parameters, wiring and pause flags; the trust assumptions are in [Guide 8](../08-security.md) | |
| Aderyn | L-2 Empty block | 2 | accepted by design | `maxWithdraw` and `maxRedeem` (`Vault.sol:456`, `458`) return the default 0: `withdraw` and `redeem` are disabled in favour of the 3-epoch queue | `120adca` |
| Aderyn | L-3 Large numeric literal | 5 | accepted by design | `10_000` in the four `BPS_DENOMINATOR` constants and in the slippage check (`TradingEngine.sol:302`) | |
| Aderyn | L-4 Literal instead of constant | 6 | accepted by design | `10 ** _decimalsOffset()` in the Vault ratios (`Vault.sol:610`, `620`, `627`, `660`) and `1e12` in the quantity updates (`TradingStorage.sol:233`, `243`), each a unit conversion next to its use | |
| Aderyn | L-5 Modifier invoked only once | 3 | accepted by design | the project's modifier-to-internal-check pattern is applied to every access check, including those used once | |
| Aderyn | L-6 State change without event | 1 | accepted by design | `TradingStorage.setTradeFundingIndex` (`TradingStorage.sol:441`) is called only by the engine while opening a trade, which emits `TradeOpened`; the index is readable with `getTradeFundingIndex` | |
| Aderyn | L-7 Unchecked return | 1 | accepted by design | `getPrice` calls `_checkSequencerUp()` (`PythChainlinkOracle.sol:130`) only for its revert while the sequencer is down; the returned `startedAt` is used by `checkOpenAllowed` | `16baf19` |
| Aderyn | L-8 Uninitialized local variable | 1 | false positive | `noUpdate` at `Vault.sol:279`, the intended empty update (same as the Slither row) | |

By verdict: of the 199 Slither results of the final run, 14 are false positives (4 + 6 + 1 + 3) and 185
accepted by design (5 + 18 + 22 + 5 + 1 + 4 + 5 + 125); 2 results of the round 3 baseline were fixed and 4
disappeared with the removed pause events. Of the 64 Aderyn instances of the final run, 3 are false positives
(1 + 1 + 1) and 61 accepted by design (9 + 34 + 2 + 5 + 6 + 3 + 1 + 1); 4 instances were fixed in round 3.
This triage is the author's; a result marked accepted or false positive here has not been checked by anyone
else.

---

## Bugs fixed before this review

These are the author's records of earlier fixes. The regression tests named here exist and pass.

1. **Division by zero in `BondDepository`.** `setReferencePrice` only rejected 0, but the discounted price
   is `referencePrice * (10000 - discountBps) / 10000`, which can floor to 0 and make `quoteBond` divide
   by zero, so every `bond` call reverted. Both setters now check the computed price
   (`EffectivePriceZero`). Tests: `test_SetReferencePrice_EffectivePriceZeroReverts`,
   `test_SetReferencePrice_QuoteStillWorksAfterRejectedPrice`.
2. **Division by zero in `SolvencyManager`.** With `totalAssets == 0` and shares outstanding, CR is 0 and
   the old deficit formula divided by it, so `checkAndAct` reverted in the total-insolvency case. The
   deficit now comes from `Vault.collateralizationDeficit()`. Tests:
   `test_TotalInsolvency_RescueStillCallable`, `test_TotalInsolvency_DeficitEqualsNominalLiabilities`,
   `test_TotalInsolvency_BondingRestoresFromZero`.

Findings fixed in round 2 are listed in the root README under "Review notes".

---

## Related

- [ROADMAP](../ROADMAP.md)
- [Security](../08-security.md)
- [Vault and solvency](../07-vault-ssl.md)
