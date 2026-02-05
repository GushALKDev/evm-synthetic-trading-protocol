# 📘 Guide 1: Fundamentals of the Synthetic Trading Protocol

**Version:** 1.0
**Next:** [Guide 2: Protocol Mathematics](./02-mathematics.md)

---

## 📋 Table of Contents

1. [Introduction](#1-introduction)
2. [System Philosophy: Player vs House](#2-system-philosophy-player-vs-house)
3. [Key Concepts](#3-key-concepts)
4. [Hybrid Solvency Mechanism](#4-hybrid-solvency-mechanism)
5. [Trade Lifecycle](#5-trade-lifecycle)

---

## 1. Introduction

The **Synthetic Trading Protocol** is a decentralized platform for trading synthetic futures. Unlike traditional exchanges (CEX) or AMM-based DEXs (like Uniswap), this protocol uses a **Single-Sided Liquidity** model where traders operate directly against a unified **Vault**.

### What are we building?

A platform where users can speculate on price movements of:
- **Crypto:** BTC, ETH, SOL, etc.
- **Forex:** EUR/USD, GBP/USD, etc.
- **Commodities:** Gold, Oil, etc.

**With high leverage and without needing to own the underlying asset.**

### Why is it different?

| Feature | CEX (Binance) | AMM (Uniswap) | Synthetic Trading Protocol |
|:---|:---|:---|:---|
| Counterparty | Other traders | Dual pool (50/50) | Single USDC Vault |
| Fragmentation | Per pair | Per pair | **Zero** (one pool for all) |
| Price Impact | Order book depth | AMM curve | **Zero** (oracle price) |
| Real Asset | Yes | Yes | **No** (synthetic) |

---

## 2. System Philosophy: Player vs House

### 2.1 The Counterparty Model

In this protocol, there's no "trader A buying from trader B". It's a **PvP (Player vs Pool)** model:

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│   TRADER wins ──────► Extracts USDC from Vault             │
│                                                             │
│   TRADER loses ────► Collateral stays in Vault             │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   LPs (Liquidity Providers) = "THE HOUSE"                  │
│   • Deposit USDC into the Vault                            │
│   • Assume risk of trader profits                          │
│   • Receive trader losses + fees                           │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

### 2.2 Extreme Capital Efficiency

- **Unified Pool:** Instead of having an ETH/USDC pool, a BTC/USDC pool, etc., there's **a single USDC pool**.
- This pool backs **all** trading pairs simultaneously.
- **Result:** Maximum liquidity depth and zero fragmentation.

### 2.3 "Zero Price Impact" Execution

Since assets are synthetic, a $1M buy order on BTC **doesn't move the real BTC price** in the spot market.

- Execution price is determined by the **Decentralized Oracle Network (DON)**.
- To simulate real conditions and protect the protocol, a **Dynamic Spread** is applied based on Open Interest and volatility.

> **See:** [Guide 2: Mathematics](./02-mathematics.md) for Spread formulas.

---

## 3. Key Concepts

| Concept | Definition |
|:---|:---|
| **Synthetic** | Financial instrument that replicates an asset's price without requiring physical ownership. |
| **Open Interest (OI)** | Total value (in USD) of all open positions. The protocol's "live risk". |
| **Collateral** | Initial margin deposited by the user (e.g., 100 USDC). |
| **Leverage** | Multiplier on collateral. `Size = Collateral × Leverage`. |
| **ERC-4626** | "Tokenized Vault" standard. LPs deposit USDC and receive `sToken` (shares) representing their pool portion. |
| **Long** | Position that profits if price **rises**. |
| **Short** | Position that profits if price **falls**. |
| **Profit Cap** | Maximum profit per trade (7x-9x of collateral). Protects the Vault. |
| **DON** | Decentralized Oracle Network. Network of 6-8 nodes providing aggregated prices. |

---

## 4. Hybrid Solvency Mechanism

One of the biggest risks in "PvP" models is traders winning more money than exists in the Vault (**Black Swan Event**).

The Synthetic Trading Protocol mitigates this with a **three-layer defense system**:

```
┌─────────────────────────────────────────────────────────────────────┐
│ LAYER 1: PREVENTIVE                                                 │
│ ├── Profit Caps: Profits limited to 7x-9x of collateral            │
│ ├── Dynamic Spread: Higher spread with high OI/volatility          │
│ └── OI Caps: Maximum exposure limits per pair and globally         │
├─────────────────────────────────────────────────────────────────────┤
│ LAYER 2: REACTIVE (Assistant Fund)                                  │
│ ├── USDC capital reserve                                            │
│ ├── Funded by 20% of trading fees                                  │
│ └── Injects capital into Vault if deficit (no $SYNTH dilution)     │
├─────────────────────────────────────────────────────────────────────┤
│ LAYER 3: LAST RESORT (Bonding)                                      │
│ ├── Issue $SYNTH bonds at discount                                 │
│ ├── Arbitrageurs buy $SYNTH → Protocol receives USDC               │
│ └── USDC recapitalizes the Vault                                    │
└─────────────────────────────────────────────────────────────────────┘
```

> **Full technical detail:** [GUIDE 7: Vault SSL Architecture](./07-vault-ssl.md)

### Bankruptcy Prevention

The scenario where both Assistant Fund and Bonding fail simultaneously is **bankruptcy**. To prevent it:

1. **Aggressive OI control:** Especially in early phases, Open Interest limits are very conservative.
2. **Strong dynamic spreads:** Higher OI and volatility = higher spread, discouraging new positions.
3. **Strict profit caps:** Profits limited to 7x-9x, reducing maximum possible payout.
4. **Volatility-based Adaptive OI:** Higher asset volatility = lower maximum OI allowed and higher spread. This protects the Vault during periods of high uncertainty.

---

## 5. Trade Lifecycle

### 5.1 Opening

1. User deposits **collateral** (e.g., 100 USDC).
2. Chooses **pair**, **leverage** (e.g., 10x), and **direction** (Long/Short).
3. The **DON** provides entry price (median of 3 best prices from 6-8 nodes).
4. Collateral enters the **Vault**.
5. Position is registered in **TradingStorage**.

### 5.2 Maintenance

- User pays **Funding Fees** if position remains open (proportional to Long/Short imbalance).
- Position can be closed manually or automatically by:
  - **Take Profit (TP):** Target price reached.
  - **Stop Loss (SL):** Maximum loss reached.
  - **Liquidation:** Loss >= 90% of collateral.

### 5.3 Closing with Profit

1. User calls `closeTrade()` or a Keeper executes TP.
2. The **DON** determines exit price.
3. Vault returns: `Collateral + Profit` (max 7x-9x collateral).

### 5.4 Liquidation

1. Price moves against user until loss >= 90% of collateral.
2. A **liquidator bot** detects the at-risk position.
3. Bot calls `liquidate(tradeId)`.
4. Oracle validates price:
   - **If confirms liquidation:** Position closes, Vault retains remaining collateral, bot receives reward.
   - **If doesn't confirm:** Transaction fails, trade continues open in "non-liquidatable" zone.

> **Phase 2 (Lookbacks):** Historical checks will be added. If price *entered* liquidation zone at any point, position will be liquidated even if current price has returned to safe zone.

---

**See also:**
- [Guide 2: Mathematics](./02-mathematics.md) - PnL, Spread, Funding formulas
- [Guide 7: Vault SSL](./07-vault-ssl.md) - Detailed solvency architecture
