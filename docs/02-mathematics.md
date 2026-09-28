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

With `fundingOwed` from section 6 (positive when the trader pays):

$$payout = \max\left(collateral + \min(PnL,\ 8 \times collateral) - fundingOwed,\ 0\right)$$

`MAX_PROFIT_MULTIPLIER = 9` caps collateral plus price PnL at 9x the collateral, so the largest price
profit is 8x the collateral. Funding is applied after the cap in both directions: a payer whose price
profit is capped still pays its funding, and a receiver's credit is not cut by the cap, so a payout can
exceed 9x the collateral by the funding credit. The close fee (section 3) is then subtracted from the
payout, down to zero.

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

`LIQUIDATION_THRESHOLD_BPS = 9000`, `LIQUIDATOR_REWARD_BPS = 1000`, `LIQUIDATOR_MIN_REWARD_BPS = 50`
(`TradingEngine.liquidate`).

1. Conservative price from the oracle's confidence band: long `price + conf`, short `max(price - conf, 0)`.
2. Close-direction spread applied to that price.
3. `adjPnl = PnL - fundingOwed` with the formulas of sections 2 and 6.
4. Liquidatable when

$$loss = \max(-adjPnl, 0) \ge \left\lfloor \frac{collateral \times 9000}{10000} \right\rfloor$$

5. Distribution:

$$remaining = \max(collateral - loss, 0), \qquad reward = \max\left(\left\lfloor \frac{remaining \times 1000}{10000} \right\rfloor,\ \left\lfloor \frac{collateral \times 50}{10000} \right\rfloor\right)$$

The caller receives `reward`; the vault receives `collateral - reward`. At the 90% threshold the reward is
1% of the collateral; it falls with the remaining collateral and never below 0.5% of the collateral, also
when the loss reaches or exceeds the collateral. `MIN_COLLATERAL = 10 USDC` keeps the floor above zero
(at least 0.046 USDC on a 10 USDC deposit at 100x). The reward never exceeds the collateral, so the vault
never funds it.

### Approximate liquidation price

Ignoring spread, fees, funding and confidence:

$$P_{liq,long} \approx P_{open} \times \left(1 - \frac{0.9}{L}\right), \qquad P_{liq,short} \approx P_{open} \times \left(1 + \frac{0.9}{L}\right)$$

Example: long 10x from 50,000 gives about 45,500. In the code the close spread counts toward the loss, so
the position becomes liquidatable before this price. The contract does not compute or store a
liquidation price.

### Opening guard (`_validateNotPreLiquidatable`)

An open reverts with `NotLiquidatable(0, loss, threshold)` if `liquidate` would accept the position in
the same block at an unchanged oracle price. The guard evaluates the loss exactly as `liquidate` does in
that situation: stored collateral (deposit minus open fee), open price against the oracle price moved by
the close-direction spread, with the spread computed at the pair OI after the open (which includes the
new position), no funding, and no confidence band (the band only makes liquidation harder).

$$loss_{guard} = \max\left(-PnL(collateral_{stored},\ openPrice,\ closeSpread(oraclePrice, OI + size)),\ 0\right) \ge \left\lfloor \frac{collateral_{stored} \times 9000}{10000} \right\rfloor \Rightarrow revert$$

At 100x with a constant spread `s` on both sides, the loss is about `100 x 2s` of the stored collateral,
so any spread of about 45 BPS or more is rejected at 100x.

### Example distribution

Stored collateral 100 USDC, loss 90 USDC: remaining 10 USDC, reward 1 USDC to the caller, 99 USDC to the
vault.

---

## 6. Funding

Funding is a transfer between the traders of a pair. The heavier side pays, the lighter side receives the
same total, and the vault is not a party to it except through the residual described below
(`FundingLib`, `TradingEngine._updateFundingIndex`).

### Rate

$$skew = \frac{|OI_{long} - OI_{short}|}{OI_{long} + OI_{short}}, \qquad rate_{hour} = \min\left(\left\lfloor \frac{fundingFactor \times |OI_{long} - OI_{short}|}{OI_{long} + OI_{short}} \right\rfloor,\ MAX\_FUNDING\_RATE\_PER\_HOUR\right)$$

