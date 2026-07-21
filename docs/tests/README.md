# 🧪 Test Suite

> ⚠️ **DISCLAIMER:** This is a **Proof of Concept with an educational purpose**. It has **not been
> audited by an external firm** and **must not be used in production** or with real funds.

**553 tests** across unit, fuzz, invariant, integration and fork suites. This document explains what
each group covers, why it exists, which invariant it belongs to, and links to the code.

| Suite       | File                                             | Tests | Purpose                                      |
| :---------- | :----------------------------------------------- | ----: | :------------------------------------------- |
| Unit        | [`test/unit/`](../../test/unit/)                 |   474 | Per-contract behaviour and access control    |
| Integration | [`test/integration/`](../../test/integration/)   |    23 | The full wired system, end to end            |
| Invariant   | [`test/invariant/`](../../test/invariant/)       |    11 | Properties that must never break             |
| Fork        | [`test/fork/`](../../test/fork/)                 |    13 | Real Pyth + Chainlink feeds on mainnet       |
| Fuzz        | spread across suites (`testFuzz_*`)              |    36 | Randomized inputs over financial math        |

```bash
forge test                                    # everything
forge test --match-path "test/integration/*"  # integration only
forge test --match-path "test/invariant/*"    # invariants only
forge test --match-test testFuzz              # fuzz only
FORK_RPC_URL=<rpc> forge test --match-path "test/fork/*"   # fork (skipped without the env var)
forge coverage                                # coverage report
```

---

## 🔗 Integration Tests

The unit suites test each contract in isolation — `SolvencyManager` in particular runs against a
`MockVault` — so nothing there proves the layers actually **compose**. The integration suite deploys
the real contracts through [`DeployLib`](../../script/Deploy.s.sol), the same code the deploy script
uses, so the tested topology is the deployed topology.

### [`Solvency.integration.t.sol`](../../test/integration/Solvency.integration.t.sol) — 17 tests

| Group | Covers |
| :---- | :----- |
| Wiring | Every cross-contract permission is granted, and `treasury` points at the AssistantFund so the fee split actually funds the reserve |
| Healthy / Warning | `checkAndAct` is a no-op above 100% CR and never spends reserve in the 100–110% warning band |
| Layer 2 | Reserve injection restores CR without opening a round when it suffices |
| Layer 3 | Bonding opens for the exact shortfall, closes when the cap is exhausted, and does not stack rounds |
| Full cycle | Drain → rescue → bond → vest → claim, ending at 100% CR |
| Total insolvency | Regression for the division-by-zero bug below |
| Fuzz | `checkAndAct` never worsens CR nor overshoots; injection is bounded by both the deficit and the reserve; a full round always restores solvency |

### [`Solvency.invariant.t.sol`](../../test/integration/Solvency.invariant.t.sol) — 6 invariants

Driven by [`SolvencyHandler`](../../test/integration/handlers/SolvencyHandler.sol), which interleaves
LP deposits, trader payouts, fee accrual, rescues, bonding, claims and skims against the live system.

| Invariant | What it guarantees |
| :-------- | :----------------- |
| `invariant_RescueAlwaysCallable` | `deficitToTarget` stays well-defined and `checkAndAct` never reverts — **in any reachable state, including total insolvency** |
| `invariant_EscrowSolventUnderFullSystem` | The vesting escrow covers unclaimed positions even while rescues and payouts churn around it |
| `invariant_SynthSupplyOnlyFromBonding` | $SYNTH is only ever minted by bonding, across rescue cycles |
| `invariant_ReserveNeverExceedsCapAfterSkim` | Reserve overflow above `targetCap` is always recoverable to the Vault |
| `invariant_RescueNeverOvershootsWildly` | A rescue never inflates CR far past its target |

---

## 🔒 Invariants (Roadmap 12.3)

Invariants are properties asserted after **every** step of a random action sequence. Each suite runs
256 sequences × 500 calls ≈ **128,000 calls per invariant**. All state changes go through a handler
that only issues valid calls, so a revert would mean a real bug rather than a bad input.

### Protocol — [`Protocol.invariant.t.sol`](../../test/invariant/Protocol.invariant.t.sol)

