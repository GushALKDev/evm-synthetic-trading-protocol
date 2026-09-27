# Test Suite

**Status:** Proof of concept. Not audited and not deployed.

All numbers below were measured on 2026-09-28 from a clean `git clone --recursive` at commit `f89ca0c`
after `npm ci`, with forge 1.7.1 and solc 0.8.24, and without `FORK_RPC_URL` set. Later documentation
commits do not change `src/` or `test/`.

| Group | Location | Tests | Command that counts them |
| :---- | :------- | ----: | :----------------------- |
| Unit | `test/unit/` | 506 | `forge test --match-path "test/unit/*" --summary` |
| Integration | `test/integration/Solvency.integration.t.sol` | 17 | `forge test --match-path "test/integration/*" --summary` |
| Invariant (integration) | `test/integration/Solvency.invariant.t.sol` | 6 | same as above |
| Invariant | `test/invariant/` | 11 | `forge test --match-path "test/invariant/*" --summary` |
| Fork | `test/fork/` | 13 | skipped without `FORK_RPC_URL` |
| **Total** | | **553** | `forge test --list --json 2>/dev/null \| jq '[.[][][]] \| length'` |

`forge test` result in mock mode: 540 passed, 0 failed, 13 skipped.

Across these groups there are 35 functions named `testFuzz_*` (32 in unit files and 3 in the integration
file); no other test function takes parameters and 17 stateful invariant functions (`invariant_*`). Count them with:

```bash
forge test --list --json 2>/dev/null | jq '[.[][][] | select(startswith("testFuzz_"))] | length'   # 35
forge test --list --json 2>/dev/null | jq '[.[][][] | select(startswith("invariant_"))] | length'  # 17
```

`foundry.toml` has no `[fuzz]` or `[invariant]` section, so Foundry defaults apply: 256 runs per fuzz test,
and 256 runs of 500 calls per invariant (forge reports 128,000 calls per invariant function).

```bash
forge test                                    # everything (fork tests skip without FORK_RPC_URL)
forge test --match-path "test/integration/*"  # integration only
forge test --match-path "test/invariant/*"    # invariants only
forge test --match-test testFuzz              # fuzz only
FORK_RPC_URL=<hyperevm-rpc> forge test --match-path "test/fork/*"
forge coverage --report summary
```

---

## Integration tests

The unit suite tests each contract in isolation; `SolvencyManager` in particular runs against a
`MockVault`. The integration suite deploys the real contracts through `DeployLib` in
[`script/Deploy.s.sol`](../../script/Deploy.s.sol), the same code the deploy script uses. It does not
deploy a `TradingEngine` with trades: trader payouts are simulated by calling `Vault.sendPayout` from the
engine address.

### [`Solvency.integration.t.sol`](../../test/integration/Solvency.integration.t.sol): 17 tests

| Group | Covers |
| :---- | :----- |
| Wiring | Cross-contract permissions are granted and `treasury` points at the AssistantFund |
| Healthy / Warning | `checkAndAct` does nothing at or above 100% CR and does not spend reserve in the 100% to 110% band |
| Layer 2 | Reserve injection restores CR without opening a bonding round when it is enough |
| Layer 3 | Bonding opens for the shortfall, closes when the cap is used up, and does not stack rounds |
| Full cycle | Drain, rescue, bond, vest, claim, ending at 100% CR |
| Total insolvency | Regression tests for the division by zero described below |
| Fuzz (3) | `testFuzz_CheckAndAct_NeverWorsensCR`, `testFuzz_Injection_BoundedByDeficitAndReserve`, `testFuzz_Bonding_AlwaysRestoresToTarget` |

### [`Solvency.invariant.t.sol`](../../test/integration/Solvency.invariant.t.sol): 6 invariant functions

Driven by [`SolvencyHandler`](../../test/integration/handlers/SolvencyHandler.sol), which interleaves LP
deposits, simulated trader payouts, fee accrual (`deal`), rescues, bonding, claims and skims.

| Invariant | What it asserts |
| :-------- | :-------------- |
| `invariant_RescueAlwaysCallable` | Calls `checkAndAct` and asserts `deficitToTarget` is at most the nominal liabilities (`totalSupply / 1e12`) |
| `invariant_EscrowSolventUnderFullSystem` | Depository $SYNTH balance covers unclaimed vesting |
| `invariant_SynthSupplyOnlyFromBonding` | $SYNTH supply equals the amount the handler bonded |
| `invariant_ReserveNeverExceedsCapAfterSkim` | Calls `skim` and asserts the reserve is at most `targetCap` |
| `invariant_RescueNeverOvershootsWildly` | CR stays below 100x (`assertLt(cr, 100 * WAD)`); a loose bound |
| `invariant_CallSummary` | Logs call counts, asserts nothing |

