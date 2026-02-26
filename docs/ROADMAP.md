# 🗺️ ROADMAP: Synthetic Trading Protocol

**Version:** 1.0
**Purpose:** Ordered implementation guide and progress tracker

---

## 📋 How to use this document

- **[ ]** = Pending
- **[~]** = In progress
- **[x]** = Completed
- **[!]** = Blocked / Requires decision

Each phase should be completed before moving to the next. Within each phase, the order is recommended but can be adjusted based on dependencies.

---

## 📊 Progress Summary

| Phase     | Name                      | Items  | Completed | Progress |
| :-------- | :------------------------ | :----- | :-------- | :------- |
| 0         | Setup & Infrastructure    | 6      | 0         | 0%       |
| 1         | Core: Vault               | 8      | 8         | 100%     |
| 2         | Core: Trading Engine      | 12     | 12        | 100%     |
| 3         | Oracle (Pyth + Chainlink) | 12     | 0         | 0%       |
| 4         | Fee System                | 5      | 0         | 0%       |
| 5         | Funding Rates             | 4      | 0         | 0%       |
| 6         | Risk Control (OI)         | 6      | 0         | 0%       |
| 7         | Liquidations              | 6      | 0         | 0%       |
| 8         | Limit Orders (TP/SL)      | 5      | 0         | 0%       |
| 9         | Solvency (Assistant Fund) | 5      | 0         | 0%       |
| 10        | Solvency (Bonding)        | 6      | 0         | 0%       |
| 11        | Governance Token          | 4      | 0         | 0%       |
| 12        | Testing & Audit           | 8      | 0         | 0%       |
| 13        | V2 Improvements           | 7      | 0         | 0%       |
| **TOTAL** |                           | **94** | **20**    | **21%**  |

---

## Phase 0: Setup & Infrastructure

> **Objective:** Configure the development environment and base project structure.

- [x] **0.1** Initialize Foundry project
- [x] **0.2** Configure dependencies (Solady)
- [x] **0.3** Folder structure (`src/`, `test/`, `script/`)
- [x] **0.4** Configure CI/CD (GitHub Actions for tests)
- [x] **0.5** Setup linters (Solhint, Prettier)
- [x] **0.6** Initial documentation (README, CONTRIBUTING)

**Deliverables:**

- Repository configured and ready for development
- CI pipeline running tests automatically

---

## Phase 1: Core - Vault (ERC-4626)

> **Objective:** Implement the Vault that custodies LP liquidity.
>
> **Dependencies:** Phase 0

- [x] **1.1** Contract `LiquidityVault.sol` (inherits ERC-4626)
- [x] **1.2** Function `deposit()` - LP deposits USDC, receives sToken
- [x] **1.3** Function `redeem()` - LP burns sToken, receives USDC
- [x] **1.4** Function `totalAssets()` - Correct calculation including locked funds
- [x] **1.5** Epoch system for temporal tracking
- [x] **1.6** Withdrawal Request System (3 epoch delay)
- [x] **1.7** Basic Access Control (`onlyTrading` modifier)
- [x] **1.8** Vault unit tests (coverage >95%)

**Deliverables:**

- Functional vault where LPs can deposit/withdraw
- Share price that reflects pool state

**Reference:** [07-vault-ssl.md](./07-vault-ssl.md)

---

## Phase 2: Core - Trading Engine

> **Objective:** Basic logic for opening and closing positions.
>
> **Dependencies:** Phase 1

- [x] **2.1** Contract `TradingStorage.sol` - Struct `Trade`, mappings
- [x] **2.2** Contract `TradingEngine.sol` - Main controller
- [x] **2.3** Struct `Pair` - Trading pair configuration
- [x] **2.4** Basic `openTrade()` function (no fees, no spread)
    - [x] 2.4.1 Validate collateral and leverage
    - [x] 2.4.2 Transfer USDC to TradingStorage
    - [x] 2.4.3 Store trade in Storage
    - [x] 2.4.4 Emit `TradeOpened` event
- [x] **2.5** Basic `closeTrade()` function (no fees)
    - [x] 2.5.1 Verify ownership
    - [x] 2.5.2 Calculate PnL
    - [x] 2.5.3 Request payout from Vault
    - [x] 2.5.4 Delete trade from Storage
    - [x] 2.5.5 Emit `TradeClosed` event
