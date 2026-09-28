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

- The caller submits the Pyth update. The oracle accepts it if it is at most `maxPriceAge` old (5 s by
  default, owner-set up to 30 s), not published after `block.timestamp`, and newer than the price already
  stored on-chain.
- Confidence above 2% of the price, or a Pyth price more than 3% away from Chainlink, makes the call
  revert.
- A spread (5 BPS base in `script/Deploy.s.sol`) is charged on open and close, plus 0.08% of notional on
  open and on close.

### What remains (residual)

Within the `maxPriceAge` window the caller still chooses which update to submit: a trader can open with an
update up to 5 seconds old after seeing a newer price, then close with the newer one, and there is no
minimum holding time. With the deploy parameters the round trip costs about 2 x (5 BPS + 8 BPS) = 26 BPS
of notional, so the trade only pays when the price moves more than that within 5 seconds. Before round 2
the window was 30 seconds; the round 1 scenario (open on a 25 second old update, close on the current
one) now reverts (`test_Regression_OracleLatency_OpenOnUpdateAged25sReverts`).

Why 5 seconds on Arbitrum: Pyth updates pushed on-chain by bots were included 0 to 2 seconds after
publication in the sample of [Guide 3](./03-architecture.md#2-oracle), and Arbitrum sequences transactions
in well under a second, so 5 seconds leaves about 3 seconds for a user transaction that fetches its update
when it is submitted. A wallet that asks the user to confirm after fetching the update can exceed it; the
owner can raise the limit up to 30 seconds, at the cost of a wider window.

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
│ └── Heavier side pays the lighter side, capped at 0.01% per hour    │
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
- **Funding bad debt.** Funding is zero-sum between traders and capped at 0.01% of the heavier side's
  notional per hour ([Guide 2](./02-mathematics.md#6-funding)). Receivers are credited as funding accrues,
  payers settle when they close or are liquidated; if a payer ends with a loss above its collateral, the
  unpaid part of its funding stays with the vault. At a flat price this needs a payer at 100x to stay
  unliquidated for more than 9.5 hours after crossing the threshold, and then grows by at most 1% of its
  collateral per hour.
- **NAV biases.** The share price and CR use a conservative NAV that ignores the 9x payout cap
  (conservative), lets positions past 100% loss offset winners on their side until liquidated (optimistic,
  bounded by their excess loss) and does not add net trader losses
  ([Guide 2, section 8.2](./02-mathematics.md#82-known-biases-of-the-nav)).
- **Snapshot age window.** Deposits and withdrawals can use a snapshot up to `maxPnlSnapshotAge` old (60 s by
  default, owner-set up to 3,600 s) if no position opened or closed since.
- **Deposits have no lock.** A new LP can enter while traders are net losing and share in those losses.
  Deposits revert below 100% coverage, which can last indefinitely
  ([Guide 7](./07-vault-ssl.md#known-biases-and-the-deposit-freeze)).
- **Winning closes can revert.** If the vault holds less USDC than the profit owed, `closeTrade` and
  `executeLimit` revert with `InsufficientVaultBalance` until the vault is refilled. No code change in
  round 2; the trader can retry after the vault receives USDC.
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
- The reward is `max(10% of the collateral left after the loss, 0.5% of the collateral)`: 1% of the
  collateral at the threshold and never below 0.5%, including past a 100% loss. It is always paid from the
  position's collateral.
- The loss is computed at the trader-favourable edge of the Pyth confidence band.

### What remains

- `closeTrade` does not check liquidatability, so an owner can close a position that is already past the
  threshold and recover the remaining collateral minus the close fee, which a liquidation would have split
  between the vault and the liquidator.
- The reward on the smallest positions (10 USDC minimum collateral) is between about 0.046 and 0.092 USDC
  at 100x.
- The opening guard rejects any position that `liquidate` would accept in the same block at an unchanged
  price (close spread at the post-open OI, collateral net of the open fee).
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
| Staleness | Revert if the Pyth price is older than `maxPriceAge` (5 s by default) or the Chainlink answer older than its heartbeat |
| Sequencer | Revert while the L2 sequencer is down and for 1 hour after it comes back (Chainlink uptime feed, optional) |
| Confidence | Revert if the Pyth confidence exceeds 2% of the price |

The oracle design and the dropped custom oracle network are described in
[Guide 3](./03-architecture.md#3-oracle-design-note).

### What remains

- Any failed check reverts `closeTrade`, `executeLimit` and `liquidate` as well as `openTrade`, so an
  oracle outage or a sustained Pyth/Chainlink disagreement freezes all positions. Funding keeps accruing
  and is settled when prices return.
- There is no price circuit breaker, volume limit or automatic pause.
- The sequencer grace period also blocks closes and liquidations for one hour after an outage.
- The 3% deviation band is wide compared to the spread and fees, and the caller chooses the update within
  the `maxPriceAge` window.

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
| Pyth pull updates | Fresh prices without running oracle infrastructure | Caller chooses the update within `maxPriceAge` (5 s); frontends and bots must fetch update data (Hermes needs an API key) |
| Chainlink as deviation check only | Catches large Pyth anomalies | A Chainlink outage or disagreement stops the protocol |
| Revert instead of fallback | No execution at a stale price | No closes or liquidations during an outage |
| Leverage up to 100x | Configurable per pair by the owner, capped by `MAX_LEVERAGE` | Fees reach 8% of collateral per side at 100x; small price moves trigger liquidation |
| Payout cap 9x | Bounds the payout per trade | Limits trader upside |
| Bonding with an owner-set price | Recapitalisation without a market oracle | Depends on $SYNTH demand and on the owner's price |

---

## 7. Risk Summary

Qualitative, as assessed in this review.

| Risk | What the code does | Remaining exposure |
|:---|:---|:---|
| Latency arbitrage | 5 s price age, spread, fees | Caller chooses the update within 5 s; no minimum holding time |
| Vault insolvency | Payout cap, static OI cap, reserve, bonding, zero-sum capped funding, NAV with open PnL | Funding bad debt when payers are liquidated late, NAV biases, deposits without a lock, winning closes revert when the vault is short |
| Oracle manipulation | Signed Pyth updates, Chainlink deviation check, confidence cap | 3% band |
| Oracle outage | Revert | All positions frozen |
| Liquidation incentives | Permissionless, reward from collateral with a 0.5% floor | Small rewards on small positions |
| USDC depeg | None beyond manual pause | Full |
| Smart contract bugs | Unit, fuzz, invariant and integration tests | Not audited |

---

**See also:**
- [Guide 5: Implementation](./05-implementation.md)
- [Guide 8: Security](./08-security.md)