Driven by [`ProtocolHandler`](../../test/invariant/handlers/ProtocolHandler.sol), which deposits,
opens, closes, liquidates, moves the oracle price (±30%) and warps time.

| Invariant | Roadmap | What it guarantees | Why it matters |
| :-------- | :------ | :----------------- | :------------- |
| [`invariant_TotalAssetsBackedByBalance`](../../test/invariant/Protocol.invariant.t.sol) | **12.3.1** | `vault.totalAssets() == USDC balance` | `totalAssets` is balance-based; any drift means the Vault promises LPs liquidity it does not hold. |
| [`invariant_OpenInterestWithinMax`](../../test/invariant/Protocol.invariant.t.sol) | **12.3.2** | Long and short OI each stay `<= pair.maxOI` | The OI cap bounds the Vault's worst-case payout. Breaching it is unbounded risk for LPs. |
| [`invariant_SharePricePositive`](../../test/invariant/Protocol.invariant.t.sol) | **12.3.3** | `convertToAssets(1e18) > 0` while shares exist | A zero share price breaks deposit/withdraw math (division by zero, infinite mint). |
| [`invariant_StorageCoversOpenCollateral`](../../test/invariant/Protocol.invariant.t.sol) | custody | TradingStorage holds `>=` the collateral owed to open trades | Trader collateral lives in TradingStorage, never the Vault. A shortfall means a trader cannot be paid on close. |
| [`invariant_SharesBackedByAssets`](../../test/invariant/Protocol.invariant.t.sol) | custody | Non-zero share supply implies non-zero assets | The insolvency end-state; would let the next depositor mint against an empty Vault. |

### Bonding — [`Bonding.invariant.t.sol`](../../test/invariant/Bonding.invariant.t.sol)

Driven by [`BondingHandler`](../../test/invariant/handlers/BondingHandler.sol), which opens rounds,
bonds, claims, warps time and re-prices via the admin setters.

| Invariant | What it guarantees | Why it matters |
| :-------- | :----------------- | :------------- |
| [`invariant_EscrowCoversUnclaimedSynth`](../../test/invariant/Bonding.invariant.t.sol) | Depository $SYNTH balance `>=` promised − claimed | $SYNTH is minted into escrow at bond time. Below this, a bonder's `claim()` reverts and their USDC bought nothing. |
| [`invariant_SupplyEqualsPromised`](../../test/invariant/Bonding.invariant.t.sol) | `synth.totalSupply() == total bonded` | Minting is minter-gated to the depository. A larger supply means an unaccounted mint path. |
| [`invariant_ClaimedNeverExceedsPromised`](../../test/invariant/Bonding.invariant.t.sol) | Per position, `claimedSynth <= totalSynth` | Guards linear-vesting accounting from paying beyond the bond. |
| [`invariant_RaisedWithinCap`](../../test/invariant/Bonding.invariant.t.sol) | Vault USDC equals the tracked raise | `bond()` clamps to the round cap; over-raising would dilute $SYNTH beyond the approved deficit. |

> `invariant_CallSummary` in both suites is not an assertion — it prints how often each action ran, so
> a silently idle suite (everything reverting, nothing asserted) is visible instead of passing vacuously.

---

## 🎲 Fuzz Tests (Roadmap 12.2)

Randomized inputs over the financial math, where off-by-one and rounding errors hide.

