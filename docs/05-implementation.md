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
| Pyth SDK | `@pythnetwork/pyth-sdk-solidity` `^4.3.1` (npm), remapped from `node_modules/` | `package.json`, `foundry.toml` |
| Formatter | `forge fmt`, `line_length = 160` | `foundry.toml` `[fmt]` |

`foundry.toml` sets `ffi = true` (needed by the fork tests) and does not set `solc`, the optimizer or
`via_ir`, so forge defaults apply.

Solady modules used: `ERC4626`, `ERC20`, `Ownable`, `ReentrancyGuard`, `SafeTransferLib`. OpenZeppelin
is not a dependency.

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
    uint64 collateral; //  8 bytes  │  Slot 1 (28/32)
    uint128 openPrice; // 16 bytes -┘
    uint128 tp; //        16 bytes -┐  Slot 2 (full)
    uint128 sl; //        16 bytes -┘
}
```

- `collateral` is the stored collateral after the open fee (USDC, 6 decimals).
- `openPrice`, `tp`, `sl` are 18-decimal prices; `openPrice` includes the open spread.
- `user == address(0)` marks a deleted or nonexistent trade. Trade IDs come from a `uint32` counter and
  are never reused.
- The entry funding index is stored separately in `mapping(uint256 => int256) _tradeFundingIndex`.

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

### WithdrawalRequest (`Vault.sol`), 2 slots

```solidity
struct WithdrawalRequest {
    uint256 shares;
    uint256 requestEpoch;
}
```

One request per address; a new request overwrites the old one. Shares are not escrowed.

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
}
```

`priceData` is opaque update data for pull oracles. The caller pays any fee in `msg.value` and the oracle
refunds the surplus to `msg.sender`. `TradingEngine` stores the oracle as an immutable, so replacing it
requires a new engine deployment.

### ISolvency (`ISolvencyVault`, `IAssistantFund`, `IBondDepository`)

Minimal views and calls used by `SolvencyManager`: `collateralizationRatio()`,
`collateralizationDeficit()`, `totalAssets()`, `balance()`, `injectFunds(uint256)`, `isActive()`,
`activateBonding(uint256)`.

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
- **Pause:** `TradingEngine` and `Vault` have their own `_paused` flag with `whenNotPaused`/`whenPaused`.
  `TradingStorage` has no pause so collateral can always move for `liquidate`.
- **Reentrancy:** Solady `ReentrancyGuard` on `TradingEngine.openTrade`, `closeTrade`, `liquidate`,
  `executeLimit` and on `Vault.deposit`, `mint`, `requestWithdrawal`, `executeWithdrawal`, `sendPayout`.
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
| Funding index | 18 (signed) | `FundingLib` |
| Volatility | 18 | 3% = `3e16` |
| Collateralization ratio | 18 | 1e18 = 100% |
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

Rounding directions for every formula are listed in [Guide 2](./02-mathematics.md). Funding rounds toward
zero in both directions, so it is the one place where rounding can favour the trader, by at most 1 USDC
unit per trade.

---

## 6. Before Any Deployment

State of the items usually checked before a deployment, as of this review:

| Item | State |
|:---|:---|
| Admin keys in a multisig, timelock on parameter changes | Not in code; single `Ownable` owner per contract |
| Pausable trading | `TradingEngine.pause` (liquidations stay active) and `Vault.pause` |
| Reentrancy guards | See section 4 |
| Oracle validation | Staleness, confidence, Chainlink deviation and heartbeat |
| Circuit breakers | Not implemented |
| Emergency withdrawal for LPs | Not implemented |
| Unit, fuzz, invariant, fork tests | Present; fork suite not reproducible in this review ([test docs](./tests/README.md)) |
| Invariant tying vault assets, open collateral, open PnL and fees | Not present |
| Static analysis | Slither and Aderyn run; findings not triaged in this round |
| External audit | Not done |
| Bug bounty | None |

---

**See also:**
- [Guide 6: Future Improvements](./06-improvements.md)
- [Guide 8: Security](./08-security.md)
