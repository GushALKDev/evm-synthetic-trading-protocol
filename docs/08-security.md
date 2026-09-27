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
| Trader | Untrusted | Open and close own trades, choose the Pyth update within the staleness window, set TP/SL |
| LP | Untrusted | Deposit, request and execute withdrawals, time entries and exits |
| Liquidator / executor bot | Untrusted | Call `liquidate` and `executeLimit` on any trade, choose the Pyth update |
| Volatility keeper | Trusted for spread input | Set per-pair volatility within the relative change bound |
| Owner (one per contract) | Fully trusted | See section 2; can redirect all funds |
| Pyth publishers, Wormhole, Chainlink | Trusted for prices | Prices that pass the oracle checks are used as is |
| Bonder | Untrusted | Buy discounted $SYNTH during a round |

### Assets

| Asset | Location | Protection in code |
|:---|:---|:---|
| LP USDC | `Vault.sol` | `sendPayout` only by `tradingEngine`; withdrawals through requests |
| Trader collateral | `TradingStorage.sol` | `sendCollateral` only by `tradingEngine` |
| Reserve USDC | `AssistantFund.sol` | `injectFunds` only by `solvencyManager`; `skim` only to the vault |
| Trade and pair data | `TradingStorage.sol` | Writes only by `tradingEngine` or the owner |
| Prices | `PythChainlinkOracle.sol` | Staleness, confidence, Chainlink deviation and heartbeat checks |
| $SYNTH supply | `SynthToken.sol` | `mint` only by `minter` |

---

## 2. Access Control as Implemented

Every contract inherits Solady `Ownable` (single owner, two-step handover available through Solady).
There are no roles, no multisig requirement and no timelock in code.

### Vault

| Function | Caller | Pause |
|:---|:---|:---|
| `deposit`, `mint` | Anyone | Blocked when paused |
| `requestWithdrawal` | Share holder | Blocked when paused |
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
| `setTreasury`, `pause`, `unpause` | Owner | |

### TradingStorage

All state-changing functions except the admin ones are `onlyTradingEngine`. Owner: `setTradingEngine`,
`addPair`, `updatePair`. No pause.

### Other contracts

| Contract | Restricted function | Caller |
|:---|:---|:---|
| `PythChainlinkOracle` | `setPairFeed` | Owner |
| `SpreadManager` | `updateVolatility` | Keeper |
| `SpreadManager` | `setBaseSpreadBps`, `setImpactFactor`, `setVolFactor`, `setMaxSpreadBps`, `setMaxVolatilityChangeBps`, `setKeeper` | Owner |
| `AssistantFund` | `injectFunds` | SolvencyManager |
| `AssistantFund` | `setSolvencyManager`, `setTargetCap` | Owner |
| `SolvencyManager` | none (`checkAndAct` is public) | |
| `BondDepository` | `activateBonding` | SolvencyManager |
| `BondDepository` | `setSolvencyManager`, `setReferencePrice`, `setDiscountBps`, `setVestingPeriod` | Owner |
| `SynthToken` | `mint` | Minter |
| `SynthToken` | `setMinter` | Owner |

### What the owner can do

- Set `tradingEngine` on the vault and on storage to any address, which can then transfer all LP USDC and
  all trader collateral.
- Set the $SYNTH minter to any address, which can mint without limit.
- Set oracle feeds, spread parameters and keeper, pair leverage and OI caps, the treasury, the reserve cap,
  and bond price, discount and vesting.
- Pause trading (liquidations continue) and the vault.

---

## 3. Invariants in the Test Suite

Stateful invariants that exist (`invariant_*` functions, 17 in total, 3 of which only log):

