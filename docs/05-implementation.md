# Guide 5: Solidity Implementation

**Prerequisites:** [Guide 4: Trade-offs and Risks](./04-tradeoffs.md)
**Next:** [Guide 6: Future Improvements](./06-improvements.md)

**Status:** Proof of concept. Not audited and not deployed.

This guide describes the code as it is. Earlier versions of this file contained design-time sketches
(role-based access control, a `receiveLoss` vault function, WAD-based PnL); none of that was built, and it
has been replaced by the actual structures.

---

## Table of Contents

1. [Tech Stack](#1-tech-stack)
2. [Data Structures](#2-data-structures)
3. [Interfaces](#3-interfaces)
4. [Code Patterns](#4-code-patterns)
5. [Numerical Precision and Rounding](#5-numerical-precision-and-rounding)
6. [Before Any Deployment](#6-before-any-deployment)

---

## 1. Tech Stack

| Component | Version or setting | Source |
|:---|:---|:---|
| Solidity | 0.8.24, fixed by `pragma solidity 0.8.24;` in every file | `src/`, `test/`, `script/` |
| Foundry | forge 1.7.1 used in this review; CI installs the `stable` toolchain | `.github/workflows/test.yml` |
| Solady | v0.1.26 (git submodule) | `foundry.lock`, `.gitmodules` |
| forge-std | v1.14.0 (git submodule) | `foundry.lock`, `.gitmodules` |
| Pyth SDK | `@pythnetwork/pyth-sdk-solidity` `^4.3.1` (npm), remapped from `node_modules/`; `npm ci` is required before `forge build` | `package.json`, `foundry.toml` |
| Formatter | `forge fmt`, `line_length = 160` | `foundry.toml` `[fmt]` |

`foundry.toml` sets `ffi = false`, the optimizer with 200 runs and `evm_version = "cancun"` (the engine and
the vault keep their ETH refund baseline in transient storage), excludes `test/gas` from the default profile
(a `gas` profile runs only the gas benchmarks), and has a `coverage` profile that lifts the contract size
limit for coverage builds only. It does not set `solc` or `via_ir`.

The Pyth SDK stays on npm because there is no tagged Solidity SDK repository to use as a submodule:

- `pyth-network/pyth-sdk-solidity` is archived (last commit 2025-05-06, "Add deprecation notices"); its
  newest tag, `v2.2.0`, has no `PythUtils.sol`, which `PythChainlinkOracle` uses
  (`gh api repos/pyth-network/pyth-sdk-solidity --jq .archived`,
  `gh api "repos/pyth-network/pyth-sdk-solidity/contents/PythUtils.sol?ref=v2.2.0"` returns 404).
- The SDK now lives in the `pyth-network/pyth-crosschain` monorepo, none of whose 1,037 tags is a
  Solidity SDK tag
  (`gh api --paginate 'repos/pyth-network/pyth-crosschain/git/matching-refs/tags/' --jq '.[].ref' | grep -ciE "solidity"`
  prints 0).

Solady modules used: `ERC4626`, `ERC20`, `Ownable`, `ReentrancyGuard`, `SafeTransferLib`, `SafeCastLib`.
OpenZeppelin is not a dependency.

---

## 2. Data Structures

### Trade (`TradingStorage.sol`), 3 slots

```solidity
struct Trade {
    address user; //      20 bytes -┐
    bool isLong; //        1 byte   │
    uint16 pairIndex; //   2 bytes  │  Slot 0 (31/32)
    uint16 leverage; //    2 bytes  │
    uint48 timestamp; //   6 bytes -┘
    uint32 index; //       4 bytes -┐
    uint32 userIndex; //   4 bytes  │  Slot 1 (full)
    uint64 collateral; //  8 bytes  │
    uint128 openPrice; // 16 bytes -┘
    uint128 tp; //        16 bytes -┐  Slot 2 (full)
    uint128 sl; //        16 bytes -┘
}
```

- `collateral` is the stored collateral after the open fee (USDC, 6 decimals).
- `openPrice`, `tp`, `sl` are 18-decimal prices; `openPrice` includes the open spread.
- `user == address(0)` marks a deleted or nonexistent trade. Trade IDs come from a `uint32` counter and
  are never reused.
- `userIndex` is the trade's position in its user's list, so `deleteTrade` removes it in constant time.
- The entry funding index (of the trade's side) is stored separately in
  `mapping(uint256 => int256) _tradeFundingIndex`.

### Pair (`TradingStorage.sol`), 2 slots

```solidity
struct Pair {
    string name; //       32 bytes -── Slot 0 (pointer)
    uint128 maxOI; //     16 bytes -┐
    uint16 maxLeverage; // 2 bytes  │  Slot 1 (19/32)
    bool isActive; //      1 byte  -┘
}
```

### PairFeed (`PythChainlinkOracle.sol`), 2 slots

```solidity
struct PairFeed {
    bytes32 pythFeedId; //       32 bytes -── Slot 0 (full)
    address chainlinkFeed; //    20 bytes -┐
    uint32 chainlinkHeartbeat; // 4 bytes  │  Slot 1 (25/32)
    bool active; //               1 byte  -┘
}
```

### SideTotals (`TradingStorage.sol`), 1 slot per pair and side

```solidity
struct SideTotals {
    uint128 collateral; // 16 bytes -┐  Slot 0 (full)
    uint128 quantity; //   16 bytes -┘
}
```

`_longTotals` and `_shortTotals` map a pair index to its totals; the side size is the existing open
interest mapping. `quantity` is the sum of `size_wad x 1e18 / openPrice` over the side's positions, rounded
up per long and down per short, in WAD asset units. `_openTradeCount` and `_positionsNonce` (both `uint32`)
share slot 0 with `tradingEngine` and `_tradeCounter`; every `storeTrade` and `deleteTrade` increments the
nonce.

### PnlSnapshot (`Vault.sol`), 1 slot

```solidity
struct PnlSnapshot {
    int128 netPnl; //   16 bytes -┐
    uint48 timestamp; // 6 bytes  │  Slot 0 (26/32)
    uint32 nonce; //     4 bytes -┘
}
```

`netPnl` is USDC (6 decimals), positive when traders are in profit. `maxPnlSnapshotAge` (`uint32`) shares a
slot with `tradingEngine`, `pauseFlags` (`uint8`) and `_withdrawPausedSince` (`uint48`); `_withdrawPausedTotal`
(`uint64`) shares a slot with `solvencyManager`.

### WithdrawalRequest (`Vault.sol`), 2 slots

```solidity
struct WithdrawalRequest {
    uint256 shares; //                  32 bytes -── Slot 0 (full)
    uint128 requestEpoch; //            16 bytes -┐  Slot 1 (full)
    uint128 withdrawPausedAtRequest; // 16 bytes -┘
}
```

One request per address. The requested shares are held by the vault (escrow); a new request returns the
previous escrow and replaces the request. `withdrawPausedAtRequest` is the number of seconds the vault had
spent under `PAUSE_WITHDRAW` when the request was made; the time paused since then extends the request's
expiry ([Guide 8, section 5](./08-security.md#5-pause-flags)).

### BondPosition (`BondDepository.sol`), 2 slots

```solidity
struct BondPosition {
    uint128 totalSynth;
    uint128 claimedSynth;
    uint64 start;
    uint64 end;
}
```

A bonder can hold several positions (`mapping(address => BondPosition[])`).

---

## 3. Interfaces

### IOracle

```solidity
interface IOracle {
    function getPrice(uint256 pairIndex, bytes[] calldata priceData) external payable returns (uint128 price18, uint128 conf18);

    function checkOpenAllowed() external view;
}
```

`checkOpenAllowed` reverts when conditions outside the price do not allow new positions; `openTrade` calls it
(the sequencer grace period in `PythChainlinkOracle`). `priceData` is opaque update data for pull oracles. The caller pays any fee in `msg.value` and the oracle
refunds the surplus to `msg.sender`. `TradingEngine` stores the oracle as an immutable, so replacing it
requires a new engine deployment.

### ISolvency (`ISolvencyVault`, `IAssistantFund`, `IBondDepository`)

Minimal views and calls used by `SolvencyManager` and `BondDepository`: `collateralizationRatio()`,
`collateralizationDeficit()`, `realisedCollateralizationRatio()`, `realisedCollateralizationDeficit()`,
`isPnlSnapshotFresh()`, `refreshPnlSnapshot(bytes[])` (payable), `totalAssets()`, `balance()`,
`injectFunds(uint256)`, `isActive()`, `activateBonding(uint256)`, `closeBonding()`. `ISolvencyManager`: `checkAndActBeforeDeposit()` and
`bondingRoundOpenAfterCheck()`, which the Vault calls on its deposit paths and in `maxDeposit`/`maxMint`.

### ISynthToken

`mint(address to, uint256 amount)`, used by `BondDepository`.

### AggregatorV3Interface

Local copy of the Chainlink aggregator interface (`latestRoundData`, `decimals`).

### TradingEngine external functions

```solidity
function openTrade(uint16 pairIndex, bool isLong, uint64 collateral, uint16 leverage, uint128 expectedPrice, uint16 slippageBps, uint128 tp, uint128 sl, bytes[] calldata priceUpdate) external payable returns (uint32 tradeId);
function closeTrade(uint256 tradeId, uint128 expectedPrice, uint16 slippageBps, bytes[] calldata priceUpdate) external payable;
function liquidate(uint256 tradeId, bytes[] calldata priceUpdate) external payable;
function executeLimit(uint256 tradeId, bytes[] calldata priceUpdate) external payable;
function updateTp(uint256 tradeId, uint128 newTp, bytes[] calldata priceUpdate) external payable;
function updateSl(uint256 tradeId, uint128 newSl, bytes[] calldata priceUpdate) external payable;
```

Slippage: `abs(executionPrice - expectedPrice) * 10000 <= expectedPrice * slippageBps`.

TP/SL: `openTrade`, `updateTp` and `updateSl` reject a TP or SL that is already crossed at the oracle
price; `TradingStorage` also checks it against the open price (long `tp > openPrice`, `sl < openPrice`;
short the reverse).

---

## 4. Code Patterns

- **Custom errors with parameters**, no revert strings, for example
  `error LeverageExceedsMax(uint16 leverage, uint16 maxLeverage);` and
  `error MaxOpenInterestExceeded(uint256 newOI, uint128 maxOI);`.
- **Access control:** Solady `Ownable` in every contract, plus single-address gates implemented as a
  modifier that calls an internal check, for example:

  ```solidity
  modifier onlyTradingEngine() {
      _requireTradingEngine();
      _;
  }

  function _requireTradingEngine() internal view {
      if (msg.sender != tradingEngine) revert CallerNotTradingEngine();
  }
  ```

  Gates: `TradingStorage.onlyTradingEngine`, `Vault.sendPayout` (inline check), `SpreadManager.onlyKeeper`,
  `AssistantFund.onlySolvencyManager`, `BondDepository.onlySolvencyManager`, `SynthToken.onlyMinter`.
- **Pause:** `TradingEngine` (`PAUSE_OPEN`, `PAUSE_SETTLE`) and `Vault` (`PAUSE_DEPOSIT`, `PAUSE_WITHDRAW`)
  each keep a `uint8 pauseFlags` set by `setPauseFlags`; `whenNotPaused(flag)` calls `_requireNotPaused(flag)`,
  which reverts with `EnforcedPause(flag)`. `TradingStorage` has no pause: the engine's flags decide when
  collateral moves.
- **Reentrancy:** Solady `ReentrancyGuard` on `TradingEngine.openTrade`, `closeTrade`, `liquidate`,
  `executeLimit`, `updateTp`, `updateSl` and on `Vault.deposit`, `mint`, `requestWithdrawal`,
  `executeWithdrawal`, `sendPayout`.
- **ETH refunds:** the `refundsEthSurplus` modifier stores `balance - msg.value` in transient storage at
  entry (`tstore`, EVM `cancun`) and refunds `balance - baseline` at the end of the call.
  `TradingStorage` has none: all its mutating functions are restricted to the engine.
- **Ordering:** in the engine, the trade is deleted and OI reduced before USDC is transferred. The oracle
  and the funding-state update in `TradingStorage` are called before that.
- **Token transfers:** `SafeTransferLib` (`safeTransfer`, `safeTransferFrom`, `safeTransferETH`).

---

## 5. Numerical Precision and Rounding

| Quantity | Decimals | Notes |
|:---|:---|:---|
| USDC amounts (collateral, fees, PnL, payouts) | 6 | PnL is computed in USDC units directly |
| sUSDC shares | 18 | `_decimalsOffset() = 12` |
| Prices (oracle, open, TP, SL) | 18 | Pyth normalised with `PythUtils.convertToUint`; Chainlink scaled by `10 ** (18 - decimals)` |
| Open interest, position size for OI | 18 | `collateral * leverage * 1e12` |
| Funding index | 18 (signed), one per side | `FundingLib`; funding owed is `size x delta / 1e30` in USDC units |
| Volatility | 18 | 3% = `3e16` |
| Open PnL quantity (`SideTotals.quantity`) | 18 | asset units, `size_wad x 1e18 / openPrice` |
| PnL snapshot (`PnlSnapshot.netPnl`) | 6 (signed) | rounded toward plus infinity |
| Collateralization ratios (NAV and realised) | 18 | 1e18 = 100% |
| Percentages | BPS | 10,000 = 100% |

PnL (`TradingEngine._calculatePnl`):

```solidity
uint256 size = uint256(_collateral) * uint256(_leverage);
if (_isLong) {
    // Floor exitValue: larger loss for the trader, rounding favours the pool
    uint256 exitValue = (uint256(_closePrice) * size) / uint256(_openPrice);
    pnlUsdc = int256(exitValue) - int256(size);
} else {
    // Ceil exitValue: larger loss for the trader, rounding favours the pool
    uint256 num = uint256(_closePrice) * size;
    uint256 exitValue = (num + uint256(_openPrice) - 1) / uint256(_openPrice);
    pnlUsdc = int256(size) - int256(exitValue);
}
```

Rounding directions for every formula are listed in [Guide 2](./02-mathematics.md). Funding rounds up for
payers and down for receivers, so it also favours the protocol, by at most 1 USDC unit per position.

---

## 6. Before Any Deployment

State of the items usually checked before a deployment, as of this review:

| Item | State |
|:---|:---|
| Admin keys in a multisig, timelock on parameter changes | Not in code; single `Ownable` owner per contract |
| Pausable trading | Independent flags: engine `PAUSE_OPEN`, `PAUSE_SETTLE` (closes, TP/SL and liquidations together, funding frozen); vault `PAUSE_DEPOSIT`, `PAUSE_WITHDRAW` (expiry clock stopped); playbook in [Guide 8](./08-security.md#6-incident-playbook) |
| Reentrancy guards | See section 4 |
| Oracle validation | Price age (5 s), future timestamp, confidence, Chainlink deviation and heartbeat, L2 sequencer uptime |
| Circuit breakers | Not implemented |
| Emergency withdrawal for LPs | Not implemented |
| Unit, fuzz, invariant, fork tests | Present; fork suite on Arbitrum One at a pinned block ([test docs](./tests/README.md)) |
| Invariant tying vault assets, open collateral and fees | Present (`invariant_VaultBalanceMatchesModelledFlows`); the NAV is checked against the balance and the snapshot (`invariant_TotalAssetsIsBalanceMinusSnapshotLiability`) and the snapshot against a brute-force valuation |
| Static analysis | Slither and Aderyn run; findings not triaged in this round |
| External audit | Not done |
| Bug bounty | None |

---

**See also:**
- [Guide 6: Future Improvements](./06-improvements.md)
- [Guide 8: Security](./08-security.md)