---

## Invariant suites

Each invariant is checked after every call of a random sequence produced by a handler that only issues
calls expected to succeed.

### Protocol: [`Protocol.invariant.t.sol`](../../test/invariant/Protocol.invariant.t.sol)

Driven by [`ProtocolHandler`](../../test/invariant/handlers/ProtocolHandler.sol) with `MockOracle` and
`MockSpreadManager(5)`. Actions: deposit, open (leverage 1 to 50, collateral 10 to 5,000 USDC, no TP/SL),
close, liquidate, move the price within 30% of 50,000, and warp 1 minute to 7 days. It does not cover
`executeLimit`, withdrawals, pausing or admin changes.

| Invariant | What it asserts | Notes |
| :-------- | :-------------- | :---- |
| `invariant_TotalAssetsBackedByBalance` | `vault.totalAssets() == usdc.balanceOf(vault)` | Always true by construction: Solady's `totalAssets()` returns that balance |
| `invariant_OpenInterestWithinMax` | Long OI and short OI are each `<= maxOI` | The contract caps long + short together, which is stronger than what this checks |
| `invariant_SharePricePositive` | `convertToAssets(1e18) > 0` while shares exist | |
| `invariant_StorageCoversOpenCollateral` | TradingStorage USDC `>=` sum of open collateral tracked by the handler | |
| `invariant_SharesBackedByAssets` | Non-zero share supply implies non-zero assets | |
| `invariant_CallSummary` | Logs call counts | Asserts nothing |

### Bonding: [`Bonding.invariant.t.sol`](../../test/invariant/Bonding.invariant.t.sol)

Driven by [`BondingHandler`](../../test/invariant/handlers/BondingHandler.sol): open rounds, bond, claim,
warp and change price, discount and vesting through the admin setters.

| Invariant | What it asserts |
| :-------- | :-------------- |
| `invariant_EscrowCoversUnclaimedSynth` | Depository $SYNTH balance `>=` promised minus claimed |
| `invariant_SupplyEqualsPromised` | `synth.totalSupply()` equals the total bonded |
| `invariant_ClaimedNeverExceedsPromised` | Per position, `claimedSynth <= totalSynth` |
| `invariant_RaisedWithinCap` | Vault USDC equals the USDC the handler bonded (the name suggests a cap check; the cap itself is not asserted) |
| `invariant_CallSummary` | Logs call counts, asserts nothing |

There is no invariant that ties vault assets, open trader collateral, open PnL and fees together.

---

## Fuzz tests

| Area | Tests | Property |
| :--- | :---- | :------- |
| PnL and payouts | `testFuzz_CloseTrade_PnL`, `testFuzz_ProfitCap`, `testFuzz_OpenTrade` | PnL symmetry, payout cap |
| Liquidations | `testFuzz_Liquidate_TotalConserved`, `testFuzz_Liquidate_ShortRoundingFavorsPool` | Reward plus vault share equals collateral; short rounding favours the pool |
| Funding | `testFuzz_IndexDelta_Symmetry`, `testFuzz_FundingOwed_LongShortOpposite`, `testFuzz_Funding_FundsConservation` | Per unit of size, longs and shorts owe opposite amounts; total USDC is conserved. The conservation test opens equal long and short sizes, so the index does not move and no funding is exchanged |
| Spread | `testFuzz_GetSpreadBps_NeverExceedsMax`, `testFuzz_GetSpreadBps_MonotonicInOI` | Cap and monotonicity |
| Vault | `testFuzz_DepositAndWithdraw`, `testFuzz_SendPayout`, `testFuzz_CR_TracksTotalAssets` | Share accounting and CR |
| Bonding | `testFuzz_Bond_ConservesCapAndInjects`, `testFuzz_Vested_MonotonicAndBounded`, `testFuzz_Claim_NoDustAfterFullVesting` | Vesting bounds, no dust |
| Limit orders | `testFuzz_ExecuteLimit_ConservesFunds` | Executor reward comes from the payout, not the vault |

---

## Unit tests by contract

Counts from `forge test --match-path "test/unit/*" --summary`.

