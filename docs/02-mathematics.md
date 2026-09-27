# Guide 2: Protocol Mathematics

**Prerequisites:** [Guide 1: Fundamentals](./01-fundamentals.md)
**Next:** [Guide 3: Technical Architecture](./03-architecture.md)

**Status:** Proof of concept. Not audited and not deployed.

Every formula here is written as the code computes it, with the rounding direction. `floor` is Solidity
integer division on non-negative values; `trunc` is integer division on signed values (rounds toward
zero). Units: USDC amounts have 6 decimals, prices 18 decimals, OI 18 decimals, BPS denominator 10,000.

---

## Table of Contents

1. [Vault Share Price](#1-vault-share-price)
2. [PnL and Payout](#2-pnl-and-payout)
3. [Fees](#3-fees)
4. [Execution Price with Dynamic Spread](#4-execution-price-with-dynamic-spread)
5. [Liquidations](#5-liquidations)
6. [Funding](#6-funding)
7. [Open Interest Cap](#7-open-interest-cap)
8. [Collateralization Ratio and Solvency Actions](#8-collateralization-ratio-and-solvency-actions)
9. [Bonding](#9-bonding)
10. [Parameters](#10-parameters)

---

## 1. Vault Share Price

The vault is a Solady `ERC4626` with `_decimalsOffset() = 12` (USDC 6 decimals, sUSDC 18 decimals).

$$SharePrice = \frac{totalAssets}{totalSupply} \times 10^{12}$$

- `totalAssets()` is the vault's USDC balance. It does not include open trader PnL, open collateral
  (held by `TradingStorage`) or pending fees.
- Deposit and mint follow Solady's ERC-4626 rounding (shares rounded down on `deposit`, assets rounded up
  on `mint`, assets rounded down on `previewRedeem`), with virtual shares from the decimals offset.

| Event | totalAssets | totalSupply | Share price |
|:---|:---|:---|:---|
| Trader closes with a loss of 100 USDC | +100 | = | rises |
| Trader closes with a profit of 100 USDC | -100 | = | falls |
| Fees: 80% of each open and close fee | + | = | rises |
| LP deposits | + | + | unchanged, up to rounding |
| LP executes a withdrawal | - | - | unchanged, up to rounding |

Because only realised PnL changes `totalAssets`, the share price does not move while trades are open.

---

## 2. PnL and Payout

`collateral` is the stored collateral (deposit minus open fee). `size = collateral x leverage`, in USDC
units. `openPrice` already includes the open spread; `exitPrice` includes the close spread
(`TradingEngine._calculatePnl`).

**Long**

$$exitValue = \left\lfloor \frac{exitPrice \times size}{openPrice} \right\rfloor, \qquad PnL = exitValue - size$$

**Short**

$$exitValue = \left\lceil \frac{exitPrice \times size}{openPrice} \right\rceil, \qquad PnL = size - exitValue$$

Both roundings make the trader's result smaller by at most 1 USDC unit, in favour of the vault.

### Example: long 10x

| Step | Value |
|:---|:---|
| Stored collateral | 100 USDC |
| Size | 1,000 USDC |
| openPrice | 2,000 |
| exitPrice | 2,100 |
| PnL | 2,100 x 1,000 / 2,000 - 1,000 = **+50 USDC** |

### Payout (`_calculatePayout`)

With `adjPnl = PnL - fundingOwed` (section 6):

$$payout = \begin{cases} \min(collateral + adjPnl,\ 9 \times collateral) & adjPnl \ge 0 \\ \max(collateral - |adjPnl|,\ 0) & adjPnl < 0 \end{cases}$$

`MAX_PROFIT_MULTIPLIER = 9` caps the payout, not the profit: the largest profit a trade can realise is
8x its collateral. The close fee (section 3) is then subtracted from the payout, down to zero.

---

## 3. Fees

`OPEN_FEE_BPS = CLOSE_FEE_BPS = 8` (0.08% of notional), `FEE_VAULT_SPLIT_BPS = 8000`.

$$openFee = \left\lfloor \frac{depositedCollateral \times leverage \times 8}{10000} \right\rfloor$$

$$closeFee = \min\left(\left\lfloor \frac{storedCollateral \times leverage \times 8}{10000} \right\rfloor,\ payout\right)$$

$$vaultShare = \left\lfloor \frac{fee \times 8000}{10000} \right\rfloor, \qquad treasuryShare = fee - vaultShare$$

- The open fee is charged on the deposited collateral, the close fee on the stored (post-fee) collateral.
- An open reverts with `FeeExceedsCollateral` if `openFee >= depositedCollateral`, which happens from
  1,250x leverage.
- At 100x the open fee is 8% of the deposit and the close fee about 7.4% of it.
- Liquidations charge no close fee. `executeLimit` charges the close fee and also takes
  `floor(storedCollateral x leverage x 10 / 10000)` (0.1% of notional) from the payout for the caller,
  capped at the payout.

---

## 4. Execution Price with Dynamic Spread

### Spread (`SpreadManager.getSpreadBps`)

$$spreadBps = \min\left(baseSpreadBps + \left\lfloor \frac{OI_{pair} \times impactFactor}{10^{30}} \right\rfloor + \left\lfloor \frac{volatility_{pair} \times volFactor}{10^{18}} \right\rfloor,\ maxSpreadBps\right)$$

- `OI_pair` is the pair's long + short OI (18 decimals) read before the trade changes it.
- `volatility_pair` (18 decimals, 3% = 3e16) is written by the keeper with `updateVolatility`. The first
  value for a pair is accepted as is; later values may change by at most `maxVolatilityChangeBps` of the
  current value (a relative bound: 5000 means the new value must be within 50% of the old one).
- `maxSpreadBps` must be below 10,000 and at least `baseSpreadBps`.

How the volatility value is computed is left to the keeper; the contract only stores it.

### Execution price (`TradingEngine._applySpread`)

| Direction | Formula |
|:---|:---|
| Long open, short close | `floor(oraclePrice x (10000 + spreadBps) / 10000)` |
| Long close, short open | `floor(oraclePrice x (10000 - spreadBps) / 10000)` |

Flooring the upward case rounds the price down by less than one unit of its 18 decimals, which is
negligible.

### Examples with the `script/Deploy.s.sol` parameters

`baseSpreadBps = 5`, `impactFactor = 3e5`, `volFactor = 100`, `maxSpreadBps = 100`.

- OI of 10M USD (`1e25`): OI term `1e25 x 3e5 / 1e30 = 3` BPS.
- Volatility 3% (`3e16`): volatility term `3e16 x 100 / 1e18 = 3` BPS.
- Total: 5 + 3 + 3 = 11 BPS. Long open at an oracle price of 50,000: `50,000 x 1.0011 = 50,055`.

---

## 5. Liquidations

`LIQUIDATION_THRESHOLD_BPS = 9000`, `LIQUIDATOR_REWARD_BPS = 1000` (`TradingEngine.liquidate`).

1. Conservative price from the oracle's confidence band: long `price + conf`, short `max(price - conf, 0)`.
2. Close-direction spread applied to that price.
3. `adjPnl = PnL - fundingOwed` with the formulas of sections 2 and 6.
4. Liquidatable when

$$loss = \max(-adjPnl, 0) \ge \left\lfloor \frac{collateral \times 9000}{10000} \right\rfloor$$

5. Distribution:

$$remaining = \max(collateral - loss, 0), \qquad reward = \left\lfloor \frac{remaining \times 1000}{10000} \right\rfloor$$

The caller receives `reward`; the vault receives `collateral - reward`. The reward is at most 1% of the
collateral and is 0 once the loss reaches the full collateral.

### Approximate liquidation price

Ignoring spread, fees, funding and confidence:

$$P_{liq,long} \approx P_{open} \times \left(1 - \frac{0.9}{L}\right), \qquad P_{liq,short} \approx P_{open} \times \left(1 + \frac{0.9}{L}\right)$$

Example: long 10x from 50,000 gives about 45,500. In the code the close spread counts toward the loss, so
the position becomes liquidatable before this price. The contract does not compute or store a
liquidation price.

### Opening guard (`_validateNotPreLiquidatable`)

An open reverts if the loss between the spread-adjusted open price and the raw oracle price already
reaches 90% of the deposited collateral. The guard uses the deposited collateral (before the open fee)
and does not include the close spread that `liquidate` applies, so with a large spread and high leverage a
position can pass the guard and be liquidatable in the same block.

### Example distribution

Stored collateral 100 USDC, loss 90 USDC: remaining 10 USDC, reward 1 USDC to the caller, 99 USDC to the
vault.

---

## 6. Funding

`FundingLib.FUNDING_FACTOR = 1e10`. The index is updated before any OI change on the pair
(`TradingEngine._updateFundingIndex`), using the OI that was in place since the last update.

$$\Delta index = trunc\left(\frac{(OI_{long} - OI_{short}) \times 10^{10} \times \Delta t}{10^{18}}\right)$$

$$raw = trunc\left(\frac{size_{wad} \times (index_{now} - index_{entry})}{10^{18}}\right), \qquad fundingOwed = \begin{cases} trunc(raw / 10^{12}) & long \\ trunc(-raw / 10^{12}) & short \end{cases}$$

A positive `fundingOwed` is paid by the trader (subtracted from PnL); a negative one is received.

### Magnitude

The index moves by `1e10` per second per USD of imbalance, so a position pays or receives `1e-8` of its
size per second, or `3.6e-5` per hour, for each USD of imbalance. The rate is not normalised by open
interest or vault size:

| Imbalance (long OI - short OI) | Funding per hour, as a share of position size |
|:---|:---|
| 1,000 USD | 3.6% |
| 10,000 USD | 36% |
| 100,000 USD | 360% |

With realistic imbalances, positions on the heavier side reach the liquidation threshold within minutes,
and positions on the lighter side receive funding up to the 9x payout cap. This is current behaviour and
is flagged for review.

### Who pays

Funding is settled with the vault, not between traders. Longs and shorts owe opposite amounts per unit of
size, so when OI is balanced the index does not move. When OI is unbalanced, the heavier side pays on a
larger size than the lighter side receives on, and the vault keeps the difference, except when a
paying position's loss is capped at its collateral.

### Rounding

`trunc` rounds toward zero in both directions, so a paying trader pays up to 1 USDC unit less and a
receiving trader receives up to 1 unit less.

---

## 7. Open Interest Cap

`TradingStorage.increaseOpenInterest` reverts when `OI_long + OI_short > maxOI` for the pair.
`positionSize = storedCollateral x leverage x 1e12` (18 decimals). `maxOI` is a static value set by the
owner in `addPair` / `updatePair`. There is no global cap across pairs and no link to volatility.

---

## 8. Collateralization Ratio and Solvency Actions

`Vault.collateralizationRatio()`:

$$CR = \left\lfloor \frac{totalAssets \times 10^{12} \times 10^{18}}{totalSupply} \right\rfloor \quad (\text{type(uint256).max if } totalSupply = 0)$$

This is the share price relative to 1.0 USDC per share (1e18 = 100%), the price at which the first shares
are minted. It does not include open trader PnL, and it does not depend on when each LP deposited.

`Vault.collateralizationDeficit()`:

$$deficit = \max\left(\left\lfloor \frac{totalSupply}{10^{12}} \right\rfloor - totalAssets,\ 0\right)$$

`SolvencyManager.checkAndAct()`:

| State | Condition | Action |
|:---|:---|:---|
| Healthy | CR >= 110% | Emit `Healthy` |
| Warning | 100% <= CR < 110% | Emit `Warning` |
| Deficit | CR < 100% | Inject `min(reserve, deficit)` from the AssistantFund |
| Critical | CR < 95% and deficit not covered and no active round | Also open a bonding round for the shortfall |

No action is taken above 110% (no buyback).

---

## 9. Bonding

`BondDepository`:

$$effectivePrice = \left\lfloor \frac{referencePrice \times (10000 - discountBps)}{10000} \right\rfloor, \qquad synthOut = \left\lfloor \frac{usdcIn \times 10^{18}}{effectivePrice} \right\rfloor$$

- `referencePrice` is USDC (6 decimals) per 1 SYNTH, set by the owner (default 2 USDC).
- `discountBps <= 1000`; `usdcIn` is clamped to the round's remaining cap.
- Vesting is linear: `vested = floor(totalSynth x elapsed / duration)` until the end, then `totalSynth`.

Example: `referencePrice = 1e6` (1 USDC), discount 10%: `effectivePrice = 900,000`, and 1,000 USDC buys
`1,000e6 x 1e18 / 900,000 = 1,111.11` SYNTH.

---

## 10. Parameters

| Parameter | Value | Where it is set |
|:---|:---|:---|
| `MAX_PROFIT_MULTIPLIER` | 9 (payout cap) | `TradingEngine` constant |
| `MIN_COLLATERAL` | 10 USDC | `TradingEngine` constant |
| `OPEN_FEE_BPS`, `CLOSE_FEE_BPS` | 8 (0.08% of notional) | `TradingEngine` constants |
| `FEE_VAULT_SPLIT_BPS` | 8000 (80% vault, 20% treasury) | `TradingEngine` constant |
| `LIQUIDATION_THRESHOLD_BPS` | 9000 | `TradingEngine` constant |
| `LIQUIDATOR_REWARD_BPS` | 1000 (of remaining collateral) | `TradingEngine` constant |
| `EXEC_REWARD_BPS` | 10 (0.1% of notional) | `TradingEngine` constant |
| `maxLeverage` | per pair, `uint16` | `TradingStorage.addPair` (owner); tests use 100 |
| `maxOI` | per pair | `TradingStorage.addPair` (owner) |
| `FUNDING_FACTOR` | 1e10 | `FundingLib` constant |
| `baseSpreadBps` | 5 | `script/Deploy.s.sol` |
| `impactFactor` | 3e5 | `script/Deploy.s.sol` |
| `volFactor` | 100 | `script/Deploy.s.sol` |
| `maxSpreadBps` | 100 | `script/Deploy.s.sol` |
| `maxVolatilityChangeBps` | 5000 (relative) | `script/Deploy.s.sol` |
| `MAX_STALENESS` | 30 s | `PythChainlinkOracle` constant |
| `MAX_CONFIDENCE_BPS` | 200 | `PythChainlinkOracle` constant |
| `MAX_DEVIATION_BPS` | 300 | `PythChainlinkOracle` constant |
| `SAFE_CR`, `DEFICIT_CR`, `CRITICAL_CR` | 110%, 100%, 95% | `SolvencyManager` constants |
| `EPOCH_LENGTH`, `WITHDRAWAL_DELAY_EPOCHS` | 1 day, 3 | `Vault` constants |
| `targetCap` | 1,000,000 USDC | `script/Deploy.s.sol` |
| `discountBps` | 500 | `script/Deploy.s.sol` (max 1000) |
| `vestingPeriod` | 48 h | `BondDepository` constructor (max 7 days) |
| `referencePrice` | 2 USDC | `BondDepository` constructor |

---

**See also:**
- [Guide 3: Technical Architecture](./03-architecture.md)
- [Guide 5: Implementation](./05-implementation.md)