| Area | Representative tests | Property under test |
| :--- | :------------------- | :------------------ |
| PnL & payouts | `testFuzz_CloseTrade_PnL`, `testFuzz_ProfitCap`, `testFuzz_OpenTrade` | PnL is symmetric and the 9× profit cap always binds. |
| Liquidations | `testFuzz_Liquidate_TotalConserved`, `testFuzz_Liquidate_ShortRoundingFavorsPool` | Reward + Vault share always equals collateral; rounding never favours the trader. |
| Funding | `testFuzz_IndexDelta_Symmetry`, `testFuzz_FundingOwed_LongShortOpposite`, `testFuzz_Funding_FundsConservation` | Longs and shorts pay exact opposites; funding is zero-sum. |
| Spread | `testFuzz_GetSpreadBps_NeverExceedsMax`, `testFuzz_GetSpreadBps_MonotonicInOI` | Spread is monotonic in OI/volatility and never exceeds `maxSpreadBps`. |
| Vault | `testFuzz_DepositAndWithdraw`, `testFuzz_SendPayout`, `testFuzz_CR_TracksTotalAssets` | Share accounting round-trips; CR tracks `totalAssets` exactly. |
| Bonding | `testFuzz_Bond_ConservesCapAndInjects`, `testFuzz_Vested_MonotonicAndBounded`, `testFuzz_Claim_NoDustAfterFullVesting` | Vesting is monotonic, bounded by the total, and leaves no dust. |
| Limit orders | `testFuzz_ExecuteLimit_ConservesFunds` | Executor reward is carved from the payout, never from the Vault. |

---

## 📋 Unit Tests by Contract

| Contract | Test file | Tests | Focus |
| :------- | :-------- | ----: | :---- |
| TradingEngine | [`TradingEngine.t.sol`](../../test/unit/TradingEngine.t.sol) | 141 | Open/close, liquidation, limit orders, fees, funding, spread, slippage, pause |
| TradingStorage | [`TradingStorage.t.sol`](../../test/unit/TradingStorage.t.sol) | 107 | Trade CRUD, OI tracking, custody, pair config, access control |
| Vault | [`Vault.t.sol`](../../test/unit/Vault.t.sol) | 58 | ERC-4626 accounting, 3-epoch withdrawal lock, payouts, CR, pause |
| SpreadManager | [`SpreadManager.t.sol`](../../test/unit/SpreadManager.t.sol) | 43 | Spread formula, volatility bounds, keeper and admin setters |
| BondDepository | [`BondDepository.t.sol`](../../test/unit/BondDepository.t.sol) | 35 | Rounds, pricing, discount caps, linear vesting, claims |
| PythChainlinkOracle | [`PythChainlinkOracle.t.sol`](../../test/unit/PythChainlinkOracle.t.sol) | 30 | Staleness, confidence, deviation anchor, normalization |
| AssistantFund | [`AssistantFund.t.sol`](../../test/unit/AssistantFund.t.sol) | 18 | Reserve injection, permissionless skim, access control |
| SynthToken | [`SynthToken.t.sol`](../../test/unit/SynthToken.t.sol) | 18 | Minter gating, burn/burnFrom, supply invariants |
| FundingLib | [`FundingLib.t.sol`](../../test/unit/FundingLib.t.sol) | 12 | Index delta and funding-owed math |
| SolvencyManager | [`SolvencyManager.t.sol`](../../test/unit/SolvencyManager.t.sol) | 12 | CR thresholds, reserve-then-bonding routing, deficit math |

### Mocks — [`test/mocks/`](../../test/mocks/)

`MockOracle` (preset prices + confidence, payable fee flow), `MockChainlinkFeed` (configurable answer
and staleness), `MockSpreadManager` (fixed spread). `MockUSDC` is duplicated per test file by design,
so suites stay independent.

---

## 🌐 Fork Tests (Roadmap 12.4)

[`PythChainlinkOracle.fork.t.sol`](../../test/fork/PythChainlinkOracle.fork.t.sol) — 13 tests against
**real mainnet Pyth and Chainlink feeds**, fetching live Hermes price updates. They validate what
mocks cannot: real exponents (`-8`), real confidence bands, real cross-oracle deviation, and 18-decimal
normalization against actual BTC/ETH prices.

Requires `FORK_RPC_URL`; without it the tests **skip** (they do not fail), which is how CI runs them.

---

## 📊 Coverage (Roadmap 12.1)

**100% line coverage on all 9 `src/` contracts.** The repository-wide percentage is lower only
because `forge coverage` also counts `node_modules/` (Pyth SDK) and test mocks.