| Contract | Test file | Tests |
| :------- | :-------- | ----: |
| TradingEngine | [`TradingEngine.t.sol`](../../test/unit/TradingEngine.t.sol) | 149 |
| TradingStorage | [`TradingStorage.t.sol`](../../test/unit/TradingStorage.t.sol) | 111 |
| Vault | [`Vault.t.sol`](../../test/unit/Vault.t.sol) | 62 |
| SpreadManager | [`SpreadManager.t.sol`](../../test/unit/SpreadManager.t.sol) | 48 |
| BondDepository | [`BondDepository.t.sol`](../../test/unit/BondDepository.t.sol) | 38 |
| PythChainlinkOracle | [`PythChainlinkOracle.t.sol`](../../test/unit/PythChainlinkOracle.t.sol) | 31 |
| AssistantFund | [`AssistantFund.t.sol`](../../test/unit/AssistantFund.t.sol) | 19 |
| SynthToken | [`SynthToken.t.sol`](../../test/unit/SynthToken.t.sol) | 19 |
| FundingLib | [`FundingLib.t.sol`](../../test/unit/FundingLib.t.sol) | 16 |
| SolvencyManager | [`SolvencyManager.t.sol`](../../test/unit/SolvencyManager.t.sol) | 13 |

### Mocks: [`test/mocks/`](../../test/mocks/)

`MockOracle` (preset prices and confidence, payable fee flow, optional revert), `MockChainlinkFeed`
(configurable answer, decimals and timestamp), `MockSpreadManager` (fixed spread). `MockUSDC` is defined
in each test file.

---

## Fork tests

[`PythChainlinkOracle.fork.t.sol`](../../test/fork/PythChainlinkOracle.fork.t.sol) has 13 tests. It
hardcodes the Pyth contract and two Chainlink aggregators on HyperEVM, forks the latest block of
`FORK_RPC_URL` (the block is not pinned and no variable pins it), and fetches Pyth updates from the Hermes
API through `ffi` (`curl` piped into `python3`; `ffi = true` is set in `foundry.toml`).

Without `FORK_RPC_URL` the tests skip. In this review the Hermes endpoint returned HTTP 401 and no
HyperEVM RPC was available, so the fork results could not be reproduced.

---

## Coverage

From `forge coverage --report summary` (coverage builds disable the optimizer and `viaIR`).

| Contract | Lines | Statements | Branches | Functions |
| :------- | :---- | :--------- | :------- | :-------- |
| AssistantFund | 100% (33/33) | 100% (37/37) | 100% (6/6) | 100% (9/9) |
| BondDepository | 100% (86/86) | 94.44% (102/108) | 72.73% (16/22) | 100% (17/17) |
| PythChainlinkOracle | 100% (40/40) | 100% (63/63) | 100% (11/11) | 100% (5/5) |
| SolvencyManager | 100% (29/29) | 100% (40/40) | 100% (5/5) | 100% (4/4) |
| SpreadManager | 100% (54/54) | 100% (58/58) | 100% (13/13) | 100% (12/12) |
| SynthToken | 100% (23/23) | 100% (18/18) | 100% (4/4) | 100% (9/9) |
| TradingEngine | 100% (264/264) | 97.58% (363/372) | 90.14% (64/71) | 100% (36/36) |
| TradingStorage | 100% (130/130) | 100% (134/134) | 100% (31/31) | 100% (30/30) |
| Vault | 100% (93/93) | 100% (102/102) | 100% (15/15) | 100% (28/28) |
| FundingLib | 100% (7/7) | 100% (5/5) | 100% (2/2) | 100% (2/2) |

The "Total" row of the report (81.30% lines) is lower because it also counts `node_modules/`, `script/`
and `test/`. Line coverage says a line ran, not that its result was checked.

---

## Static analysis

Raw counts from this review, run in the repository checkout at commit `f89ca0c`. The findings have not been
triaged in this round.

| Tool | Command | Result |
| :--- | :------ | :----- |
| Slither 0.11.6 | `slither . --filter-paths "lib\|node_modules\|test"` | 141 results: 0 High, 6 Medium, 14 Low, 121 Informational |
| Aderyn 0.6.8 | `aderyn --src src` | 2 High, 7 Low |

Slither by detector: `incorrect-equality` 3, `pyth-unchecked-confidence` 1, `unused-return` 2 (Medium);
`timestamp` 9, `reentrancy-events` 5 (Low); `naming-convention` 113, `missing-inheritance` 4,
`unindexed-event-address` 4 (Informational). Aderyn: H-1 "Contract locks Ether without a withdraw
function" (9 instances), H-2 "Unsafe Casting of integers" (2 instances: `BondDepository.sol:215`,
`PythChainlinkOracle.sol:136`), and L-1 to L-7.

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

---

## Related

- [ROADMAP](../ROADMAP.md)
- [Security](../08-security.md)
- [Vault and solvency](../07-vault-ssl.md)
