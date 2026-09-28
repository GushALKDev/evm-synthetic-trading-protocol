# Test Suite

**Status:** Proof of concept. Not audited and not deployed.

All numbers below were measured on 2026-09-28 at commit `aaceb08` (branch `fix/review-findings`) after
`npm ci`, with forge 1.7.1 and solc 0.8.24. Mock-mode numbers are taken with `FORK_RPC_URL` empty; later
commits only change documentation and add `script/analysis/pyth_update_age.py`.

| Group | Location | Tests | Command that counts them |
| :---- | :------- | ----: | :----------------------- |
| Unit | `test/unit/` | 539 | `forge test --match-path "test/unit/*" --summary` |
| Regression (round 2 findings) | `test/regression/` | 33 | `forge test --match-path "test/regression/*" --summary` |
| Integration | `test/integration/Solvency.integration.t.sol` | 17 | `forge test --match-path "test/integration/*" --summary` |
| Invariant (integration) | `test/integration/Solvency.invariant.t.sol` | 8 | same as above |
| Invariant | `test/invariant/` | 16 | `forge test --match-path "test/invariant/*" --summary` |
| Fork | `test/fork/` | 19 | skipped without `FORK_RPC_URL` |
| **Total (correctness)** | | **632** | `forge test --list --json 2>/dev/null \| jq '[.[][][]] \| length'` |
| Gas benchmarks (not counted above) | `test/gas/` | 9 | `FOUNDRY_PROFILE=gas forge test --list --json 2>/dev/null \| jq '[.[][][]] \| length'` |

`forge test` in mock mode: 613 passed, 0 failed, 19 skipped (the fork suite).

There are 39 functions named `testFuzz_*` and 24 stateful invariant functions (`invariant_*`). Count them
with:

```bash
forge test --list --json 2>/dev/null | jq '[.[][][] | select(startswith("testFuzz_"))] | length'   # 39
forge test --list --json 2>/dev/null | jq '[.[][][] | select(startswith("invariant_"))] | length'  # 24
```

`foundry.toml` has no `[fuzz]` or `[invariant]` section, so Foundry defaults apply: 256 runs per fuzz test,
and 256 runs of 500 calls per invariant (forge reports 128,000 calls per invariant function). The default
profile skips `test/gas`; the `gas` profile runs only it.

```bash
forge test                                    # correctness suite (fork tests skip without FORK_RPC_URL)
forge test --match-path "test/regression/*"   # round 2 regression tests
forge test --match-path "test/invariant/*"    # invariants
FORK_RPC_URL=<arbitrum-one-archive-rpc> forge test --match-path "test/fork/*"
FOUNDRY_PROFILE=gas forge test                # gas benchmarks, written to snapshots/*.json
forge coverage --report summary
```

---

## Regression tests (round 2)

One file per finding, in [`test/regression/`](../../test/regression/). The tests named `test_Regression_*`
and `testFuzz_Regression_*` failed against the code before their fix (the failing output is in the round 2
report); the other tests in these files pass before and after. Most use only functions that existed before
the fix, so they compile against it.

| File | Finding | Tests |
| :--- | :------ | ----: |
| `FundingRegression.t.sol` | Funding paid by the vault, unnormalised rate | 2 |
| `WithdrawalRegression.t.sol` | Withdrawal requests without expiry or escrow; `max*` functions | 5 |
| `OracleLatencyRegression.t.sol` | 30 s price window; future `publishTime` underflow | 3 |
| `SequencerRegression.t.sol` | No L2 sequencer uptime check | 5 |
| `LeverageRegression.t.sol` | No global leverage cap | 3 |
| `OpenGuardRegression.t.sol` | Opening guard ignored the close spread and the open fee | 3 |
| `LiquidationRewardRegression.t.sol` | Zero liquidator reward past 100% loss | 1 |
| `DeleteTradeRegression.t.sol` | Linear search in `deleteTrade` | 2 |
| `EthRefundRegression.t.sol` | Force-sent ETH paid to the next caller | 2 |
| `ReentrancyRegression.t.sol` | `updateTp`/`updateSl` without `nonReentrant`; re-entry through the ETH refund | 4 |
| `BondingRoundRegression.t.sol` | Bonding round not closed when CR recovers | 3 |

