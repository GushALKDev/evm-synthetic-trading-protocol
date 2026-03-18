# 🧮 Guide 2: Protocol Mathematics

**Version:** 1.0  
**Prerequisites:** [Guide 1: Fundamentals](./01-fundamentals.md)  
**Next:** [Guide 3: Technical Architecture](./03-architecture.md)

---

## 📋 Table of Contents

1. [Vault Share Price](#1-vault-share-price)
2. [PnL (Profit & Loss) Calculation](#2-pnl-profit--loss-calculation)
3. [Execution Price with Dynamic Spread](#3-execution-price-with-dynamic-spread)
4. [Liquidations](#4-liquidations)
5. [Funding Rates](#5-funding-rates)
6. [Adaptive OI (Dynamic Open Interest)](#6-adaptive-oi-dynamic-open-interest)
7. [Solvency (Collateralization Ratio)](#7-solvency-collateralization-ratio)
8. [Configurable Parameters Table](#8-configurable-parameters-table)

---

> ⚠️ **Precision Note:** In all Solidity formulas, multiply before dividing to avoid decimal loss. Example: `(priceExit * size) / priceEntry`.

---

## 1. Vault Share Price

The Vault follows the **ERC-4626** standard. The exchange rate between assets (USDC) and shares (sToken) fluctuates based on trader PnL.

### Formula

$$SharePrice = \\frac{TotalAssets}{TotalSupply}$$

Where:
- **TotalAssets:** Total USDC in the Vault.
- **TotalSupply:** Total sToken held by LPs.

### Profit/Loss Dynamics

| Event | TotalAssets | TotalSupply | SharePrice | LP Effect |
|:---|:---|:---|:---|:---|\n| Trader loses 100 USDC | +100 | = | **↑ Rises** | ✅ Profit |
| Trader wins 100 USDC | -100 | = | **↓ Falls** | ❌ Loss |
| LP deposits 100 USDC | +100 | +shares | = | Neutral |
| LP withdraws 100 USDC | -100 | -shares | = | Neutral |

---

## 2. PnL (Profit & Loss) Calculation

PnL calculation considers direction (Long/Short), position size, and entry/exit prices.

### Definitions

| Variable | Definition | Unit |
|:---|:---|:---|
| $Collateral$ | Initial margin deposited | USDC |
| $Leverage$ | Multiplier (e.g., 10x) | Number |
| $Size$ | Position size = $Collateral \\times Leverage$ | USDC |
| $P_{entry}$ | Entry price (oracle) | USD |
| $P_{exit}$ | Exit price (oracle) | USD |

### General Formula

$$PnL = \\frac{(P_{exit} - P_{entry}) \\times Size}{P_{entry}} \\times Direction$$

Where $Direction = +1$ for Long, $-1$ for Short.

### Simplified Formulas (used in contracts)

**For Long (profits if price rises):**
$$PnL = \\frac{P_{exit} \\times Size}{P_{entry}} - Size$$

**For Short (profits if price falls):**
$$PnL = Size - \\frac{P_{exit} \\times Size}{P_{entry}}$$

### Example: Long 10x on ETH

| Step | Value |
|:---|:---|
| Collateral | 100 USDC |
| Leverage | 10x |
| Size | 1,000 USDC |
| $P_{entry}$ | 2,000 USD |
| $P_{exit}$ | 2,100 USD (+5%) |
| **PnL** | $(2100 × 1000 / 2000) - 1000 = 1050 - 1000 = $ **+50 USDC** |

### Profit Cap

Profits are capped to protect the Vault:

$$Payout = min(Collateral + PnL, Collateral \\times MAX\\_MULTIPLIER)$$

Where $MAX\\_MULTIPLIER$ = 7x to 9x (configurable).

---

## 3. Execution Price with Dynamic Spread

To protect against latency arbitrage, simulate market depth, and manage risk during volatile periods, execution price incorporates a **dynamic spread** based on OI and volatility.

### Spread Formula

$$Spread = BaseSpread + (OI_{pair} \\times ImpactFactor) + (Volatility \\times VolatilityFactor)$$

Where:
- **BaseSpread:** Fixed minimum spread (e.g., 0.05%)
- **$OI_{pair}$:** Current Open Interest for the pair
- **ImpactFactor:** OI impact multiplier
- **Volatility:** Realized asset volatility (e.g., 24h return std dev)
- **VolatilityFactor:** Volatility impact multiplier

### Volatility Calculation

Volatility is calculated off-chain and updated periodically on-contract:

$$Volatility = \\sigma_{24h} = \\sqrt{\\frac{1}{N}\\sum_{i=1}^{N}(r_i - \\bar{r})^2}$$

Where $r_i$ are hourly logarithmic returns over the last 24h.

**Typical ranges:**
| Asset | Low Volatility | Medium Volatility | High Volatility |
|:---|:---|:---|:---|
| BTC | < 2% | 2-5% | > 5% |
| ETH | < 3% | 3-7% | > 7% |
| Altcoins | < 5% | 5-10% | > 10% |

### Execution Price

$$P_{execution} = P_{oracle} \\times (1 \\pm Spread)$$

| Direction | Formula | Effect |
|:---|:---|:---|
| **Long (Open)** | $P_{oracle} \\times (1 + Spread)$ | Buy more expensive |
| **Long (Close)** | $P_{oracle} \\times (1 - Spread)$ | Sell cheaper |
| **Short (Open)** | $P_{oracle} \\times (1 - Spread)$ | Sell cheaper |
| **Short (Close)** | $P_{oracle} \\times (1 + Spread)$ | Rebuy more expensive |

### Example: Normal Conditions

- Oracle Price: 50,000 USD
- BaseSpread: 0.05%
- OI Impact: 0.03%
- Volatility Impact: 0.02% (low volatility)
- **Total Spread:** 0.10%

**Long Open:** $50,000 × 1.0010 = 50,050 USD$

### Example: High Volatility

- Oracle Price: 50,000 USD
- BaseSpread: 0.05%
- OI Impact: 0.03%
- Volatility Impact: 0.15% (high volatility, σ = 6%)
- **Total Spread:** 0.23%

**Long Open:** $50,000 × 1.0023 = 50,115 USD$

> ⚠️ **Note:** During extreme volatility events (flash crashes, news), spread can increase significantly to protect the Vault.

---

## 4. Liquidations

The system liquidates positions before loss exceeds collateral (avoiding bad debt).

### Liquidation Threshold

**Default:** 90% of collateral.

$$isLiquidatable = Loss \\geq Collateral \\times LIQUIDATION\\_THRESHOLD$$

### Liquidation Price

**For Long:**
$$P_{liq} = P_{entry} \\times \\left(1 - \\frac{LIQUIDATION\\_THRESHOLD}{Leverage}\\right)$$

**For Short:**
$$P_{liq} = P_{entry} \\times \\left(1 + \\frac{LIQUIDATION\\_THRESHOLD}{Leverage}\\right)$$

### Example: Long 10x

| Variable | Value |
|:---|:---|
| Collateral | 100 USDC |
| Leverage | 10x |
| $P_{entry}$ | 50,000 USD |
| Threshold | 90% |
| **$P_{liq}$** | $50,000 × (1 - 0.9/10) = 50,000 × 0.91 = $ **45,500 USD** |

### Remaining Collateral Distribution

When liquidated (10% remaining = 10 USDC in example):

| Recipient | Percentage | Example |
|:---|:---|:---|
| Liquidator Bot | 10% of remaining | 1 USDC |
| Vault (LPs) | 90% of remaining | 9 USDC |

### Liquidation Behavior (Phases)

**Phase 1 (Current):**
1. Bot detects at-risk position.
2. Bot calls `liquidate(tradeId)`.
3. Oracle returns current price.
4. If current price is in liquidation zone → Liquidated.
5. If current price is NOT in zone → Transaction fails, trade stays open.

**Phase 2 (Lookbacks):**
1. Bot detects price *entered* liquidation zone.
2. Bot calls `liquidate(tradeId)` with historical price proof.
3. Even if current price is in safe zone, position is liquidated because price *touched* threshold.

> This behavior also applies to **limit orders** (TP/SL).

---

## 5. Funding Rates

Funding rates balance directional risk between Longs and Shorts.

### Funding Rate Calculation

$$FundingRate = (OI_{long} - OI_{short}) \\times FundingFactor$$

| Condition | Who Pays | Who Receives |
|:---|:---|:---|
| $OI_{long} > OI_{short}$ | Longs | Shorts (+ Vault for imbalance) |
| $OI_{short} > OI_{long}$ | Shorts | Longs (+ Vault for imbalance) |

### Cumulative Funding Index

To avoid iterating over all positions each block, a global index is used:

$$cumulativeFundingIndex_{new} = cumulativeFundingIndex_{old} + FundingRate \\times \\Delta time$$

**Funding owed per position:**
$$FundingOwed = Size \\times (currentIndex - positionEntryIndex)$$

---

## 6. Dynamic Spread via SpreadManager

The protocol uses a standalone `SpreadManager` contract to compute execution spreads based on **OI** and **per-pair volatility**. This is the primary risk mechanism for protecting the Vault — higher risk conditions automatically widen spreads, making new positions more expensive.

### Implementation

The spread formula from §3 is implemented in `SpreadManager.getSpreadBps(pairIndex, currentOI)`:

```solidity
spreadBps = baseSpreadBps + (currentOI * impactFactor / OI_PRECISION) + (pairVolatility * volFactor / VOL_PRECISION);
if (spreadBps > maxSpreadBps) spreadBps = maxSpreadBps;
```

Where `OI_PRECISION = 1e30` and `VOL_PRECISION = 1e18`.

### BPS Calibration

| Parameter | Default | Example Effect |
|:---|:---|:---|
| `baseSpreadBps` | 5 (0.05%) | Fixed floor |
| `impactFactor` | 3e5 | 3 BPS at 10M OI (`1e25 * 3e5 / 1e30 = 3`) |
| `volFactor` | 100 | 3 BPS at 3% vol (`3e16 * 100 / 1e18 = 3`) |
| `maxSpreadBps` | 100 (1%) | Hard ceiling |

### Volatility Update

- **Frequency:** Every hour (or every X blocks)
- **Source:** Calculated off-chain (24h realized σ), published by authorized keeper
- **Validation:** Maximum change per update bounded by ±`maxVolatilityChangeBps` (default: 200 = 2%) to prevent manipulation. First update for a pair skips bounds check.

### Behavior During High Volatility

```
┌─────────────────────────────────────────────────────────────────────┐
│                    HIGH VOLATILITY (σ > 5%)                          │
├─────────────────────────────────────────────────────────────────────┤
│  • Spread: 0.05% + 0.03%(OI) + 0.15%(Vol) = 0.23%                   │
│  • New positions: More expensive due to wider spread                │
│  • Existing positions: Unaffected (entered at their spread)        │
│  • When volatility returns to normal: spread decreases gradually   │
└─────────────────────────────────────────────────────────────────────┘
```

---

## 7. Solvency (Collateralization Ratio)

### Definition

$$CR = \\frac{TotalUSDC_{Vault}}{TotalLPDeposits}$$

### Thresholds

| State | Condition | Action |
|:---|:---|:---|
| **Healthy** | CR ≥ 110% | Normal operation |
| **Warning** | 100% ≤ CR < 110% | No action, monitoring |
| **Deficit** | CR < 100% | Activate solvency layers |
| **Surplus** | CR > 110% | Use surplus for $SYNTH buyback |

### Solvency Actions

**Deficit (CR < 100%):**
1. Inject from Assistant Fund (if available).
2. If insufficient → Activate $SYNTH bonding.

**Surplus (CR > 110%):**
1. Take surplus USDC (above 110%).
2. Buy $SYNTH on open market.
3. Burn $SYNTH (deflation).

---

## 8. Configurable Parameters Table

| Parameter | Suggested Value | Contract | Description |
|:---|:---|:---|:---|
| `MAX_LEVERAGE` | 100x | TradingEngine | Maximum allowed leverage |
| `LIQUIDATION_THRESHOLD` | 90% | TradingEngine | % loss for liquidation |
| `MAX_MULTIPLIER` | 7x-9x | Market | Profit cap (max payout) |
| `BASE_SPREAD` | 0.05% (5 BPS) | SpreadManager | Fixed minimum spread |
| `OI_IMPACT_FACTOR` | 3e5 | SpreadManager | OI impact multiplier (3 BPS at 10M OI) |
| `VOLATILITY_FACTOR` | 100 | SpreadManager | Volatility impact multiplier (3 BPS at 3% vol) |
| `MAX_SPREAD` | 1% (100 BPS) | SpreadManager | Maximum spread cap |
| `FUNDING_FACTOR` | 0.0001% | FundingLib | Funding rate multiplier |
| `SAFE_CR_THRESHOLD` | 110% | SolvencyManager | Ratio to activate buyback |
| `DEFICIT_CR_THRESHOLD` | 100% | SolvencyManager | Ratio to activate solvency |
| `FEE_SPLIT_ASSISTANT` | 20% | FeeManager | % fees → Assistant Fund |
| `LIQUIDATOR_REWARD` | 10% | TradingEngine | % of remaining for liquidator |
| `VOLATILITY_UPDATE_FREQ` | 1 hour | Keeper | σ update frequency |
| `MAX_VOLATILITY_CHANGE` | ±2% (200 BPS) | SpreadManager | Maximum volatility change per keeper update |

---

**See also:**
- [Guide 3: Technical Architecture](./03-architecture.md) - How these formulas are implemented
- [Guide 5: Solidity Implementation](./05-implementation.md) - Concrete code
