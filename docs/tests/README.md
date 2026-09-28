# Test Suite

**Status:** Proof of concept. Not audited and not deployed.

All numbers below were measured on 2026-09-28 at commit `2e390d7` (branch `fix/open-pnl-nav`) after
`npm ci`, with forge 1.7.1 and solc 0.8.24. Mock-mode numbers are taken with `FORK_RPC_URL` empty; later
commits only change documentation.

| Group | Location | Tests | Command that counts them |
| :---- | :------- | ----: | :----------------------- |
| Unit | `test/unit/` | 599 | `forge test --match-path "test/unit/*" --summary` |
| Regression (round 2 and 2b findings) | `test/regression/` | 50 | `forge test --match-path "test/regression/*" --summary` |
| Integration | `test/integration/Solvency.integration.t.sol` | 17 | `forge test --match-path "test/integration/*" --summary` |
| Invariant (integration) | `test/integration/Solvency.invariant.t.sol` | 8 | same as above |
| Invariant | `test/invariant/` | 21 | `forge test --match-path "test/invariant/*" --summary` |
| Fork | `test/fork/` | 19 | skipped without `FORK_RPC_URL` |
| **Total (correctness)** | | **714** | `forge test --list --json 2>/dev/null \| jq '[.[][][]] \| length'` |
| Gas benchmarks (not counted above) | `test/gas/` | 14 | `FOUNDRY_PROFILE=gas forge test --list --json 2>/dev/null \| jq '[.[][][]] \| length'` |

`FORK_RPC_URL= forge test` (mock mode): 695 passed, 0 failed, 19 skipped (the fork suite).

There are 45 functions named `testFuzz_*` and 29 stateful invariant functions (`invariant_*`). Count them
with:

```bash
forge test --list --json 2>/dev/null | jq '[.[][][] | select(startswith("testFuzz_"))] | length'   # 45
forge test --list --json 2>/dev/null | jq '[.[][][] | select(startswith("invariant_"))] | length'  # 29
```

`foundry.toml` has no `[fuzz]` or `[invariant]` section, so Foundry defaults apply: 256 runs per fuzz test,
and 256 runs of 500 calls per invariant (forge reports 128,000 calls per invariant function). The default
profile skips `test/gas`; the `gas` profile runs only it.

```bash
forge test                                    # correctness suite (fork tests skip without FORK_RPC_URL)
forge test --match-path "test/regression/*"   # regression tests
forge test --match-path "test/invariant/*"    # invariants
FORK_RPC_URL=<arbitrum-one-archive-rpc> forge test --match-path "test/fork/*"
FOUNDRY_PROFILE=gas forge test                # gas benchmarks, written to snapshots/*.json
FOUNDRY_PROFILE=coverage forge coverage --report summary
```

**Coverage profile.** The default profile builds with the optimizer (200 runs) and keeps the EIP-170
contract size limit, which `forge build --sizes` enforces in CI. `forge coverage` compiles without the
optimizer, where contracts are larger, so `foundry.toml` has a `coverage` profile that only raises
`code_size_limit`; run coverage with `FOUNDRY_PROFILE=coverage`. Do not pass `--no-match-path` on the command
line: it replaces the profile's `no_match_path` and runs the gas benchmarks, which rewrite
`snapshots/*.json`.

---

## Regression tests (rounds 2 and 2b)

One file per finding, in [`test/regression/`](../../test/regression/). The tests named `test_Regression_*`
and `testFuzz_Regression_*` failed against the code before their fix (the failing output is in the round 2
and round 2b reports); the other tests in these files pass before and after. Most use only functions that
existed before the fix, so they compile against it; new functions are called with low-level calls and new
errors are matched by selector literal.

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
| `MaxPairsRegression.t.sol` | No bound on the number of pairs the PnL snapshot iterates (2b) | 1 |
| `OpenPnlNavRegression.t.sol` | Share price ignored unrealised trader PnL; stale snapshot; payout check against the NAV (2b) | 7 |
| `DepositCoverageRegression.t.sol` | Deposits below 100% coverage took part of the next injection (2b) | 5 |
| `SolvencySplitRegression.t.sol` | Bonding on an unrealised move; bond clamp and round close on the realised ratio; injection on a stale snapshot (2b) | 4 |