- [x] **2.6** PnL calculation for Long
- [x] **2.7** PnL calculation for Short
- [x] **2.8** Profit Cap (limit gains to 9x)
- [x] **2.9** Function `updateTP()` - Update Take Profit
    - [x] 2.9.1 Validate new TP against current price (not already reached)
- [x] **2.10** Function `updateSL()` - Update Stop Loss
    - [x] 2.10.1 Validate new SL against current price (not already reached)
- [x] **2.11** Pausable (emergency)
- [x] **2.12** Trading engine unit tests (coverage >95%)

**Deliverables:**

- Users can open/close Long and Short trades
- PnL calculated correctly
- Vault pays gains and retains losses

**Reference:** [02-mathematics.md](./02-mathematics.md)

---

## Phase 3: Oracle System (Pyth + Chainlink)

> **Objective:** Integrate Pyth Network as primary price source with Chainlink as deviation anchor.
>
> **Architecture Decision:** Originally designed as a custom DON (6-8 nodes). Migrated to Pyth pull oracle model after analysis — see [03-architecture.md ADR](./03-architecture.md#3-oracle-architecture-decision-record) for full rationale.
>
> **Dependencies:** Phase 2

- [ ] **3.1** Contract `OracleAggregator.sol` (Pyth + Chainlink wrapper)
- [ ] **3.2** Pyth integration (pull model)
    - [ ] 3.2.1 `updatePriceFeeds()` with user-submitted signed data
    - [ ] 3.2.2 `getPriceNoOlderThan()` with staleness check
    - [ ] 3.2.3 Confidence interval validation
- [ ] **3.3** Chainlink integration (deviation anchor only, NOT fallback)
    - [ ] 3.3.1 Read `latestRoundData()` as reference price
    - [ ] 3.3.2 Deviation check: revert if `|pythPrice - chainlinkPrice| > MAX_DEVIATION`
- [ ] **3.4** Price normalization to 18 decimals (Pyth expo + Chainlink 8 dec)
- [ ] **3.5** Pair feed mapping (`pairIndex → pythFeedId + chainlinkFeed`)
- [ ] **3.6** Update TradingEngine to accept `bytes[] calldata priceUpdate` + `payable`
    - [ ] 3.6.1 `openTrade` signature: add `priceUpdate`, remove `_openPrice` param (oracle provides it)
    - [ ] 3.6.2 `closeTrade` signature: add `priceUpdate`, remove `_closePrice` param
    - [ ] 3.6.3 `updateTp`/`updateSl`: add `priceUpdate` to validate TP/SL not already reached at current price
    - [ ] 3.6.4 Forward `msg.value` to OracleAggregator for Pyth update fee
    - [ ] 3.6.5 Refund excess ETH from Pyth fee to `msg.sender`
- [ ] **3.7** Price-dependent validations (deferred from Phase 2)
    - [ ] 3.7.1 Validate TP/SL not already triggered on `openTrade` against execution price (e.g. Long: TP > oraclePrice, SL < oraclePrice)
    - [ ] 3.7.2 Validate TP/SL not already triggered on `updateTp`/`updateSl` against current oracle price — revert in both cases (SL: protects user from keeper executing at worse price; TP: avoids silent instant close, user should raise TP or close at market)
    - [ ] 3.7.3 Reject positions that are pre-liquidable after spread application (loss at entry >= LIQUIDATION_THRESHOLD)
    - [ ] 3.7.4 Dynamic spread on execution price: `P_execution = P_oracle × (1 ± spread)`
    - [ ] 3.7.5 Use confidence interval for conservative pricing on liquidation checks (`price - conf` for longs, `price + conf` for shorts)
- [ ] **3.8** TradingStorage adaptations
    - [ ] 3.8.1 `_validateTp`/`_validateSl` validate against execution price instead of openPrice (or move validation to TradingEngine)
    - [ ] 3.8.2 Evaluate OI tracking: nominal (current: `collateral × leverage`) vs USD-denominated (`collateral × leverage × price / 1e18`)
- [ ] **3.9** Pyth fee handling
    - [ ] 3.9.1 TradingEngine must be `payable` or receive ETH for Pyth fees
    - [ ] 3.9.2 Consider who pays the fee (user via `msg.value`, or protocol treasury)
    - [ ] 3.9.3 `receive()` function if protocol subsidizes fees
- [ ] **3.10** Mock Oracle for local tests (simulates Pyth interface)
- [ ] **3.11** Aggregator tests (staleness, confidence, deviation, edge cases)
- [ ] **3.12** Update TradingEngine tests for oracle integration (mock price feeds, fee forwarding)

**Deliverables:**

- Validated prices from Pyth with sub-second freshness
- Chainlink deviation anchor protects against Pyth anomalies
- Stale Pyth price → revert (no fallback)
- Mock oracle for local development
- All trading functions use oracle-derived prices instead of caller-supplied parameters
- TP/SL validated against live oracle price on set and update

**Reference:** [03-architecture.md](./03-architecture.md) - Oracle System + ADR

---

## Phase 4: Fee System

> **Objective:** Implement fee collection.
>
> **Dependencies:** Phase 2

- [ ] **4.1** Contract `FeeManager.sol` (or integrate in TradingEngine)
- [ ] **4.2** Opening Fee (0.08% of size)
- [ ] **4.3** Closing Fee (0.08% of size)
- [ ] **4.4** Fee distribution (80% Vault, 20% Treasury/Assistant)
- [ ] **4.5** Fee tests (verify correct distribution)

**Deliverables:**

- Fees deducted automatically on open/close
- Vault receives its fee portion
- Treasury/Assistant receives its portion

---

## Phase 5: Funding Rates

> **Objective:** Balance Long/Short positions with funding rates.
>
> **Dependencies:** Phase 2, Phase 4

- [ ] **5.1** Contract `FundingLib.sol` (library)
- [ ] **5.2** Funding Rate calculation based on Long vs Short OI
- [ ] **5.3** Cumulative index (`cumulativeFundingIndex`)
- [ ] **5.4** Apply funding when closing trades (based on time open)

**Deliverables:**

- Funding rate disincentivizes position imbalance
- Traders pay/receive proportional funding

**Reference:** [02-mathematics.md](./02-mathematics.md) - Funding Section

---

## Phase 6: Risk Control (Open Interest)

> **Objective:** Limit protocol exposure based on volatility.
>
> **Dependencies:** Phase 3

- [ ] **6.1** Contract `OIManager.sol`
- [ ] **6.2** Open Interest tracking per pair
- [ ] **6.3** Global Open Interest tracking
- [ ] **6.4** Per-pair volatility (updatable by keeper)
- [ ] **6.5** Dynamic MaxOI calculation based on volatility
- [ ] **6.6** Validation in `openTrade()` against MaxOI

**Deliverables:**

- OI limited automatically
- Higher volatility = lower OI allowed
- New positions blocked if OI exceeds limit

**Reference:** [02-mathematics.md](./02-mathematics.md) - Adaptive OI Section

---

## Phase 7: Liquidations

> **Objective:** Close positions that exceed loss threshold.
>
> **Dependencies:** Phase 3, Phase 6

- [ ] **7.1** Function `liquidate()` in TradingEngine
- [ ] **7.2** Liquidation price calculation
- [ ] **7.3** Liquidation condition verification (loss >= 90%)
- [ ] **7.4** Remaining collateral distribution (liquidator vs vault)
- [ ] **7.5** Liquidator reward (10% of remainder)
- [ ] **7.6** Liquidation tests (edge case fuzzing)

**Deliverables:**

- At-risk positions can be liquidated by anyone
- Liquidators economically incentivized
- Vault protected from bad debt

**Reference:** [02-mathematics.md](./02-mathematics.md) - Liquidations Section

---

## Phase 8: Limit Orders (Automatic TP/SL)

> **Objective:** Automatic execution of Take Profit and Stop Loss.
>
> **Dependencies:** Phase 7

- [ ] **8.1** Function `executeLimit()` in TradingEngine
- [ ] **8.2** Chainlink Automation integration (Keepers)
- [ ] **8.3** TP/SL condition verification
- [ ] **8.4** Access Control for Keepers (`onlyKeeper`)
- [ ] **8.5** Automatic execution tests

**Deliverables:**

- TP/SL executed automatically
- Keepers rewarded for execution

**Reference:** [06-improvements.md](./06-improvements.md) - Advanced Orders Section

---

## Phase 9: Solvency - Assistant Fund

> **Objective:** Capital reserve to cover deficits without token dilution.
>
> **Dependencies:** Phase 4

- [ ] **9.1** Contract `AssistantFund.sol`
- [ ] **9.2** Reception of 20% of fees
- [ ] **9.3** Function `injectFunds()` (only SolvencyManager)
- [ ] **9.4** Balance and target cap tracking
- [ ] **9.5** Assistant Fund tests

**Deliverables:**

- Reserve accumulating fees automatically
- Injection controlled by SolvencyManager

**Reference:** [07-vault-ssl.md](./07-vault-ssl.md)

---

## Phase 10: Solvency - Bonding

> **Objective:** Last resort mechanism for recapitalization.
>
> **Dependencies:** Phase 9, Phase 11

- [ ] **10.1** Contract `BondDepository.sol`
- [ ] **10.2** Contract `SolvencyManager.sol`
- [ ] **10.3** Bond price calculation (TWAP with discount)
- [ ] **10.4** Bond purchase function
- [ ] **10.5** Token vesting (linear or instant)
- [ ] **10.6** Activation logic (CR < threshold)

**Deliverables:**

- Bonds sold at discount during emergency
- USDC raised injected into Vault
- Bondholders receive $SYNTH

**Reference:** [07-vault-ssl.md](./07-vault-ssl.md)

---

## Phase 11: Governance Token ($SYNTH)

> **Objective:** Governance token for incentives and bonding.
>
> **Dependencies:** None (can be done in parallel with Phase 10)

- [ ] **11.1** Contract `SynthToken.sol` (ERC-20)
- [ ] **11.2** Controlled mint (only BondDepository)
- [ ] **11.3** Burn function (for buybacks)
- [ ] **11.4** Token tests

**Deliverables:**

- Functional ERC-20 token
- Minting restricted to authorized contracts

---

## Phase 12: Testing & Audit

> **Objective:** Validate protocol security and correctness.
>
> **Dependencies:** Phases 1-11

- [ ] **12.1** Test coverage >95% on all contracts
- [ ] **12.2** Fuzz testing of all mathematical functions
- [ ] **12.3** Invariant tests (properties that must never break)
    - [ ] 12.3.1 `totalAssets >= 0`
    - [ ] 12.3.2 `globalOI <= maxOI`
    - [ ] 12.3.3 `sharePrice > 0`
- [ ] **12.4** Fork tests against mainnet (real oracles)
- [ ] **12.5** Static analysis (Slither, Aderyn)
- [ ] **12.6** Internal code review
- [ ] **12.7** External audit (reputable firm)
- [ ] **12.8** Audit findings remediation

**Deliverables:**

- Coverage report
- Slither/Aderyn report with no criticals
- External audit report
- All fixes implemented

**Reference:** [08-security.md](./08-security.md)

---

## Phase 13: V2 Improvements (Post-Launch)

> **Objective:** Additional features for growth.
>
> **Dependencies:** Successful V1 launch

- [ ] **13.1** Referral System
- [ ] **13.2** Tiered Fees (volume discounts)
- [ ] **13.3** Liquidation Lookbacks (Phase 2 liquidations)
- [ ] **13.4** Multi-Collateral (ETH, wBTC)
- [ ] **13.5** Copy Trading Vaults
- [ ] **13.6** Account Abstraction (ERC-4337)
- [ ] **13.7** NFT Boost for LPs

**Reference:** [06-improvements.md](./06-improvements.md)

---

## 📝 Changelog

| Date       | Changes                 |
| :--------- | :---------------------- |
| 2026-02-25 | Phase 3: Redesigned oracle from custom DON to Pyth + Chainlink (see ADR) |
| 2026-02-25 | Phase 2: TradingEngine.sol complete (2.2, 2.4-2.11) |
| 2026-02-07 | Phase 2: TradingStorage.sol + Pair struct complete (2.1, 2.3) |
| 2026-02-05 | Initial Roadmap version |

---

## 📚 References

- [Master Index](./INDEX.md)
- [Fundamental Concepts](./01-fundamentals.md)
- [Mathematics](./02-mathematics.md)
- [Technical Architecture](./03-architecture.md)
- [Trade-offs and Problems](./04-tradeoffs.md)
- [Solidity Implementation](./05-implementation.md)
- [Suggested Improvements](./06-improvements.md)
- [Vault SSL](./07-vault-ssl.md)
- [Security](./08-security.md)