- `rate_hour` is the fraction of the heavier side's notional paid per hour (WAD, 1e18 = 100%).
- `MAX_FUNDING_RATE_PER_HOUR = 1e14` (0.01% per hour) is an immutable constant in `FundingLib`.
- `fundingFactor` is the rate at 100% skew. It is stored in `TradingEngine`, starts at
  `DEFAULT_FUNDING_FACTOR = 1e14` and the owner can set it with `setFundingFactor` within
  `[MIN_FUNDING_FACTOR, MAX_FUNDING_FACTOR] = [1e12, 1e15]` (0.0001% to 0.1% per hour at 100% skew; at the
  maximum factor the rate reaches the ceiling at 10% skew). A change accrues every pair at the old factor
  first.
- If either side has zero OI, nothing accrues.

### Indexes

Each pair keeps one cumulative index per side (WAD per unit of notional, positive = paid). Over an interval
`dt` with constant OI (the indexes are updated before every OI change):

$$\Delta index_{heavy} = \left\lceil \frac{rate_{hour} \times dt}{3600} \right\rceil, \qquad \Delta index_{light} = -\left\lfloor \frac{\Delta index_{heavy} \times OI_{heavy}}{OI_{light}} \right\rfloor$$

so `OI_light x |Δindex_light| <= OI_heavy x Δindex_heavy`: the light side is credited at most what the
heavy side is charged. The per-unit rate on the light side is `rate_hour x OI_heavy / OI_light`, which is
large when the light side is small, but its total is bounded by what the heavy side pays.

### Amount owed by a position

$$\Delta = index_{side,now} - index_{side,entry}, \qquad fundingOwed = \begin{cases} \left\lceil \frac{size_{wad} \times \Delta}{10^{30}} \right\rceil & \Delta \ge 0 \\ -\left\lfloor \frac{size_{wad} \times |\Delta|}{10^{30}} \right\rfloor & \Delta < 0 \end{cases}$$

Payers round up and receivers round down, so the sum of `fundingOwed` over all positions of a pair is
between 0 and one unit per position. `fundingOwed` enters the payout after the price cap (section 2) and
the liquidation loss (section 5).

### Example

A 1,000 USDC x100 long (92,000 USD notional) against a 10 USDC x100 short (920 USD notional), default
factor: `rate_hour = floor(1e14 x 91,080 / 92,920)`, about 0.0098% of the long notional per hour. After 60
seconds at an unchanged price the short closes with 7.693836 USDC for its 10 USDC deposit: its funding
credit is smaller than the spread and fees of the round trip. Before round 2 the same short closed with
57.819699 USDC, credited by the vault. Both values come from
`forge test --match-test test_Regression_Funding_SmallShortCannotProfitAtFlatPrice -vv` (after and before
the fix).

### Residual: funding a payer cannot pay

Receivers are credited as funding accrues and can close at any time; a payer settles only when it closes
or is liquidated. The vault fronts a credit until the payer settles. If the payer ends with a loss above
what its collateral covers, the unpaid part stays with the vault:

$$unpaid = \max\left(0,\ fundingOwed - \max\left(0,\ collateral + \min(PnL,\ 8 \times collateral) - reward\right)\right)$$

with `reward = 0` for a close or TP/SL execution and the liquidator reward for a liquidation (the reward
is taken first, then the price loss, then funding).

Worst case with the deployed parameters (ceiling 0.01% per hour, `MAX_LEVERAGE = 100`, liquidation at 90%
of the stored collateral `C`, reward floor 0.5% of `C`): a payer accrues funding at most at
`0.0001 x L x C` per hour, 1% of `C` per hour at 100x. Funding counts toward the liquidation loss, so at a
flat price the position becomes liquidatable with about 10% of `C` left; unpaid funding appears only if
nobody liquidates it for longer than

$$t_0 = \frac{0.1 - 0.005}{0.0001 \times L} \text{ hours} = 9.5 \text{ h at } L = 100$$

