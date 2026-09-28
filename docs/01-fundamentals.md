# Guide 1: Fundamentals of the Synthetic Trading Protocol

**Next:** [Guide 2: Protocol Mathematics](./02-mathematics.md)

**Status:** Proof of concept. Not audited and not deployed.

---

## Table of Contents

1. [Introduction](#1-introduction)
2. [Counterparty Model: Traders vs the Vault](#2-counterparty-model-traders-vs-the-vault)
3. [Key Concepts](#3-key-concepts)
4. [Solvency Layers](#4-solvency-layers)
5. [Trade Lifecycle](#5-trade-lifecycle)

---

## 1. Introduction

The protocol lets traders take leveraged long or short positions on assets priced by an oracle,
without holding the asset. All trades are made against one USDC vault funded by liquidity providers
(LPs), instead of against other traders or an AMM pool.

### What can be traded

Any pair the owner configures with a Pyth feed ID and a Chainlink feed (`PythChainlinkOracle.setPairFeed`
and `TradingStorage.addPair`). The code has no per-asset-class logic: there are no market hours, weekend
closures or asset-class parameters, so forex or commodity pairs would be treated the same way as
crypto pairs. The tests use BTC/USD and ETH/USD.

### How it differs from other venues

| Feature | Order book exchange | AMM | This protocol |
|:---|:---|:---|:---|
| Counterparty | Other traders | Liquidity pool per pair | One USDC vault for all pairs |
| Liquidity | Per pair | Per pair | Shared by all pairs |
| Execution price | Order book | AMM curve | Oracle price plus a spread that grows with open interest and volatility |
| Asset delivered | Yes | Yes | No (synthetic exposure) |

---

## 2. Counterparty Model: Traders vs the Vault

### 2.1 Who pays whom

```
┌─────────────────────────────────────────────────────────────┐
│                                                             │
│   Trader closes with profit ──► profit is paid from Vault   │
│                                                             │
│   Trader closes with loss ────► lost collateral moves from  │
│                                  TradingStorage to Vault    │
│                                                             │
├─────────────────────────────────────────────────────────────┤
│                                                             │
│   LPs                                                       │
│   • Deposit USDC into the Vault, receive sUSDC shares       │
│   • Carry the PnL of all open trades                        │
│   • Receive trader losses and 80% of trading fees           │
│                                                             │
└─────────────────────────────────────────────────────────────┘
```

LPs are the counterparty to trader PnL. When traders are net profitable, the vault share price falls
and LPs lose part of their deposit. The vault holds only USDC, so there is no impermanent loss in the
AMM sense, but LP returns are the mirror image of trader returns plus fees.

### 2.2 One pool for all pairs

A single USDC vault backs every pair. This avoids splitting liquidity per pair, and it also means a
large loss on one pair reduces the liquidity available to pay winners on every other pair.

### 2.3 Oracle execution

A large order does not move the reference price, because the asset is not traded. The execution price is
the Pyth price submitted with the transaction, adjusted by a spread computed by `SpreadManager` from
the pair's open interest and a keeper-supplied volatility value.

> **See:** [Guide 2: Mathematics](./02-mathematics.md) for the spread formula.

---

## 3. Key Concepts

| Concept | Definition |
|:---|:---|
| **Synthetic position** | Exposure to an asset's price without owning the asset. |
| **Open interest (OI)** | Sum of position sizes (collateral x leverage) on a pair, tracked separately for longs and shorts. |
| **Collateral** | USDC deposited by the trader (minimum 10 USDC, `TradingEngine.MIN_COLLATERAL`). The stored collateral is the deposit minus the open fee. |
| **Leverage** | `Size = Collateral x Leverage`. The maximum is set per pair by the owner, up to the global `MAX_LEVERAGE` of 100. |
| **ERC-4626** | Tokenized vault standard. LPs deposit USDC and receive sUSDC shares. |
| **Long / Short** | A long profits when the price rises, a short when it falls. |
| **Payout cap** | Collateral plus price PnL is capped at 9x the stored collateral (`MAX_PROFIT_MULTIPLIER = 9`), so the maximum price profit is 8x collateral. Funding is settled after the cap. |
| **Funding** | A transfer between the traders of a pair: the heavier side pays the lighter side, at most 0.01% of the heavier side's notional per hour. |
| **Pyth** | Pull oracle: the caller submits a signed price update, which the Pyth contract verifies on-chain. |

---

## 4. Solvency Layers

The main risk of a single-counterparty vault is that traders win more than the vault holds. The design
describes three layers:

```
┌─────────────────────────────────────────────────────────────────────┐
│ LAYER 1: PREVENTIVE                                                 │
│ ├── Payout cap: at most 9x collateral per trade (price PnL)         │
│ ├── Dynamic spread: grows with OI and keeper-set volatility         │
│ └── OI cap: static per-pair cap on long + short OI, set by owner    │
├─────────────────────────────────────────────────────────────────────┤
│ LAYER 2: RESERVE (AssistantFund)                                    │
│ ├── USDC reserve                                                    │
│ ├── Receives the 20% fee share when it is set as the treasury       │
│ └── Injected into the Vault when CR < 100% (fresh PnL snapshot)     │
├─────────────────────────────────────────────────────────────────────┤
│ LAYER 3: BONDING (BondDepository)                                   │
│ ├── Opened when realised CR < 95% and a realised deficit remains    │
│ ├── Anyone buys $SYNTH at a discount, vested linearly               │
│ └── The USDC goes to the Vault                                      │
└─────────────────────────────────────────────────────────────────────┘
```

CR here is `Vault.collateralizationRatio()`, the LP principal coverage ratio: the vault share price at a
conservative NAV (USDC balance minus the net unrealised trader profit of the latest PnL snapshot) relative to
1.0 USDC per share. Realised CR is the same ratio on the USDC balance alone; bonding uses it so that an
unrealised move that can reverse does not sell discounted $SYNTH. A deposit first runs the pending reserve
injection and reverts while a bonding round is open or due.

Layer 1 is preventive: payout cap, static OI cap and dynamic spread; volatility-adaptive OI caps are
designed only. Also not implemented: a global OI cap across pairs and a surplus buyback of $SYNTH. Layer 3 depends on buyers valuing $SYNTH, whose reference price is set by the
owner.

> **More detail:** [Guide 7: Vault and Solvency](./07-vault-ssl.md)

---

## 5. Trade Lifecycle

### 5.1 Opening

1. The trader approves USDC and calls `openTrade` with pair, direction, collateral, leverage, expected
   price, slippage tolerance, optional TP/SL and Pyth update data (paying the Pyth fee in `msg.value`).
2. The oracle returns the validated Pyth price (at most 5 s old by default). The engine applies the
   open-direction spread, checks slippage, and rejects the trade if `liquidate` would accept it in the
   same block at an unchanged price.
3. The collateral moves to `TradingStorage`. The open fee (0.08% of notional) is taken from it and split
   80% to the vault and 20% to the treasury.
4. The trade is stored with the collateral net of the fee, and pair OI increases by the position size.
   The call reverts if long + short OI would exceed the pair cap.

### 5.2 While open

- Funding accrues according to the relative long/short skew of the pair: the heavier side pays, the
  lighter side receives the same total pro rata. It is settled on close or liquidation.
- The position can end by a manual close, by `executeLimit` when the TP or SL price is crossed (anyone can
  call it), or by `liquidate` when the funding-adjusted loss reaches 90% of collateral (anyone can call it).

### 5.3 Closing with profit

1. The trader calls `closeTrade`, or anyone calls `executeLimit` once the TP is crossed.
2. The exit price is the Pyth price with the close-direction spread.
3. The payout is collateral plus price PnL capped at 9x collateral, minus the funding owed (or plus the
   funding received), minus the close fee (0.08% of notional). `TradingStorage` returns the collateral part and the vault pays the rest through
   `sendPayout`. With `executeLimit`, 0.1% of notional is taken from the payout for the caller.
4. If the vault holds less USDC than the profit owed, the call reverts.

### 5.4 Liquidation

1. The loss, including funding, reaches 90% of the stored collateral.
2. A bot calls `liquidate(tradeId, priceUpdate)`.
3. The loss is computed at the trader-favourable edge of the Pyth confidence band (price + conf for longs,
   price - conf for shorts), then with the close-direction spread.
4. If the position qualifies, the caller receives `max(10% of the collateral left after the loss, 0.5% of
   the collateral)` and the rest of the collateral goes to the vault. No close fee is charged. Otherwise
   the call reverts.

The liquidation check uses only the submitted price. Checking whether the price touched the liquidation
level earlier ("lookbacks") is not implemented.

---

**See also:**
- [Guide 2: Mathematics](./02-mathematics.md) for PnL, spread and funding formulas
- [Guide 7: Vault and Solvency](./07-vault-ssl.md) for the solvency layers