---

## Invariant suites

Each invariant is checked after every call of a random sequence. Call summaries are logged from
`afterInvariant` hooks (forge prints the last run's logs with `-vv`), not from invariant functions.

### Protocol: [`Protocol.invariant.t.sol`](../../test/invariant/Protocol.invariant.t.sol)

Deploys the engine, storage, vault, `AssistantFund` (as treasury), `SolvencyManager`, `BondDepository` and
`SynthToken` with `MockOracle` and `MockSpreadManager(5)`; the vault starts with 1,000,000 USDC. Two
handlers:

- [`ProtocolHandler`](../../test/invariant/handlers/ProtocolHandler.sol): open (collateral 10 to 5,000
  USDC, leverage 1 to 100, optional TP/SL), close, liquidate, `executeLimit`, `updateTp`, `updateSl`, and
  `refreshSnapshot`. It models every settlement from the documented formulas and compares the trader and
  keeper payouts with the model. `closeTrade`, `liquidate` and `executeLimit` revert when they settle
  nothing, so in the metrics table below calls minus reverts is the number of settlements. At each refresh
  it rebuilds the open totals position by position and checks the snapshot against them (exact), and checks
  the conservativeness bound below with the excess loss `E` as a ghost variable.
- [`LiquidityHandler`](../../test/invariant/handlers/LiquidityHandler.sol): deposit, withdrawal request,
  execution and cancellation, epoch advance, warp (1 minute to 1 day), price moves up or down by up to 5%
  per call within 60% to 140% of 50,000, pause and unpause of the engine or the vault, `checkAndAct`,
  `bond`, `skim`. Each flow is modelled before the call and compared with the measured amount. `deposit`,
  `executeWithdrawal` and `checkAndAct` take a mode seed: act on the current snapshot (possibly stale),
  refresh first, or go through the refresh-and-act entry point. A deposit or execution rejected for a
  documented reason (paused, stale snapshot, coverage below 100%, nothing to execute) ends with
  `NotExecuted`, so calls minus reverts is the number that went through; an unexpected revert counts as a
  mismatch.

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
| `invariant_RescueNeverOvershootsTarget` | the NAV ratio after an injection that raised it, and the realised ratio after a bond that raised it, are <= 100% |
| `invariant_SharePricePositive` | `convertToAssets(1e18) > 0` while shares exist |
| `invariant_SharesBackedByAssets` | shares outstanding imply assets > 0 |
| `invariant_TotalAssetsIsBalanceMinusSnapshotLiability` | `totalAssets` = max(balance - max(0, snapshot), 0), and the balance while no trade is open |
| `invariant_OpenTotalsMatchPositions` | per side, size, collateral and quantity aggregates = the sums over open positions, exactly; open trade count = open positions |
| `invariant_SnapshotMatchesBruteForceAndIsConservative` | at every refresh: snapshot = `toUsdcUp(pairPnl(brute-force totals))` exactly, and L <= max(0, snapshot) + E, where L is the positive part of the sum of per-position PnL capped at 8x collateral and floored at minus collateral, and E the excess loss of positions past 100% loss (tolerance 0) |
| `invariant_NoDepositBelowParOrStaleAction` | no deposit went through with the coverage ratio below 100%; no deposit or withdrawal execution went through on a stale snapshot |
| `invariant_BondingNeverStartsAboveCriticalRealisedRatio` | no `checkAndAct` opened a bonding round with the realised ratio at or above 95% |

Call distribution for the `invariant_VaultBalanceMatchesModelledFlows` campaign (256 runs x 500 calls),
from `FOUNDRY_INVARIANT_SHOW_METRICS=true forge test --match-contract ProtocolInvariantTest --match-test invariant_VaultBalanceMatchesModelledFlows -vv`
(forge runs one campaign per invariant function; the other campaigns are within a few percent):

| Handler | Action | Calls | Reverts | Went through |
| :------ | :----- | ----: | ------: | ------: |
| ProtocolHandler | openTrade | 7,110 | 0 | |
| ProtocolHandler | closeTrade | 7,060 | 3,391 | 3,669 |
| ProtocolHandler | liquidate | 7,219 | 6,629 | 590 |
| ProtocolHandler | executeLimit | 7,077 | 6,846 | 231 |
| ProtocolHandler | updateTp / updateSl | 7,028 / 7,126 | 0 / 0 | |
| ProtocolHandler | refreshSnapshot | 7,141 | 0 | 7,141 |
| LiquidityHandler | deposit | 7,006 | 4,768 | 2,238 |
| LiquidityHandler | executeWithdrawal | 7,016 | 6,888 | 128 |
| LiquidityHandler | requestWithdrawal / cancelWithdrawal | 7,101 / 7,292 | 0 | |
| LiquidityHandler | advanceEpoch / warp / movePrice / togglePause | 7,169 / 7,277 / 7,070 / 7,113 | 0 | |
| LiquidityHandler | checkAndAct / bond / skim | 7,088 / 7,126 / 6,981 | 0 | |

Of the 4,490 settlements, 590 (13.1%) were liquidations, 3,669 (81.7%) closes and 231 (5.1%) TP/SL
executions. `deposit` reverts with `NotExecuted` while the vault is paused, the snapshot is stale or the
coverage ratio is below 100%; `executeWithdrawal` when no request is in its execution window or the
snapshot is stale.
The last run's log of that campaign reports 20 refreshes with a largest excess loss `E` of 0; an earlier
run of the same campaign on commit `c3d552a` (same `src/` and `test/invariant/`) logged a largest `E` of
8,259.96 USD at a refresh, so the conservativeness bound is also checked with `E > 0`, and
`test_TotalAssets_UnderwaterPositionOffsetsWinnerWithinSide` builds that case on purpose. The
handler liquidates a random position per call, so a liquidatable payer can stay open for days of warps,
which leaves unpaid funding: the residual described in
[Guide 2](../02-mathematics.md#residual-funding-a-payer-cannot-pay).

Mutation checks: each of these temporary changes to `src/` made at least one invariant fail with 20 runs of
200 calls (`FOUNDRY_INVARIANT_RUNS=20 FOUNDRY_INVARIANT_DEPTH=200 forge test --match-contract ProtocolInvariantTest`):
funding applied before the 9x cap (`FlowsMatchModel`, `VaultBalanceMatchesModelledFlows`), liquidator
reward without its floor (same two), receivers credited 1% more than payers pay
(`FundingCreditsNeverExceedCharges`, `VaultFundingExposureBoundedByBadDebt`). `bond()` without the
deficit clamp made `BondsNeverExceedDeficit` (bonding suite) and `VaultBalanceMatchesModelledFlows`
(solvency suite) fail with 100 runs.

Round 2b mutation checks, each with the default configuration and
`forge test --match-contract ProtocolInvariantTest --match-test <invariant>`: deposits without the coverage
check (`NoDepositBelowParOrStaleAction`: `deposit below 100% coverage: 1 != 0`), bonding triggered on the
NAV ratio (`BondingNeverStartsAboveCriticalRealisedRatio`: `1 != 0`), quantity removed with the short
rounding for longs (`OpenTotalsMatchPositions`: `long quantity: 1 != 0`), and the snapshot halved
(`SnapshotMatchesBruteForceAndIsConservative`: `snapshot differs from the brute-force valuation: 1 != 0`).

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

A selection of the 45 `testFuzz_*` functions, by area.

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
| Open PnL math | `testFuzz_Quantity_LongAtMostOneAboveShort`, `testFuzz_SidePnl_OverstatesPerPositionSum`, `testFuzz_PairPnl_AtLeastAnyPriceInBand` | Rounding direction, aggregate at least the per-position sum, band edge choice (2 wei tolerance) |
| Open PnL aggregates | `testFuzz_Aggregates_NoDriftAfterManyOpensAndCloses` | Totals return exactly to the brute-force sums after random opens and closes |
| NAV | `testFuzz_PreviewsMatchActionsAtNav`, `testFuzz_Ratios_RealisedAtLeastNav` | `previewDeposit`/`previewMint` equal `deposit`/`mint` with a fresh snapshot; realised ratio >= NAV ratio |

---

## Unit tests by contract

Counts from `forge test --match-path "test/unit/*" --summary`.

| Contract | Test file | Tests |
| :------- | :-------- | ----: |
| TradingEngine | [`TradingEngine.t.sol`](../../test/unit/TradingEngine.t.sol) | 158 |
| TradingStorage | [`TradingStorage.t.sol`](../../test/unit/TradingStorage.t.sol) | 117 |
| Vault | [`Vault.t.sol`](../../test/unit/Vault.t.sol) | 71 |
| Vault (NAV, snapshot, ratios) | [`VaultNav.t.sol`](../../test/unit/VaultNav.t.sol) | 35 |
| SpreadManager | [`SpreadManager.t.sol`](../../test/unit/SpreadManager.t.sol) | 48 |
| BondDepository | [`BondDepository.t.sol`](../../test/unit/BondDepository.t.sol) | 44 |
| PythChainlinkOracle | [`PythChainlinkOracle.t.sol`](../../test/unit/PythChainlinkOracle.t.sol) | 37 |
| SolvencyManager | [`SolvencyManager.t.sol`](../../test/unit/SolvencyManager.t.sol) | 23 |
| AssistantFund | [`AssistantFund.t.sol`](../../test/unit/AssistantFund.t.sol) | 19 |
| SynthToken | [`SynthToken.t.sol`](../../test/unit/SynthToken.t.sol) | 19 |
| FundingLib | [`FundingLib.t.sol`](../../test/unit/FundingLib.t.sol) | 17 |
| OpenPnlLib | [`OpenPnlLib.t.sol`](../../test/unit/OpenPnlLib.t.sol) | 11 |

### Mocks: [`test/mocks/`](../../test/mocks/)

`MockOracle` (preset prices and confidence, payable fee flow, optional revert), `MockChainlinkFeed`
(configurable answer, decimals, `startedAt` and `updatedAt`; also plays the sequencer uptime feed),
`MockSpreadManager` (fixed spread), `MockSolvencyVault` (settable realised collateralization deficit for the
bonding tests). `MockUSDC` is defined in each test file. `MockOracle` charges its fee on every call, so the
multi-pair refresh tests run it with a zero fee; the gas benchmark at `MAX_PAIRS` uses the real oracle.

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
position is already open on the pair, so `deposit`, `executeWithdrawal` and `checkAndAct` run after a
snapshot refresh that is not measured. The build uses the optimizer with 200 runs.

| Call | Gas (`FOUNDRY_PROFILE=gas forge test`, `snapshots/*.json`) |
| :--- | --: |
| `TradingEngine.openTrade` (with TP and SL) | 298,003 |
| `TradingEngine.closeTrade` (profit) | 129,571 |
| `TradingEngine.liquidate` | 126,939 |
| `TradingEngine.executeLimit` (TP) | 158,702 |
| `Vault.deposit` | 49,605 |
| `Vault.refreshAndDeposit` | 171,080 |
| `Vault.requestWithdrawal` | 61,840 |
| `Vault.executeWithdrawal` | 33,076 |
| `Vault.refreshAndExecuteWithdrawal` | 156,588 |
| `Vault.refreshPnlSnapshot`, 1 pair | 126,621 |
| `Vault.refreshPnlSnapshot`, 20 pairs (`MAX_PAIRS`), a long and a short on each | 640,239 |
| `SolvencyManager.checkAndAct` (injects the reserve and opens a bonding round) | 66,562 |
| `SolvencyManager.refreshAndCheckAndAct` (same path) | 199,194 |
| `BondDepository.bond` | 137,962 |

---

## Coverage

From `FORK_RPC_URL= FOUNDRY_PROFILE=coverage forge coverage --report summary` (coverage builds disable the
optimizer and `viaIR`; the profile excludes `test/gas`). The run executed 714 tests: 695 passed, 19 skipped.

| Contract | Lines | Statements | Branches | Functions |
| :------- | :---- | :--------- | :------- | :-------- |
| AssistantFund | 100% (33/33) | 100% (37/37) | 100% (6/6) | 100% (9/9) |
| BondDepository | 100% (93/93) | 94.92% (112/118) | 75.00% (18/24) | 100% (18/18) |
| PythChainlinkOracle | 100% (53/53) | 100% (85/85) | 100% (16/16) | 100% (7/7) |
| SolvencyManager | 100% (44/44) | 100% (57/57) | 100% (10/10) | 100% (6/6) |
| SpreadManager | 100% (54/54) | 100% (58/58) | 100% (13/13) | 100% (12/12) |
| SynthToken | 100% (23/23) | 100% (18/18) | 100% (4/4) | 100% (9/9) |
| TradingEngine | 100% (280/280) | 99.24% (392/395) | 95.65% (66/69) | 100% (41/41) |
| TradingStorage | 100% (153/153) | 100% (159/159) | 100% (34/34) | 100% (34/34) |
| Vault | 98.99% (196/198) | 99.17% (240/242) | 100% (27/27) | 100% (50/50) |
| FundingLib | 100% (16/16) | 100% (28/28) | 100% (4/4) | 100% (3/3) |
| OpenPnlLib | 100% (21/21) | 100% (32/32) | 100% (5/5) | 100% (4/4) |

The two `Vault` lines reported as not covered are the `return 0` bodies of `maxWithdraw` and `maxRedeem`
(the `DA` entries with 0 hits in `FORK_RPC_URL= FOUNDRY_PROFILE=coverage forge coverage --report lcov`),
which `test/unit/Vault.t.sol` and `test/regression/WithdrawalRegression.t.sol` call and check. In
`TradingEngine`, the `FeeExceedsCollateral` check cannot be reached while `MAX_LEVERAGE` is 100 (the open fee
is at most 8% of the collateral). The "Total" row of the report (86.39% lines) also counts
`node_modules/`, `script/` and `test/`. Line coverage says a line ran, not that its result was checked.

---

## Static analysis

Raw counts, not triaged except where noted. They were run at commit `c3d552a`; the only later change to code
is a test file, outside the analysed paths (`src/` for Aderyn, `test` filtered out for Slither).

| Tool | Command | Result |
| :--- | :------ | :----- |
| Slither 0.11.6 | `slither . --filter-paths "lib\|node_modules\|test" --json <file>` | 197 results: 4 High, 16 Medium, 43 Low, 134 Informational |
| Aderyn 0.6.8 | `aderyn --src src` | 3 High (14 instances), 6 Low (53 instances) |

Slither by detector (counted from the JSON with `jq -r '.results.detectors[] | "\(.impact) \(.check)"' <file> | sort | uniq -c`):
High `msg-value-loop` 4; Medium `incorrect-equality` 6, `unused-return` 5, `uninitialized-local` 3,
`pyth-unchecked-confidence` 1, `reentrancy-no-eth` 1; Low `timestamp` 19, `calls-loop` 17,
`reentrancy-events` 6, `reentrancy-benign` 1; Informational `naming-convention` 122, `assembly` 4,
`missing-inheritance` 4, `unindexed-event-address` 4. The four `msg-value-loop` results are the same line of
`Vault._refreshPnlSnapshot`, reached from its four callers: `msg.value` goes only to the first priced pair
(a flag skips it afterwards), which the gas benchmark at `MAX_PAIRS` exercises by paying the fee for 20
feeds once. The `reentrancy-no-eth` result is `TradingEngine.setFundingFactor`, which calls TradingStorage
(owner-set) to accrue every pair before it writes the new factor; the accrual must use the old factor.

Aderyn: H-1 "Contract locks Ether without a withdraw function" (9 instances), H-2 "Reentrancy: State
change after external call" (2: `BondDepository.sol:207`, the `view` call to the vault's
`realisedCollateralizationDeficit` before `remainingCap` is written, and `TradingEngine.sol:817`,
`setFundingFactor`), H-3 "Unsafe Casting of integers" (3: `BondDepository.sol:224`,
`PythChainlinkOracle.sol:168`, `Vault.sol:279`, the constant 60 cast to `uint32`); L-1 to L-6
(centralization risk 35, large numeric literal 5, literal instead of constant 6, modifier invoked once 5,
state change without event 1, uninitialized local variable 1).

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
