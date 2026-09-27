# Guide 4: Trade-offs and Risks

**Prerequisites:** [Guide 3: Technical Architecture](./03-architecture.md)
**Next:** [Guide 5: Implementation](./05-implementation.md)

**Status:** Proof of concept. Not audited and not deployed.

---

## Table of Contents

1. [Latency Arbitrage](#1-latency-arbitrage)
2. [LP Solvency](#2-lp-solvency)
3. [Liquidations](#3-liquidations)
4. [Oracle Failure and Manipulation](#4-oracle-failure-and-manipulation)
5. [Stablecoin Risk](#5-stablecoin-risk)
6. [Trade-offs Summary](#6-trade-offs-summary)
7. [Risk Summary](#7-risk-summary)

---

Oracle-priced trading protocols with a single liquidity pool share a set of known risks. For each one,
this guide states what the code does and what it does not do.

---

## 1. Latency Arbitrage

### The problem

The on-chain price lags the market. A trader who sees the market move before the oracle price used for
execution can open at the old price and close at the new one.

### What the code does

- The caller submits the Pyth update. The oracle accepts it if it is at most 30 seconds old and newer
  than the price already stored on-chain.
- Confidence above 2% of the price, or a Pyth price more than 3% away from Chainlink, makes the call
  revert.
- A spread (5 BPS base in `script/Deploy.s.sol`) is charged on open and close, plus 0.08% of notional on
  open and on close.

### What remains

Within the 30 second window the caller chooses which update to submit. A trader can open with an older
update after seeing a newer one, then close with the newer one, and there is no minimum holding time
(open and close in the same block are allowed). With the deploy parameters the round trip costs about
2 x (5 BPS + 8 BPS) = 26 BPS of notional, so a price move larger than that inside the window is a
low-risk trade against the vault. This is current behaviour and is flagged for review.

### Alternative not implemented: delayed execution

1. The trader submits a request.
2. A keeper executes it later with a price published after the request.

This removes the choice of price at the cost of a two-step flow.

---

## 2. LP Solvency

### The problem

LPs are the counterparty to every trade. If traders are net profitable, for example many leveraged longs
in a strong rally, the vault pays them and LPs lose part of their deposit. In the extreme, profits owed can
exceed the vault balance.

### What the code does

```
┌─────────────────────────────────────────────────────────────────────┐
│ LAYER 1: PREVENTIVE                                                 │
│ ├── Payout cap: 9x collateral (maximum profit 8x)                   │
│ ├── Static per-pair OI cap (long + short), set by the owner         │
│ └── Dynamic spread: base + OI term + keeper-set volatility term     │
├─────────────────────────────────────────────────────────────────────┤
│ FUNDING                                                             │
│ └── Heavier side pays; settled against the vault                    │
├─────────────────────────────────────────────────────────────────────┤
│ LAYER 2: ASSISTANT FUND                                             │
│ ├── Receives 20% of fees when set as the treasury                   │
│ └── Injected into the vault by checkAndAct below 100% CR            │
├─────────────────────────────────────────────────────────────────────┤
│ LAYER 3: BONDING                                                    │
│ ├── Opened by checkAndAct below 95% CR if a shortfall remains       │
│ └── Discounted $SYNTH sale, USDC to the vault                       │
└─────────────────────────────────────────────────────────────────────┘
```

### What remains

- **Open interest caps do not adapt to volatility.** A formula such as
  `MaxOI = BaseOI x (TargetVol / CurrentVol)` was designed but not implemented. There is no global OI cap.
- **Funding magnitude.** The funding rate is `3.6e-5` of position size per hour per USD of imbalance
  ([Guide 2](./02-mathematics.md#6-funding)); a 100,000 USD imbalance gives 360% per hour. Positions on the
  lighter side can collect up to the payout cap within minutes while the heavier side is liquidated. If
  the heavier positions are not liquidated in the short window where the liquidator reward is non-zero,
  their loss is capped at their collateral while the lighter side keeps accruing, and the vault pays the
  difference. This is current behaviour and is flagged for review.
- **The vault ratio ignores open PnL.** Layers 2 and 3 react to realised losses only, measured as the share
  price relative to 1.0.
- **Winning closes can revert.** If the vault holds less USDC than the profit owed, `closeTrade` and
  `executeLimit` revert until the vault is refilled.
- **Layer 3 depends on $SYNTH demand.** The bond price comes from an owner-set `referencePrice`, not a
  market price.

---

## 3. Liquidations

### The problem

1. A position near the threshold may be closed by its owner first.
2. Bots compete for the reward.
3. Block producers can reorder transactions.
4. Positions that nobody liquidates keep an open claim on the vault.

### What the code does

- `liquidate` is permissionless and not paused with trading.
- The reward is 10% of the collateral left after the loss, which is at most 1% of collateral and zero once
  the loss reaches the full collateral.
- The loss is computed at the trader-favourable edge of the Pyth confidence band.

### What remains

- `closeTrade` does not check liquidatability, so an owner can close a position that is already past the
  threshold and recover the remaining collateral minus the close fee, which a liquidation would have split
  between the vault and the liquidator.
- A position whose loss has passed 100% of collateral pays no liquidation reward, so nobody is paid to
  close it. If the price recovers, the owner can still close it with a payout.
- The reward on the smallest positions (10 USDC minimum collateral) is at most about 0.1 USDC.
- The opening guard does not include the close spread, so with a large spread and high leverage a new
  position can be liquidatable in the same block.
- Liquidation uses only the submitted price. Lookbacks (liquidating if the price touched the level
  earlier) are not implemented.

---

## 4. Oracle Failure and Manipulation

### The problem

A manipulated or wrong price can trigger unfair liquidations, allow trades at favourable prices, or
drain the vault. An unavailable price stops the protocol.

### What the code does

| Protection | Implementation |
|:---|:---|
| No DEX pool prices | Pyth price with a Chainlink deviation check only |
| Signed updates | Pyth verifies the update data on-chain (`updatePriceFeeds`) |
| Deviation check | Revert if Pyth and Chainlink differ by more than 3% |
| Staleness | Revert if the Pyth price is older than 30 s or the Chainlink answer older than its heartbeat |
| Confidence | Revert if the Pyth confidence exceeds 2% of the price |

The oracle design and the dropped custom oracle network are described in
[Guide 3](./03-architecture.md#3-oracle-design-note).

### What remains

- Any failed check reverts `closeTrade`, `executeLimit` and `liquidate` as well as `openTrade`, so an
  oracle outage or a sustained Pyth/Chainlink disagreement freezes all positions. Funding keeps accruing
  and is settled when prices return.
- There is no price circuit breaker, volume limit or automatic pause.
- There is no L2 sequencer uptime check.
- The 3% deviation band is wide compared to the spread and fees, and the caller chooses the update within
  the staleness window.

---

## 5. Stablecoin Risk

The vault, collateral and payouts are all USDC. A USDC depeg changes the real value of every balance, and
Layer 3 bonding sells $SYNTH for USDC. The code does nothing specific about a depeg: there is no peg
monitor and no automatic pause. The owner can pause trading and the vault manually.

| Option | Pros | Cons |
|:---|:---|:---|
| Accept the risk (current) | Simple | Full exposure to the issuer |
| Several stablecoins | Diversification | Complexity, correlated failures |
| Pause on depeg | Limits damage | Needs a peg source and an operator |

---

## 6. Trade-offs Summary

| Choice | Advantage | Cost |
|:---|:---|:---|
| Single USDC vault | Shared liquidity for all pairs | LPs carry all trader PnL |
| Pyth pull updates | Fresh prices without running oracle infrastructure | Caller chooses the update within 30 s; frontends and bots must fetch update data |
| Chainlink as deviation check only | Catches large Pyth anomalies | A Chainlink outage or disagreement stops the protocol |
| Revert instead of fallback | No execution at a stale price | No closes or liquidations during an outage |
| High per-pair leverage | Configurable by the owner | Fees reach 8% of collateral per side at 100x; small price moves trigger liquidation |
| Payout cap 9x | Bounds the payout per trade | Limits trader upside |
| Bonding with an owner-set price | Recapitalisation without a market oracle | Depends on $SYNTH demand and on the owner's price |

---

## 7. Risk Summary

Qualitative, as assessed in this review.

| Risk | What the code does | Remaining exposure |
|:---|:---|:---|
| Latency arbitrage | 30 s staleness, spread, fees | Caller chooses the update; no minimum holding time |
| Vault insolvency | Payout cap, static OI cap, reserve, bonding | Funding magnitude, ratio ignores open PnL, winning closes revert when the vault is short |
| Oracle manipulation | Signed Pyth updates, Chainlink deviation check, confidence cap | 3% band |
| Oracle outage | Revert | All positions frozen |
| Liquidation incentives | Permissionless, reward from collateral | Zero reward past 100% loss; small rewards on small positions |
| USDC depeg | None beyond manual pause | Full |
| Smart contract bugs | Unit, fuzz, invariant and integration tests | Not audited |

---

**See also:**
- [Guide 5: Implementation](./05-implementation.md)
- [Guide 8: Security](./08-security.md)