| Suite | Invariant | Property asserted |
|:---|:---|:---|
| Protocol | `invariant_TotalAssetsBackedByBalance` | `totalAssets() == USDC balance` (true by construction in Solady) |
| Protocol | `invariant_OpenInterestWithinMax` | Long OI and short OI each `<= maxOI` |
| Protocol | `invariant_SharePricePositive` | `convertToAssets(1e18) > 0` while shares exist |
| Protocol | `invariant_StorageCoversOpenCollateral` | Storage USDC `>=` sum of open collateral |
| Protocol | `invariant_SharesBackedByAssets` | Shares outstanding implies assets `> 0` |
| Bonding | `invariant_EscrowCoversUnclaimedSynth` | Depository $SYNTH `>=` unclaimed vesting |
| Bonding | `invariant_SupplyEqualsPromised` | $SYNTH supply equals total bonded |
| Bonding | `invariant_ClaimedNeverExceedsPromised` | `claimedSynth <= totalSynth` per position |
| Bonding | `invariant_RaisedWithinCap` | Vault USDC equals USDC bonded |
| Solvency (integration) | `invariant_RescueAlwaysCallable` | Deficit `<=` nominal liabilities and `checkAndAct` does not revert |
| Solvency (integration) | `invariant_EscrowSolventUnderFullSystem` | Escrow covers unclaimed vesting |
| Solvency (integration) | `invariant_SynthSupplyOnlyFromBonding` | Supply equals bonded total |
| Solvency (integration) | `invariant_ReserveNeverExceedsCapAfterSkim` | After `skim`, reserve `<= targetCap` |
| Solvency (integration) | `invariant_RescueNeverOvershootsWildly` | CR `< 100x` |

Properties that are **not** checked by any invariant:

- Vault assets plus open collateral cover open trader PnL plus fees owed (no invariant links vault,
  collateral, open PnL and fees).
- Funding paid and received stays within a bounded rate.
- A position whose loss reaches the threshold can always be liquidated with a positive reward.
- Withdrawal requests delay every exit.
- Total OI across pairs stays below a global limit (there is no global limit).

The protocol handler never calls `executeLimit`, withdrawals, pause or admin functions, and uses a fixed
5 BPS mock spread and a mock oracle.

---

## 4. Attack Vectors

### 4.1 Reentrancy

`TradingEngine.openTrade`, `closeTrade`, `liquidate`, `executeLimit` and the vault's deposit, mint,
withdrawal-request, withdrawal-execution and payout functions are `nonReentrant`. USDC transfers happen
after the trade is deleted and OI is reduced. `updateTp`/`updateSl` are not guarded; they refund ETH to the
caller after updating storage. The oracle is an owner-configured external contract called before state
changes.

### 4.2 Oracle manipulation and price choice

Pyth updates are verified on-chain and checked for staleness (30 s), confidence (2%) and deviation from
Chainlink (3%). The caller still chooses which valid update to submit, as long as it is newer than the one
stored on-chain. See [Guide 4](./04-tradeoffs.md#1-latency-arbitrage). The oracle design note is in
[Guide 3](./03-architecture.md#3-oracle-design-note).

### 4.3 Latency arbitrage

Open with an older update, close with a newer one; no minimum holding time. The round-trip cost with the
deploy parameters is about 26 BPS of notional.

### 4.4 LP timing

- Withdrawal requests do not expire, so after 3 epochs an LP can exit at any time, including just before a
  known trader profit is realised.
- Deposits are immediate, so a new LP can enter just before a known trader loss or a reserve injection.
- The share price ignores unrealised PnL, which makes both of the above visible from public state.

### 4.5 Liquidation incentives

The liquidator reward is at most 1% of collateral and zero once the loss reaches the full collateral. A
user with many open trades makes each of their liquidations more expensive, because `deleteTrade` searches
the user's trade array linearly. There is no limit on trades per user.

### 4.6 Funding

The funding rate scales with the absolute USD imbalance and is not normalised; see
[Guide 2](./02-mathematics.md#6-funding). Combined with the zero reward past 100% loss, this can move value
from the vault to positions on the lighter side.

### 4.7 Solvency layers

`checkAndAct` is permissionless and acts only below 100% CR. Anyone depositing when the share price is
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

| Item | State |
|:---|:---|
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
