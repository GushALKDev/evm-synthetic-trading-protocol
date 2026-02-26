# 💻 Guide 5: Solidity Implementation

**Version:** 1.0
**Prerequisites:** [Guide 4: Trade-offs and Problems](./04-tradeoffs.md)
**Next:** [Guide 6: Future Improvements](./06-improvements.md)

---

## 📋 Table of Contents

1. [Tech Stack](#1-tech-stack)
2. [Data Structures](#2-data-structures)
3. [Contract Interfaces](#3-contract-interfaces)
4. [Security Patterns](#4-security-patterns)
5. [Numerical Precision Handling](#5-numerical-precision-handling)
6. [Implementation Examples](#6-implementation-examples)
7. [Pre-Deployment Checklist](#7-pre-deployment-checklist)

---

## 1. Tech Stack

### Framework: Foundry

**Why Foundry over Hardhat?**

| Feature | Foundry | Hardhat |
|:---|:---|:---|
| Test language | Solidity | JavaScript/TypeScript |
| Speed | Extremely fast | Moderate |
| Native fuzzing | ✅ Yes | ❌ Requires plugin |
| Invariant testing | ✅ Yes | ❌ No |
| Gas snapshots | ✅ Integrated | ⚠️ Plugin |
| Fork testing | ✅ Excellent | ⚠️ Limited |

### Recommended Dependencies

```toml
# foundry.toml
[profile.default]
solc = "0.8.24"
optimizer = true
optimizer_runs = 200
via_ir = true

[dependencies]
openzeppelin = "5.0.0"
solady = "0.0.170"
```

### Libraries

| Library | Use | Import |
|:---|:---|:---|
| **Solady** | Ownable, SafeTransferLib, ReentrancyGuard, ERC4626, FixedPointMathLib | `solady/` |
| **Pyth SDK** | IPyth, PythStructs for price verification | `@pythnetwork/pyth-sdk-solidity/` |

---

## 2. Data Structures

### Trade Struct

```solidity
/// @notice Represents an open trading position
struct Trade {
    address user;           // Position owner
    uint256 pairIndex;      // Index of the trading pair (e.g., 0 = BTC/USD)
    uint256 index;          // Unique trade ID (auto-incremented)
    uint256 collateral;     // Initial margin deposited (USDC, 6 decimals)
    uint256 positionSize;   // Leveraged size in USD (18 decimals for precision)
    uint256 openPrice;      // Entry price from oracle (8 decimals normalized to 18)
    uint256 leverage;       // Leverage multiplier (e.g., 10 = 10x)
    uint256 tp;             // Take profit price (0 if not set)
    uint256 sl;             // Stop loss price (0 if not set)
    uint256 fundingIndex;   // Cumulative funding index at open
    uint256 timestamp;      // Block timestamp at open
    bool isLong;            // true = LONG, false = SHORT
}
```

### Pair Struct

```solidity
/// @notice Configuration for a trading pair
struct Pair {
    string name;            // e.g., "BTC/USD"
    bytes32 pythFeedId;     // Pyth price feed ID
    address chainlinkFeed;  // Chainlink AggregatorV3 address (deviation anchor)
    uint256 spreadBps;      // Base spread in basis points (100 = 1%)
    uint256 maxOI;          // Maximum open interest allowed (USD, 18 decimals)
    uint256 maxLeverage;    // Maximum leverage for this pair
    uint256 fundingFactor;  // Funding rate multiplier
    bool isActive;          // Can be paused independently
}
```

### Oracle Validated Price Struct

```solidity
/// @notice Validated price output from OracleAggregator
/// @dev Pyth raw price is normalized to 18 decimals. Confidence is preserved for risk management.
struct ValidatedPrice {
    uint128 price;          // Normalized price (18 decimals)
    uint128 confidence;     // Pyth confidence interval (18 decimals)
    uint64 publishTime;     // Pyth publish timestamp
}
```

---

## 3. Contract Interfaces

### IVault.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC4626} from "@openzeppelin/contracts/interfaces/IERC4626.sol";

interface IVault is IERC4626 {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    
    error OnlyTrading();
    error InsufficientBalance(uint256 requested, uint256 available);
    error WithdrawalLocked(uint256 unlockTime);
    
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    
    event PayoutSent(address indexed user, uint256 amount);
    event LossReceived(uint256 amount);
    event CollateralizationRatioUpdated(uint256 newRatio);
    
    /*//////////////////////////////////////////////////////////////
                            TRADING FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Send payout to winning trader (only callable by TradingEngine)
    /// @param user Recipient address
    /// @param amount Amount in USDC (6 decimals)
    function sendPayout(address user, uint256 amount) external;
    
    /// @notice Receive loss from losing trader (internal accounting)
    /// @param amount Amount in USDC (6 decimals)
    function receiveLoss(uint256 amount) external;
    
    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    /// @notice Current collateralization ratio (18 decimals, 1e18 = 100%)
    function collateralizationRatio() external view returns (uint256);
    
    /// @notice Check if withdrawals are currently allowed
    function canWithdraw(address user) external view returns (bool);
}
```

### ITradingEngine.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface ITradingEngine {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/
    
    error InvalidLeverage(uint256 leverage, uint256 max);
    error MaxOpenInterestReached(uint256 current, uint256 max);
    error PairNotActive(uint256 pairIndex);
    error NotTradeOwner(address caller, address owner);
    error NotLiquidatable(uint256 lossPercent, uint256 threshold);
    error InvalidPrice(uint256 price, uint256 timestamp);
    error ProfitCapExceeded();
    
    /*//////////////////////////////////////////////////////////////
                                EVENTS
    //////////////////////////////////////////////////////////////*/
    
    event TradeOpened(
        uint256 indexed tradeId,
        address indexed user,
        uint256 pairIndex,
        uint256 collateral,
        uint256 leverage,
        bool isLong,
        uint256 openPrice
    );
    
    event TradeClosed(
        uint256 indexed tradeId,
        address indexed user,
        uint256 closePrice,
        int256 pnl,
        CloseReason reason
    );
    
    event TradeLiquidated(
        uint256 indexed tradeId,
        address indexed liquidator,
        uint256 reward
    );
    
    /*//////////////////////////////////////////////////////////////
                                ENUMS
    //////////////////////////////////////////////////////////////*/
    
    enum CloseReason { Manual, TakeProfit, StopLoss, Liquidation }
    
    /*//////////////////////////////////////////////////////////////
                            TRADING FUNCTIONS
    //////////////////////////////////////////////////////////////*/
    
    function openTrade(
        uint256 pairIndex,
        uint256 collateral,
        uint256 leverage,
        bool isLong,
        uint256 tp,
        uint256 sl
    ) external returns (uint256 tradeId);
    
    function closeTrade(uint256 tradeId) external;
    
    function updateTakeProfit(uint256 tradeId, uint256 newTp) external;

    function updateStopLoss(uint256 tradeId, uint256 newSl) external;

    function liquidate(uint256 tradeId) external;

    function executeLimit(uint256 tradeId) external;
}
```

> **TP/SL price-dependent validations (Phase 3):**
> `openTrade`, `updateTakeProfit`, and `updateStopLoss` must validate that the TP/SL has not already been triggered at the current oracle price. For example, a LONG with `oraclePrice = 80,000` must reject `sl = 90,000` because the keeper would execute immediately at 80k — worse than the 90k the user intended. Similarly, a TP already surpassed is rejected so the user can raise it or close at market. These validations live in TradingEngine (requires oracle access), while TradingStorage retains its structural checks (`tp > openPrice` for longs, etc.) as a defense-in-depth layer.

### IOracleAggregator.sol

```solidity
// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

interface IOracleAggregator {
    /*//////////////////////////////////////////////////////////////
                                ERRORS
    //////////////////////////////////////////////////////////////*/

    error StalePrice(uint64 publishTime, uint256 maxStaleness);
    error ConfidenceTooWide(uint128 confidence, uint128 price, uint256 maxBps);
    error PriceDeviationTooHigh(uint256 pythPrice, uint256 chainlinkPrice, uint256 maxDeviation);
    error ZeroPrice();
    error InvalidPythFee();

    /*//////////////////////////////////////////////////////////////
                            PRICE FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Validate and return Pyth price with Chainlink deviation check
    /// @dev Caller must send ETH to cover Pyth update fee. Reverts if:
    ///      - Pyth price is stale (> MAX_STALENESS)
    ///      - Confidence interval is too wide (> MAX_CONFIDENCE_BPS)
    ///      - Deviation from Chainlink exceeds MAX_DEVIATION
    ///      Chainlink is NOT a fallback — stale Pyth always reverts.
    /// @param priceUpdate Signed price data from Pyth Hermes API
    /// @param pairIndex Index of the trading pair
    /// @return price Validated price (18 decimals)
    function getValidatedPrice(bytes[] calldata priceUpdate, uint16 pairIndex) external payable returns (uint128 price);

    /// @notice Get the Pyth update fee for a given price update
    /// @param priceUpdate The price update bytes
    /// @return fee The fee in native token (wei)
    function getUpdateFee(bytes[] calldata priceUpdate) external view returns (uint256 fee);

    /// @notice Get price with spread applied for execution (future: Phase 4)
    /// @param priceUpdate Signed price data from Pyth Hermes API
    /// @param pairIndex Index of the trading pair
    /// @param isLong Direction of the trade
    /// @param isOpen Whether this is an open or close
    /// @return executionPrice Price with spread applied (18 decimals)
    function getExecutionPrice(bytes[] calldata priceUpdate, uint16 pairIndex, bool isLong, bool isOpen) external payable returns (uint128 executionPrice);
}
```

---

## 4. Security Patterns

### 4.1 Custom Errors (Gas Efficient)

```solidity
// ❌ BAD: String errors (expensive)
require(newOI <= maxOI, "Max OI reached");

// ✅ GOOD: Custom errors (cheap)
error MaxOpenInterestReached(uint256 current, uint256 max);

function openTrade(...) external {
    uint256 newOI = currentOI + positionSize;
    if (newOI > maxOI) {
        revert MaxOpenInterestReached(newOI, maxOI);
    }
}
```

### 4.2 Checks-Effects-Interactions (CEI)

```solidity
function closeTrade(uint256 tradeId) external nonReentrant {
    Trade storage t = trades[tradeId];
    
    // ══════════════════════════════════════════════════════════
    //                         CHECKS
    // ══════════════════════════════════════════════════════════
    if (msg.sender != t.user) {
        revert NotTradeOwner(msg.sender, t.user);
    }
    
    (uint256 price,) = oracle.getPrice(t.pairIndex);
    int256 pnl = _calculatePnL(t, price);
    uint256 payout = _calculatePayout(t.collateral, pnl);
    
    // ══════════════════════════════════════════════════════════
    //                         EFFECTS
    // ══════════════════════════════════════════════════════════
    // Update state BEFORE external calls
    openInterest[t.pairIndex] -= t.positionSize;
    delete trades[tradeId];
    _removeFromUserTrades(msg.sender, tradeId);
    
    emit TradeClosed(tradeId, msg.sender, price, pnl, CloseReason.Manual);
    
    // ══════════════════════════════════════════════════════════
    //                       INTERACTIONS
    // ══════════════════════════════════════════════════════════
    // External calls LAST
    if (payout > 0) {
        vault.sendPayout(msg.sender, payout);
    }
}
```

### 4.3 Access Control with Roles

```solidity
import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";

contract TradingEngine is AccessControl {
    bytes32 public constant ADMIN_ROLE = keccak256("ADMIN_ROLE");
    bytes32 public constant KEEPER_ROLE = keccak256("KEEPER_ROLE");
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");
    
    modifier onlyKeeper() {
        if (!hasRole(KEEPER_ROLE, msg.sender)) {
            revert NotKeeper(msg.sender);
        }
        _;
    }
    
    function executeLimit(uint256 tradeId) external onlyKeeper {
        // Only keepers can execute limit orders
    }
    
    function pause() external onlyRole(PAUSER_ROLE) {
        _pause();
    }
}
```

---

## 5. Numerical Precision Handling

### Decimal Standards

| Type | Decimals | Constant |
|:---|:---|:---|
| USDC (input/output) | 6 | `1e6` |
| Internal USD values | 18 | `WAD = 1e18` |
| Chainlink prices | 8 | `1e8` |
| Pyth prices | variable (expo) | normalized to `1e18` |
| Internal prices | 18 | `WAD = 1e18` |
| Percentages (BPS) | 4 | `10000 = 100%` |

### Conversions

```solidity
using FixedPointMathLib for uint256;

uint256 constant WAD = 1e18;
uint256 constant USDC_DECIMALS = 6;
uint256 constant PRICE_DECIMALS = 8;

/// @notice Convert USDC (6 decimals) to internal representation (18 decimals)
function toWad(uint256 usdc) internal pure returns (uint256) {
    return usdc * 1e12; // 6 + 12 = 18
}

/// @notice Convert internal (18 decimals) back to USDC (6 decimals)
function toUsdc(uint256 wad) internal pure returns (uint256) {
    return wad / 1e12;
}

/// @notice Normalize Chainlink price (8 decimals) to internal (18 decimals)
function normalizePrice(uint256 chainlinkPrice) internal pure returns (uint256) {
    return chainlinkPrice * 1e10; // 8 + 10 = 18
}
```

### PnL Calculation with Precision

```solidity
/// @notice Calculate PnL for a trade
/// @param t The trade struct
/// @param currentPrice Current price (18 decimals)
/// @return pnl Signed PnL (positive = profit, negative = loss)
function _calculatePnL(Trade storage t, uint256 currentPrice) internal view returns (int256 pnl) {
    // positionSize is in 18 decimals
    // currentPrice and openPrice are in 18 decimals
    
    if (t.isLong) {
        // PnL = (exitPrice * size / entryPrice) - size
        // Multiply first to avoid precision loss
        uint256 exitValue = currentPrice.mulWad(t.positionSize).divWad(t.openPrice);
        pnl = int256(exitValue) - int256(t.positionSize);
    } else {
        // PnL = size - (exitPrice * size / entryPrice)
        uint256 exitValue = currentPrice.mulWad(t.positionSize).divWad(t.openPrice);
        pnl = int256(t.positionSize) - int256(exitValue);
    }
}
```

---

## 6. Implementation Examples

### Liquidation with Reward

```solidity
function liquidate(uint256 tradeId) external nonReentrant whenNotPaused {
    Trade storage t = trades[tradeId];
    
    // Checks
    if (t.user == address(0)) revert TradeNotFound(tradeId);
    
    (uint256 price,) = oracle.getPrice(t.pairIndex);
    int256 pnl = _calculatePnL(t, price);
    
    // Loss must be >= 90% of collateral
    uint256 collateralWad = toWad(t.collateral);
    int256 lossThreshold = -int256(collateralWad.mulWad(LIQUIDATION_THRESHOLD));
    
    if (pnl > lossThreshold) {
        revert NotLiquidatable(uint256(-pnl), uint256(-lossThreshold));
    }
    
    // Effects
    uint256 remaining = uint256(int256(collateralWad) + pnl);
    uint256 liquidatorReward = remaining.mulWad(LIQUIDATOR_REWARD_BPS);
    uint256 vaultShare = remaining - liquidatorReward;
    
    address tradeOwner = t.user;
    openInterest[t.pairIndex] -= t.positionSize;
    delete trades[tradeId];
    _removeFromUserTrades(tradeOwner, tradeId);
    
    emit TradeLiquidated(tradeId, msg.sender, toUsdc(liquidatorReward));
    
    // Interactions
    vault.receiveLoss(toUsdc(vaultShare));
    IERC20(usdc).safeTransfer(msg.sender, toUsdc(liquidatorReward));
}
```

### Dynamic Spread

```solidity
function getExecutionPrice(
    uint256 pairIndex,
    bool isLong,
    bool isOpen
) external returns (uint256 executionPrice) {
    (uint256 oraclePrice,) = getPrice(pairIndex);
    
    Pair storage pair = pairs[pairIndex];
    
    // Calculate spread based on utilization
    uint256 utilization = openInterest[pairIndex].divWad(vault.totalAssets());
    uint256 dynamicSpread = pair.spreadBps + utilization.mulWad(pair.impactFactor);
    
    // Cap spread at maximum
    if (dynamicSpread > MAX_SPREAD_BPS) {
        dynamicSpread = MAX_SPREAD_BPS;
    }
    
    // Apply spread based on direction
    bool worsePrice = (isLong && isOpen) || (!isLong && !isOpen);
    
    if (worsePrice) {
        executionPrice = oraclePrice.mulWad(WAD + dynamicSpread * WAD / 10000);
    } else {
        executionPrice = oraclePrice.mulWad(WAD - dynamicSpread * WAD / 10000);
    }
}
```

---

## 7. Pre-Deployment Checklist

### Security

- [ ] **Access Control:** All admin functions protected with roles
- [ ] **Pausable:** Trading can be paused in emergency
- [ ] **Reentrancy Guards:** All functions with external transfers
- [ ] **CEI Pattern:** State updated before external calls
- [ ] **Integer Overflow:** Solidity 0.8+ (native checks)
- [ ] **Oracle Validation:** Staleness and deviation verified

### Configuration

- [ ] **Timelock:** Critical parameter changes with 24-48h delay
- [ ] **Multisig:** Admin keys in multisig (e.g., 3/5)
- [ ] **Circuit Breakers:** Configured for extreme movements
- [ ] **Emergency Withdrawal:** Function for LPs to withdraw without delay in emergency

### Testing

- [ ] **Unit Tests:** Coverage >95%
- [ ] **Fuzz Testing:** All mathematical functions
- [ ] **Invariant Tests:**
  - `totalAssets >= sum(pendingPayouts)`
  - `sum(openInterest) <= maxGlobalOI`
  - `sharePrice > 0`
- [ ] **Fork Tests:** Against mainnet/testnet with real oracles

### Audit

- [ ] **Internal Review:** Code review by at least 2 developers
- [ ] **Static Analysis:** Slither, Aderyn with no critical findings
- [ ] **External Audit:** At least 1 audit from reputable firm
- [ ] **Bug Bounty:** Active program post-launch

---

**See also:**
- [Guide 6: Future Improvements](./06-improvements.md) - Advanced features
- [Guide 8: Security](./08-security.md) - Complete threat model
