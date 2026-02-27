# ⚠️ Guide 4: Trade-offs, Problems, and Solutions

**Version:** 1.0
**Prerequisites:** [Guide 3: Technical Architecture](./03-architecture.md)
**Next:** [Guide 5: Solidity Implementation](./05-implementation.md)

---

## 📋 Table of Contents

1. [Latency Arbitrage (Toxic Flow)](#1-latency-arbitrage-toxic-flow)
2. [Solvency Risk (LP Rekt)](#2-solvency-risk-lp-rekt)
3. [Liquidation Front-Running](#3-liquidation-front-running)
4. [Oracle Manipulation](#4-oracle-manipulation)
5. [Stablecoin Risk (USDC Depeg)](#5-stablecoin-risk-usdc-depeg)
6. [Trade-offs Summary Table](#6-trade-offs-summary-table)
7. [Risk Matrix](#7-risk-matrix)

---

Oracle-based synthetic trading protocols (GMX, Gains Network, Synthetix) share a series of well-documented risks. This guide analyzes each one and how the Synthetic Trading Protocol mitigates them.

---

## 1. Latency Arbitrage (Toxic Flow)

### The Problem

On-chain prices (oracle updates) always lag behind CEXs (Binance, Coinbase).

```
Timeline:
─────────────────────────────────────────────────────►
     │                    │                    │
   t=0                  t=500ms              t=2s
   BTC rises 1%         Bot detects          Oracle
   on Binance           discrepancy          updates
                              │
                              ▼
                        Bot opens LONG
                        on protocol
                        (old price)
                              │
                              ▼
                        GUARANTEED PROFIT
                        "Risk-free" arbitrage
```

**Consequence:** Systematic LP fund drainage (Toxic Flow).

### Our Solution: Pyth Pull Oracle + Staleness Control

The Synthetic Trading Protocol uses **Pyth Network** (pull model) with strict staleness enforcement:

1. **Fresh prices:** Pyth provides sub-second price updates from 128+ first-party publishers (exchanges, market makers).
2. **User-submitted prices:** Frontend fetches the latest signed price from Pyth Hermes API and includes it as calldata — price is verified on-chain via Wormhole signatures.
3. **Strict staleness:** `MAX_STALENESS` of 10-30 seconds. Stale price → revert (no fallback).
4. **Chainlink deviation anchor:** If Pyth price deviates too far from Chainlink → revert. Protects against Pyth anomalies without using Chainlink as a slower fallback.
5. **Confidence intervals:** Pyth provides publisher disagreement data — trades are rejected during high uncertainty (`conf/price > 1%`).

**Benefits:**
- Sub-second price freshness eliminates most latency arbitrage windows.
- Pull model means users pay the update fee (~$0.01 on L2), no protocol gas cost.
- 128+ publishers make manipulation economically infeasible.
- Confidence intervals enable dynamic risk management.

### Alternative: Deferred Execution

If latency remains a problem:

1. User sends `requestOpenTrade()`.
2. Order is queued (pending).
3. After X blocks, a Keeper executes with the price *at that future moment*.

**Trade-off:** Worse UX (non-instant order), but eliminates price prediction ability. Most modern perp DEXs (Jupiter, Synthetix v3) avoid this by relying on Pyth's sub-second updates.

---

## 2. Solvency Risk (LP Rekt)

### The Problem

Unlike a 50/50 AMM, LP losses here aren't algorithmically limited.

**Black Swan Scenario:**
- Extreme bull market.
- All traders are LONG with high leverage.
- Vault can be drained if profits exceed assets.

### Our Solution: 4-Layer Defense

```
┌─────────────────────────────────────────────────────────────────────┐
│ LAYER 0: EXTREME PREVENTIVE (Volatility-based)                      │
│ ├── Adaptive OI Caps: Higher volatility = lower OI allowed          │
│ ├── Dynamic Spreads: Higher volatility/OI = higher spread           │
│ └── Strict Profit Caps: 7x-9x maximum                              │
├─────────────────────────────────────────────────────────────────────┤
│ LAYER 1: FUNDING RATES                                              │
│ ├── If OI_long >> OI_short: Very high funding for Longs            │
│ └── Incentivizes closes or Short openings (balance)                │
├─────────────────────────────────────────────────────────────────────┤
│ LAYER 2: ASSISTANT FUND                                             │
│ ├── 20% of all fees go to reserve                                  │
│ └── Automatic injection without $SYNTH dilution                     │
├─────────────────────────────────────────────────────────────────────┤
│ LAYER 3: BONDING                                                    │
│ ├── $SYNTH sale at discount                                        │
│ └── Emergency recapitalization                                      │
└─────────────────────────────────────────────────────────────────────┘
```

### Bankruptcy Control

The **bankruptcy** scenario (Assistant Fund + Bonding both fail simultaneously) is prevented by:

| Control | Mechanism | Effect |
|:---|:---|:---|
| **Adaptive OI Cap** | `MaxOI = BaseOI × (TargetVol / CurrentVol)` | Lower OI allowed during high volatility |
| **Profit Cap** | `maxPayout = collateral × 9` | Limits maximum loss per trade |
| **Dynamic Spread** | `spread = base + (OI × factor) + (Vol × factor)` | Higher spread during high volatility |

---

## 3. Liquidation Front-Running

### The Problem

1. **Self front-running:** User about to be liquidated tries to manipulate price or close first.
2. **Gas Wars:** Multiple bots compete for liquidation reward, congesting network.
3. **MEV:** Validators can reorder txs to extract value.

### Our Solution

**For self front-running:**
- User cannot close a position already in liquidation zone (validation in `closeTrade`).

**For Gas Wars:**
- Fixed reward (10% of remaining) that doesn't justify excessive wars.
- Consider Flashbots/Protect RPC to avoid public mempool.

**Liquidation Behavior (Phase 2 - Lookbacks):**
- If price *touched* liquidation zone at any point, position is liquidatable.
- Prevents temporary price manipulations.

```solidity
// Phase 1: Current price only
function liquidate(uint256 tradeId) external {
    uint256 currentPrice = oracle.getPrice(trade.pairIndex);
    require(isLiquidatable(trade, currentPrice), "Not liquidatable");
    // ...
}

// Phase 2: With lookback
function liquidate(uint256 tradeId, bytes calldata priceProof) external {
    // Verify price entered liquidation zone
    require(oracle.verifyPriceTouchedLevel(priceProof, trade.liqPrice), "Never hit liq price");
    // ...
}
```

---

## 4. Oracle Manipulation

### The Problem

If the oracle can be manipulated, an attacker could:
- Trigger unfair liquidations.
- Execute trades at favorable prices.
- Systematically drain the Vault.

**Attack vectors:**
1. Flash Loan to manipulate DEX pool used as oracle.
2. Compromise Pyth publishers or submit stale/adversarial price updates.
3. Exploit low-liquidity feeds with fewer publishers.

### Our Solution

| Protection | Implementation |
|:---|:---|
| **Don't use DEX pools as oracle** | Pyth (primary) + Chainlink (anchor) only |
| **Wormhole signature verification** | Pyth prices are cryptographically signed by publishers and verified on-chain |
| **Chainlink deviation anchor** | Pyth price must be within `MAX_DEVIATION` of Chainlink; revert otherwise |
| **Staleness check** | Reject Pyth prices older than `MAX_STALENESS` (10-30s) |
| **Confidence check** | Reject prices with wide confidence interval (`conf/price > MAX_CONFIDENCE_BPS`) |
| **Circuit Breakers** | If price moves >X% in 1 block, pause system |

```solidity
// Validation pipeline in PythChainlinkOracle
// 1. Pyth staleness (reverts if stale — no Chainlink fallback)
PythStructs.Price memory price = pyth.getPriceNoOlderThan(feedId, MAX_STALENESS);

// 2. Confidence interval check
if (price.conf * BPS_DENOMINATOR / uint64(abs(price.price)) > MAX_CONFIDENCE_BPS)
    revert ConfidenceTooWide();

// 3. Chainlink deviation anchor (circuit breaker, not fallback)
uint256 deviation = _calculateDeviation(pythPrice, chainlinkPrice);
if (deviation > MAX_DEVIATION) revert PriceDeviationTooHigh();
```

---

## 5. Stablecoin Risk (USDC Depeg)

### The Problem

The entire Vault is denominated in USDC. If USDC loses parity (as in March 2023), the protocol collapses:

- LPs suffer loss of deposit value.
- Traders can exploit depeg for arbitrage.
- Solvency mechanism (Bonding) may not work if USDC is worth 0.

### Solutions (Trade-offs)

| Option | Pros | Cons |
|:---|:---|:---|
| **Accept the risk** | Simplicity, clean UX | Exposure to Circle/regulators |
| **Multi-stablecoin Vault** | Diversification | Complexity, correlation risk |
| **ETH/wBTC backing** | Decentralized | Volatility, complexity |
| **Pause on depeg** | Limits damage | Can cause panic |

**Our position:** For V1, we accept USDC risk with circuit breakers. Off-chain monitoring of USDC peg with automatic pause if deviates >2%.

---

## 6. Trade-offs Summary Table

| Feature | Advantage | Disadvantage (Trade-off) |
|:---|:---|:---|
| **Single-Sided Liquidity** | High efficiency, no slippage by size | Insolvency risk if OI not managed |
| **Pyth Pull Oracle** | Sub-second prices, 128+ publishers, near-zero cost | Wormhole dependency, pull model requires frontend integration |
| **Chainlink Deviation Anchor** | Protects against Pyth anomalies | Third-party dependency, Chainlink latency limits anchor precision |
| **No Fallback (Revert on Stale)** | Prevents high-leverage execution on stale prices | Temporary trade unavailability during Pyth outages |
| **High Max Leverage (100x)** | Attracts retail/degens | Higher variance and bad debt risk |
| **Profit Cap (7x-9x)** | Protects Vault | Limits upside for successful traders |
| **Bonding over Mint** | More controlled than direct minting | Requires demand for $SYNTH |

---

## 7. Risk Matrix

| Risk | Probability | Impact | Mitigation | Residual Risk |
|:---|:---|:---|:---|:---|
| Latency Arbitrage | Medium | High | Pyth sub-second updates + Spread | Medium-Low |
| Vault Insolvency | Medium | Critical | 4-layer defense | Low |
| Oracle Manipulation | Low | Critical | Pyth (128+ publishers) + Chainlink anchor | Low |
| Liquidation Front-run | Medium | Medium | Lookbacks + Fixed reward | Low |
| USDC Depeg | Low | High | Circuit breaker + Monitoring | Medium |
| Smart Contract Bug | Low | Critical | Audits + Bug Bounty | Low |

---

**See also:**
- [Guide 5: Solidity Implementation](./05-implementation.md) - Mitigation code
- [Guide 8: Security](./08-security.md) - Complete threat model