after it crosses the threshold, and then grows by at most `0.0001 x L x C` per hour (1% of `C` per hour at
100x). If the price gaps past a 100% loss, the whole accrued `fundingOwed` of that payer is unpaid; since
funding alone would have made it liquidatable, that amount is at most `0.9 x C` plus what accrued during
the liquidation delay. The protocol invariant suite tracks this amount (`ghostFundingBadDebt`) and checks
that the vault's net funding result plus the funding still owed by open positions is never below minus
that amount ([test suite](./tests/README.md)).

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

At CR >= 100% an open bonding round is closed (`closeBonding`, event `BondingClosed`). No other action is
taken above 110% (no buyback).

---

## 9. Bonding

`BondDepository`:

$$effectivePrice = \left\lfloor \frac{referencePrice \times (10000 - discountBps)}{10000} \right\rfloor, \qquad synthOut = \left\lfloor \frac{usdcIn \times 10^{18}}{effectivePrice} \right\rfloor$$

- `referencePrice` is USDC (6 decimals) per 1 SYNTH, set by the owner (default 2 USDC).
- `discountBps <= 1000`; `usdcIn = min(amount, remainingCap, collateralizationDeficit)`, and `bond`
  reverts with `NoActiveRound` when the last two are not both above zero. The bond that takes all that is
  available closes the round, so a round never raises more than the deficit at the time of each bond.
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
| `LIQUIDATOR_MIN_REWARD_BPS` | 50 (of collateral, reward floor) | `TradingEngine` constant |
| `MAX_LEVERAGE` | 100 | `TradingEngine` and `TradingStorage` constants |
| `EXEC_REWARD_BPS` | 10 (0.1% of notional) | `TradingEngine` constant |
| `maxLeverage` | per pair, 1 to `MAX_LEVERAGE` | `TradingStorage.addPair` / `updatePair` (owner) |
| `maxOI` | per pair | `TradingStorage.addPair` (owner) |
| `MAX_FUNDING_RATE_PER_HOUR` | 1e14 (0.01% per hour) | `FundingLib` constant |
| `fundingFactor` | 1e14 by default, owner-set within 1e12 to 1e15 | `TradingEngine.setFundingFactor` |
| `baseSpreadBps` | 5 | `script/Deploy.s.sol` |
| `impactFactor` | 3e5 | `script/Deploy.s.sol` |
| `volFactor` | 100 | `script/Deploy.s.sol` |
| `maxSpreadBps` | 100 | `script/Deploy.s.sol` |
| `maxVolatilityChangeBps` | 5000 (relative) | `script/Deploy.s.sol` |
| `MAX_STALENESS` | 30 s, ceiling for `maxPriceAge` | `PythChainlinkOracle` constant |
| `maxPriceAge` | 5 s by default, owner-set within 1 to 30 s | `PythChainlinkOracle.setMaxPriceAge` |
| `SEQUENCER_GRACE_PERIOD` | 3600 s | `PythChainlinkOracle` constant |
| `MAX_CONFIDENCE_BPS` | 200 | `PythChainlinkOracle` constant |
| `MAX_DEVIATION_BPS` | 300 | `PythChainlinkOracle` constant |
| `SAFE_CR`, `DEFICIT_CR`, `CRITICAL_CR` | 110%, 100%, 95% | `SolvencyManager` constants |
| `EPOCH_LENGTH`, `WITHDRAWAL_DELAY_EPOCHS`, `WITHDRAWAL_WINDOW_EPOCHS` | 1 day, 3, 1 | `Vault` constants |
| `targetCap` | 1,000,000 USDC | `script/Deploy.s.sol` |
| `discountBps` | 500 | `script/Deploy.s.sol` (max 1000) |
| `vestingPeriod` | 48 h | `BondDepository` constructor (max 7 days) |
| `referencePrice` | 2 USDC | `BondDepository` constructor |

---

**See also:**
- [Guide 3: Technical Architecture](./03-architecture.md)
- [Guide 5: Implementation](./05-implementation.md)