| Contract | Lines | Branches |
| :------- | :---- | :------- |
| AssistantFund | 100% | 100% |
| BondDepository | 100% | 75% |
| PythChainlinkOracle | 100% | 100% |
| SolvencyManager | 100% | 100% |
| SpreadManager | 100% | 100% |
| SynthToken | 100% | 100% |
| TradingEngine | 100% | 90% |
| TradingStorage | 100% | 100% |
| Vault | 100% | 100% |

---

## 🔍 Static Analysis (Roadmap 12.5)

| Tool | Result |
| :--- | :----- |
| **Slither** 0.11.3 | **No criticals or highs.** Remaining findings are naming-convention noise (the `_param` / `IMMUTABLE` conventions are deliberate) plus documented false positives. |
| **Aderyn** 0.6.8 | 2 "High" findings, both reviewed and dismissed — see below. |

```bash
slither . --filter-paths "lib|node_modules|test"
aderyn --src src
```

### Findings review

| Finding | Verdict |
| :------ | :------ |
| Slither `pyth-unchecked-confidence` | **False positive.** Confidence *is* validated in [`PythChainlinkOracle.sol`](../../src/PythChainlinkOracle.sol) before use; the detector does not recognise the pattern. |
| Slither `unused-return` (Chainlink) | **False positive.** `answer` and `updatedAt` are consumed; the ignored fields (`roundId`, `answeredInRound`) are deprecated. |
| Slither `unused-return` (TradingEngine) | **Intentional.** `conf18` is deliberately discarded on open/close — the conservative band applies only to liquidation (Phase 7.7). |
| Slither `missing-zero-check` (`Vault._asset`) | **Fixed.** A zero-address check was added to the `Vault` constructor, matching every other contract. |
| Aderyn H-1 "locks Ether" | **False positive.** Flags all 9 contracts for being `Ownable`; only the oracle receives ETH and it already refunds the surplus. |
| Aderyn H-2 "unsafe cast" | **Not reachable.** Overflowing `uint128(synthOut)` would need a ~3.4e14 USDC round, far above USDC's total supply. Documented inline in `BondDepository.bond()`. |

### 🐛 Bugs found and fixed during this phase

#### 2. Division by zero in `SolvencyManager` — the rescue was uncallable when most needed

Found by the **integration invariants**, not by any unit test: `SolvencyManager` is unit-tested
against a `MockVault`, so this state was unreachable there.

When the Vault is fully drained (`totalAssets == 0` with shares outstanding), `collateralizationRatio`
returns 0. The deficit was computed as `totalAssets * (WAD - cr) / cr` → **panic `0x12`**. The
permissionless `checkAndAct` reverted, so the Layer 2/3 rescue could not be invoked **precisely in the
total-insolvency scenario the solvency system exists to resolve**. The stale comment in the code even
asserted this was impossible.

Fixed by deriving the deficit from the nominal deposit basis instead
(`Vault.collateralizationDeficit()`), which is arithmetically equivalent while the Vault holds assets
and stays well-defined at zero. Regression tests: `test_TotalInsolvency_RescueStillCallable`,
`test_TotalInsolvency_DeficitEqualsNominalLiabilities` and `test_TotalInsolvency_BondingRestoresFromZero`.

#### 1. Division by zero in `BondDepository`

Static analysis led to a **real division-by-zero** in `BondDepository`:

`setReferencePrice` only rejected `0`, but the discount is applied with integer division
(`referencePrice * (10000 - discountBps) / 10000`). A small enough price floored the effective price
to zero, so `quoteBond` panicked (`0x12`) and **every bond reverted — bricking the recapitalization
round exactly when the protocol needs it**.

Fixed by validating the *computed* effective price (not just the input) in both `setReferencePrice`
and `setDiscountBps`, via the new `EffectivePriceZero` error. Regression tests:
`test_SetReferencePrice_EffectivePriceZeroReverts` and
`test_SetReferencePrice_QuoteStillWorksAfterRejectedPrice` in
[`BondDepository.t.sol`](../../test/unit/BondDepository.t.sol).

---

## 🔗 Related

- [ROADMAP](../ROADMAP.md) — Phase 12 items and progress
- [Security](../08-security.md) — threat model and invariant rationale
- [Vault SSL Architecture](../07-vault-ssl.md) — 3-layer solvency the invariants protect