---

## Invariant suites

Each invariant is checked after every call of a random sequence. Call summaries are logged from
`afterInvariant` hooks (forge prints the last run's logs with `-vv`), not from invariant functions.

### Protocol: [`Protocol.invariant.t.sol`](../../test/invariant/Protocol.invariant.t.sol)

Deploys the engine, storage, vault, `AssistantFund` (as treasury), `SolvencyManager`, `BondDepository` and
`SynthToken` with `MockOracle` and `MockSpreadManager(5)`; the vault starts with 1,000,000 USDC. Two
handlers:

- [`ProtocolHandler`](../../test/invariant/handlers/ProtocolHandler.sol): open (collateral 10 to 5,000
  USDC, leverage 1 to 100, optional TP/SL), close, liquidate, `executeLimit`, `updateTp`, `updateSl`. It
  models every settlement from the documented formulas and compares the trader and keeper payouts with the
  model. `closeTrade`, `liquidate` and `executeLimit` revert when they settle nothing, so in the metrics
  table below calls minus reverts is the number of settlements.
- [`LiquidityHandler`](../../test/invariant/handlers/LiquidityHandler.sol): deposit, withdrawal request,
  execution and cancellation, epoch advance, warp (1 minute to 1 day), price moves up or down by up to 5%
  per call within 60% to 140% of 50,000, pause and unpause of the engine or the vault, `checkAndAct`,
  `bond`, `skim`. Each flow is modelled before the call and compared with the measured amount.

| Invariant | What it asserts |
| :-------- | :-------------- |
| `invariant_VaultBalanceMatchesModelledFlows` | vault USDC = 1,000,000 + deposits - withdrawals + vault fee share + modelled trader losses - modelled trader profits + injections + skims + bond proceeds |
| `invariant_AssistantFundBalanceMatchesModelledFlows` | reserve USDC = treasury fee share - injections - skims |
| `invariant_FlowsMatchModel` | no trader, keeper, withdrawal, injection, skim or bond amount differed from the model |
| `invariant_FundingCreditsNeverExceedCharges` | 0 <= sum of settled `fundingOwed` + funding accrued by open positions <= number of positions counted |
| `invariant_VaultFundingExposureBoundedByBadDebt` | collected - credited + accrued + tracked bad debt >= 0 (the vault pays funding only up to the bad-debt residual) |
| `invariant_StorageHoldsExactlyOpenCollateral` | TradingStorage USDC = sum of open collateral |
| `invariant_OpenInterestMatchesPositionsAndCap` | long and short OI equal the open positions of each side, and long + short <= `maxOI` |
| `invariant_EscrowedSharesMatchRequests` | shares held by the vault = shares of all pending withdrawal requests |
| `invariant_RescueNeverOvershootsTarget` | CR after a rescue action (injection or bond) that raised it is <= 100% |
| `invariant_SharePricePositive` | `convertToAssets(1e18) > 0` while shares exist |
| `invariant_SharesBackedByAssets` | shares outstanding imply assets > 0 |

Call distribution for the `invariant_VaultBalanceMatchesModelledFlows` campaign (256 runs x 500 calls),
from `forge test --match-path "test/invariant/Protocol.invariant.t.sol" -vv` (forge runs one campaign per
invariant function; the other campaigns are within a few percent):

| Handler | Action | Calls | Reverts | Settled |
| :------ | :----- | ----: | ------: | ------: |
| ProtocolHandler | openTrade | 7,429 | 0 | |
| ProtocolHandler | closeTrade | 7,567 | 3,766 | 3,801 |
| ProtocolHandler | liquidate | 7,396 | 6,710 | 686 |
| ProtocolHandler | executeLimit | 7,533 | 7,337 | 196 |
| ProtocolHandler | updateTp / updateSl | 7,615 / 7,493 | 0 / 0 | |
| LiquidityHandler | deposit / requestWithdrawal / executeWithdrawal / cancelWithdrawal | 7,271 / 7,630 / 7,581 / 7,613 | 0 | |
| LiquidityHandler | advanceEpoch / warp / movePrice / togglePause | 7,557 / 7,466 / 7,630 / 7,536 | 0 | |
| LiquidityHandler | checkAndAct / bond / skim | 7,497 / 7,635 / 7,551 | 0 | |

Of the 4,683 settlements, 686 (14.6%) were liquidations, 3,801 (81.2%) closes and 196 (4.2%) TP/SL
executions. Before round 2 the funding rate liquidated most leveraged positions within minutes of a warp.
The logs of the last run of each campaign report between 585 and 721 USDC of unpaid funding
(`funding bad debt`): the handler liquidates a random position per call, so a liquidatable payer can stay
open for days of warps, which is the residual described in
[Guide 2](../02-mathematics.md#residual-funding-a-payer-cannot-pay).

Mutation checks: each of these temporary changes to `src/` made at least one invariant fail with 20 runs of
200 calls (`FOUNDRY_INVARIANT_RUNS=20 FOUNDRY_INVARIANT_DEPTH=200 forge test --match-contract ProtocolInvariantTest`):
funding applied before the 9x cap (`FlowsMatchModel`, `VaultBalanceMatchesModelledFlows`), liquidator
reward without its floor (same two), receivers credited 1% more than payers pay
(`FundingCreditsNeverExceedCharges`, `VaultFundingExposureBoundedByBadDebt`). `bond()` without the
deficit clamp made `BondsNeverExceedDeficit` (bonding suite) and `VaultBalanceMatchesModelledFlows`
(solvency suite) fail with 100 runs.

### Bonding: [`Bonding.invariant.t.sol`](../../test/invariant/Bonding.invariant.t.sol)

Driven by [`BondingHandler`](../../test/invariant/handlers/BondingHandler.sol): open rounds, bond, claim,
warp, change price, discount and vesting, set the vault deficit (`MockSolvencyVault`) and close recovered
rounds as `checkAndAct` would.

| Invariant | What it asserts |
| :-------- | :-------------- |
| `invariant_EscrowCoversUnclaimedSynth` | depository $SYNTH >= promised - claimed |
| `invariant_SupplyEqualsPromised` | `synth.totalSupply()` = total bonded |
| `invariant_ClaimedNeverExceedsPromised` | per position, `claimedSynth <= totalSynth` |
| `invariant_RaisedWithinCap` | current round raise <= its cap, total raise <= sum of caps, vault USDC = total raise |
| `invariant_BondsNeverExceedDeficit` | each bond took `min(amount, cap, deficit)` and the bond that took all of it closed the round |

### Solvency (integration): [`Solvency.invariant.t.sol`](../../test/integration/Solvency.invariant.t.sol)

Driven by [`SolvencyHandler`](../../test/integration/handlers/SolvencyHandler.sol) on the wired
`DeployLib` deployment: LP deposits, simulated trader payouts (`sendPayout`), fee accrual, rescues, bonding,
claims and skims.

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

A selection of the 39 `testFuzz_*` functions, by area.

| Area | Tests | Property |
| :--- | :---- | :------- |
| PnL and payouts | `testFuzz_CloseTrade_PnL`, `testFuzz_ProfitCap`, `testFuzz_OpenTrade` | PnL symmetry, payout cap |
| Liquidations | `testFuzz_Liquidate_TotalConserved`, `testFuzz_Liquidate_ShortRoundingFavorsPool` | Reward plus vault share equals collateral; short rounding favours the pool |
| Opening guard | `testFuzz_Regression_OpenGuard_NoSameBlockLiquidation` | No open position is liquidatable in the same block at the same price |
| Funding | `testFuzz_IndexDeltas_Symmetry`, `testFuzz_IndexDeltas_CreditsNeverExceedCharges`, `testFuzz_IndexDeltas_MonotonicWithTime`, `testFuzz_FundingOwed_LinearWithSize`, `testFuzz_Funding_FundsConservation` | Zero sum at the index level, ceiling, conservation with unbalanced OI (long 1.5x to 10x the short) |
| Spread | `testFuzz_GetSpreadBps_NeverExceedsMax`, `testFuzz_GetSpreadBps_MonotonicInOI` | Cap and monotonicity |
| Vault | `testFuzz_DepositAndWithdraw`, `testFuzz_SendPayout`, `testFuzz_CR_TracksTotalAssets`, `testFuzz_MaxWithdraw_MatchesWithdraw`, `testFuzz_MaxRedeem_MatchesRedeem` | Share accounting, CR, `max*` against their actions |
| Storage | `testFuzz_DeleteTrade_UserListStaysConsistent` | The user's trade list holds exactly the open trades after random deletions |
| Bonding | `testFuzz_Bond_ConservesCapAndInjects`, `testFuzz_Vested_MonotonicAndBounded`, `testFuzz_Claim_NoDustAfterFullVesting` | Vesting bounds, no dust |
| Limit orders | `testFuzz_ExecuteLimit_ConservesFunds` | Executor reward comes from the payout, not the vault |

---

## Unit tests by contract

Counts from `forge test --match-path "test/unit/*" --summary`.

| Contract | Test file | Tests |
| :------- | :-------- | ----: |
| TradingEngine | [`TradingEngine.t.sol`](../../test/unit/TradingEngine.t.sol) | 158 |
| TradingStorage | [`TradingStorage.t.sol`](../../test/unit/TradingStorage.t.sol) | 111 |
| Vault | [`Vault.t.sol`](../../test/unit/Vault.t.sol) | 71 |
| SpreadManager | [`SpreadManager.t.sol`](../../test/unit/SpreadManager.t.sol) | 48 |
| BondDepository | [`BondDepository.t.sol`](../../test/unit/BondDepository.t.sol) | 44 |
| PythChainlinkOracle | [`PythChainlinkOracle.t.sol`](../../test/unit/PythChainlinkOracle.t.sol) | 37 |
| AssistantFund | [`AssistantFund.t.sol`](../../test/unit/AssistantFund.t.sol) | 19 |
| SynthToken | [`SynthToken.t.sol`](../../test/unit/SynthToken.t.sol) | 19 |
| FundingLib | [`FundingLib.t.sol`](../../test/unit/FundingLib.t.sol) | 17 |
| SolvencyManager | [`SolvencyManager.t.sol`](../../test/unit/SolvencyManager.t.sol) | 15 |

### Mocks: [`test/mocks/`](../../test/mocks/)

`MockOracle` (preset prices and confidence, payable fee flow, optional revert), `MockChainlinkFeed`
(configurable answer, decimals, `startedAt` and `updatedAt`; also plays the sequencer uptime feed),
`MockSpreadManager` (fixed spread), `MockSolvencyVault` (settable collateralization deficit for the bonding
tests). `MockUSDC` is defined in each test file.

---

## Fork tests

[`PythChainlinkOracle.fork.t.sol`](../../test/fork/PythChainlinkOracle.fork.t.sol) has 19 tests against
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

The heartbeats come from Chainlink's reference data for Arbitrum One
(`https://reference-data-directory.vercel.app/feeds-ethereum-mainnet-arbitrum-1.json`). The tests cover the
price path for both feeds, the Chainlink deviation (2 BPS for BTC and 1 BPS for ETH at the pinned block),
confidence, staleness after a warp, the update fee (0 wei on Arbitrum One, for empty and real update data),
a recorded signed update taken from the calldata of the updating transaction (verified with
`parsePriceFeedUpdates` and passed through `getPrice`), the sequencer feed (live, and mocked down or in its
grace period), and an open and close through `TradingEngine` on the real oracle.

`FORK_RPC_URL=<arbitrum-one-archive-rpc> forge test --match-path "test/fork/*"`: 19 passed at block
504,522,171. Without `FORK_RPC_URL` the 19 tests skip. Forge loads `.env` from the project root, so mock
mode needs `FORK_RPC_URL` absent or empty.

---

## Gas benchmarks

[`test/gas/GasBenchmarks.t.sol`](../../test/gas/GasBenchmarks.t.sol) records the gas of one successful call
per entry point with `vm.snapshotGasLastCall` into [`snapshots/`](../../snapshots/). The contracts are wired
as in `DeployLib` with the real `PythChainlinkOracle` on `MockPyth` (no Wormhole signature verification, so
the Pyth part costs less than on a live chain), a sequencer uptime feed and the real `SpreadManager`; one
position is already open on the pair.

| Call | Gas (`FOUNDRY_PROFILE=gas forge test`, `snapshots/*.json`) |
| :--- | --: |
| `TradingEngine.openTrade` (with TP and SL) | 325,076 |
| `TradingEngine.closeTrade` (profit) | 166,923 |
| `TradingEngine.liquidate` | 160,049 |
| `TradingEngine.executeLimit` (TP) | 197,611 |
| `Vault.deposit` | 43,300 |
| `Vault.requestWithdrawal` | 63,014 |
| `Vault.executeWithdrawal` | 32,221 |
| `SolvencyManager.checkAndAct` (opens a bonding round) | 62,826 |
| `BondDepository.bond` | 141,854 |

---

## Coverage

From `forge coverage --report summary` (coverage builds disable the optimizer and `viaIR`; the default
profile excludes `test/gas`). The run executed 632 tests: 613 passed, 19 skipped.

| Contract | Lines | Statements | Branches | Functions |
| :------- | :---- | :--------- | :------- | :-------- |
| AssistantFund | 100% (33/33) | 100% (37/37) | 100% (6/6) | 100% (9/9) |
| BondDepository | 100% (93/93) | 94.92% (112/118) | 75.00% (18/24) | 100% (18/18) |
| PythChainlinkOracle | 100% (53/53) | 100% (85/85) | 100% (16/16) | 100% (7/7) |
| SolvencyManager | 100% (32/32) | 100% (45/45) | 100% (6/6) | 100% (4/4) |
| SpreadManager | 100% (54/54) | 100% (58/58) | 100% (13/13) | 100% (12/12) |
| SynthToken | 100% (23/23) | 100% (18/18) | 100% (4/4) | 100% (9/9) |
| TradingEngine | 100% (280/280) | 99.24% (392/395) | 95.65% (66/69) | 100% (41/41) |
| TradingStorage | 100% (132/132) | 100% (139/139) | 100% (33/33) | 100% (30/30) |
| Vault | 98.18% (108/110) | 98.39% (122/124) | 100% (17/17) | 100% (32/32) |
| FundingLib | 100% (16/16) | 100% (28/28) | 100% (4/4) | 100% (3/3) |

The two `Vault` lines reported as not covered are the `return 0` bodies of `maxWithdraw` and `maxRedeem`,
which `test/unit/Vault.t.sol` and `test/regression/WithdrawalRegression.t.sol` call and check. In
`TradingEngine`, the `FeeExceedsCollateral` check cannot be reached while `MAX_LEVERAGE` is 100 (the open fee
is at most 8% of the collateral). The "Total" row of the report (85.13% lines) also counts
`node_modules/`, `script/` and `test/`. Line coverage says a line ran, not that its result was checked.

---

## Static analysis

Raw counts at commit `aaceb08`, not triaged except where noted.

| Tool | Command | Result |
| :--- | :------ | :----- |
| Slither 0.11.6 | `slither . --filter-paths "lib\|node_modules\|test" --json <file>` | 156 results: 0 High, 8 Medium, 20 Low, 128 Informational |
| Aderyn 0.6.8 | `aderyn --src src` | 3 High (13 instances), 5 Low (47 instances) |
| Solhint 6.0.3 | `npx solhint 'src/**/*.sol'` | 517 warnings, 0 errors |

Slither by detector (counted from the JSON `results.detectors[].check`): Medium `incorrect-equality` 3,
`unused-return` 3, `pyth-unchecked-confidence` 1, `reentrancy-no-eth` 1; Low `timestamp` 10,
`reentrancy-events` 5, `calls-loop` 5; Informational `naming-convention` 118, `missing-inheritance` 4,
`unindexed-event-address` 4, `assembly` 2. The `reentrancy-no-eth` result is
`TradingEngine.setFundingFactor`, which calls TradingStorage (owner-set) to accrue every pair before it
writes the new factor; the accrual must use the old factor.

Aderyn: H-1 "Contract locks Ether without a withdraw function" (9 instances, one per contract), H-2
"Reentrancy: State change after external call" (2: `BondDepository.sol:206`, the `view` call to the
vault's `collateralizationDeficit` before `remainingCap` is written, and `TradingEngine.sol:817`,
`setFundingFactor`), H-3 "Unsafe Casting of integers" (2: `BondDepository.sol:223`,
`PythChainlinkOracle.sol:168`); L-1 to L-5 (centralization risk 34, large numeric literal 5, literal
instead of constant 2, modifier invoked once 5, state change without event 1).

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
