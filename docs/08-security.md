# 🔒 Guide 8: Security

**Version:** 1.0
**Prerequisites:** [Guide 7: Vault SSL Architecture](./07-vault-ssl.md)
**Next:** [Master Index](../README.md)

---

## 📋 Table of Contents

1. [Threat Model](#1-threat-model)
2. [Access Control Matrix](#2-access-control-matrix)
3. [System Invariants](#3-system-invariants)
4. [Attack Vectors and Mitigations](#4-attack-vectors-and-mitigations)
5. [Circuit Breakers](#5-circuit-breakers)
6. [Emergency Process](#6-emergency-process)
7. [Audit Checklist](#7-audit-checklist)
8. [Bug Bounty Scope](#8-bug-bounty-scope)

---

## 1. Threat Model

### System Actors

| Actor | Description | Trust Level | Capabilities |
|:---|:---|:---|:---|\
| **Trader** | User opening positions | Untrusted | Can attempt to exploit logic |
| **LP** | Liquidity provider | Untrusted | Can attempt timing attacks |
| **Keeper** | Bot executing TP/SL/Liquidations | Semi-trusted | Can attempt front-running |
| **Admin** | Multisig with parameter control | Trusted | Can change configuration (with timelock) |
| **Pyth Publisher** | Data publisher (exchange, market maker) | Semi-trusted | Subject to Oracle Integrity Staking (slashing) |
| **Attacker** | External malicious agent | Untrusted | All attack vectors |

### Critical Assets

| Asset | Location | Value at Risk | Protection |
|:---|:---|:---|:---|\
| Vault USDC | `LiquidityVault.sol` | Total TVL | Access control, CEI |
| Trade Data | `TradingStorage.sol` | Integrity | Only TradingEngine writes |
| Oracle Prices | `OracleAggregator.sol` | Fairness | Pyth (128+ publishers) + Chainlink deviation anchor |
| $SYNTH Token | `SynthToken.sol` | Market value | Controlled minter role |
| Admin Keys | External multisig | Entire system | Timelock, 3/5 threshold |

---

## 2. Access Control Matrix

### System Roles

| Role | Description | Holders |
|:---|:---|:---|
| `DEFAULT_ADMIN_ROLE` | Can assign/revoke roles | Multisig + Timelock |
| `TRADING_ROLE` | Can interact with Vault for payments | TradingEngine.sol |
| `KEEPER_ROLE` | Can execute limits/liquidations | Keeper bots |
| `PAUSER_ROLE` | Can pause system | Multisig (no timelock) |
| `MINTER_ROLE` | Can mint $SYNTH | BondDepository.sol |
| `MANAGER_ROLE` | Can adjust parameters | Multisig + Timelock |

### Permission Matrix by Contract

#### LiquidityVault.sol

| Function | PUBLIC | TRADING | ADMIN | PAUSER |
|:---|:---|:---|:---|:---|\
| `deposit()` | ✅ | - | - | when not paused |
| `withdraw()` | ✅ | - | - | when not paused |
| `sendPayout()` | ❌ | ✅ | - | - |
| `receiveLoss()` | ❌ | ✅ | - | - |
| `pause()` | ❌ | - | - | ✅ |
| `setEmergencyWithdraw()` | ❌ | - | ✅ | - |

#### TradingEngine.sol

| Function | PUBLIC | KEEPER | ADMIN | PAUSER |
|:---|:---|:---|:---|:---|\
| `openTrade()` | ✅ | - | - | when not paused |
| `closeTrade()` | ✅ (owner) | - | - | - |
| `updateTP/SL()` | ✅ (owner) | - | - | - |
| `liquidate()` | ✅ | - | - | - |
| `executeLimit()` | ❌ | ✅ | - | - |
| `updatePair()` | ❌ | - | ✅ | - |
| `pause()` | ❌ | - | - | ✅ |

#### BondDepository.sol

| Function | PUBLIC | SOLVENCY | ADMIN |
|:---|:---|:---|:---|\
| `deposit()` | ✅ | - | when active |
| `activateBonding()` | ❌ | ✅ | - |
| `deactivateBonding()` | ❌ | ✅ | ✅ |
| `setDiscount()` | ❌ | - | ✅ (timelock) |

---

## 3. System Invariants

The following properties must **NEVER** be broken. They are the basis for invariant tests.

### Solvency Invariants

```solidity
// INV-1: Vault can never have negative debt
assert(vault.totalAssets() >= 0);

// INV-2: Pending payouts never exceed available assets
assert(sumOfPendingPayouts <= vault.totalAssets());

// INV-3: If CR < 100%, solvency MUST be activated
if (vault.collateralizationRatio() < 1e18) {
    assert(solvencyManager.isActive());
}
```

### Trading Invariants

```solidity
// INV-4: Open Interest never exceeds calculated maximum
assert(globalOpenInterest <= calculateMaxExposure());

// INV-5: No trade can have PnL > MAX_MULTIPLIER × collateral
for (trade in allTrades) {
    int256 pnl = calculatePnL(trade);
    assert(pnl <= int256(trade.collateral * MAX_MULTIPLIER));
}

// INV-6: Liquidation price is always within valid range
for (trade in allTrades) {
    uint256 liqPrice = calculateLiquidationPrice(trade);
    assert(liqPrice > 0);
    if (trade.isLong) {
        assert(liqPrice < trade.openPrice);
    } else {
        assert(liqPrice > trade.openPrice);
    }
}
```

### Oracle Invariants

```solidity
// INV-7: Validated price is never 0
assert(oracle.getValidatedPrice(priceUpdate, pairIndex) > 0);

// INV-8: Pyth price doesn't deviate more than MAX_DEVIATION from Chainlink
// (enforced by OracleAggregator — reverts if exceeded)
uint256 pythPrice = oracle.getValidatedPrice(priceUpdate, pairIndex);
uint256 clPrice = chainlink.latestAnswer();
uint256 deviation = abs(pythPrice - clPrice) * 1e18 / clPrice;
assert(deviation <= MAX_DEVIATION);

// INV-8b: Pyth price is never stale (staleness > MAX_STALENESS → revert, no fallback)
// (enforced by Pyth's getPriceNoOlderThan — cannot be bypassed)
```

### Token Invariants

```solidity
// INV-9: Only BondDepository can mint SYNTH
assert(synthToken.minter() == address(bondDepository));

// INV-10: Share price always > 0
assert(vault.previewRedeem(1e18) > 0);
```

---

## 4. Attack Vectors and Mitigations

### 4.1 Reentrancy Attack

**Vector:** Malicious callback during external transfer.

**Mitigation:**
```solidity
function closeTrade(uint256 tradeId) external nonReentrant {
    // ... EFFECTS first ...
    delete trades[tradeId];
    
    // ... INTERACTIONS last ...
    vault.sendPayout(msg.sender, payout);
}
```

### 4.2 Oracle Manipulation

**Vector:** Submit manipulated or adversarial price data to execute trades at favorable prices.

**Mitigation:**
- DO NOT use DEX pools as oracles.
- **Pyth Wormhole verification:** All prices are cryptographically signed by publishers and verified on-chain. Cannot be forged.
- **128+ publishers** with Oracle Integrity Staking (slashing for inaccurate data). Manipulation requires compromising a significant fraction.
- **Chainlink deviation anchor:** Pyth price must be within `MAX_DEVIATION` of Chainlink — catches anomalous Pyth prices.
- **Confidence interval check:** Wide confidence (publisher disagreement) → revert.
- **Staleness check:** Only prices within `MAX_STALENESS` (10-30s) are accepted — no stale price exploitation.

### 4.3 Front-Running (Latency Arbitrage)

**Vector:** See future price on CEX, open trade before oracle update.

**Mitigation:**
- **Pyth sub-second updates:** 400ms refresh rate from first-party publishers significantly narrows the arbitrage window.
- **Strict staleness:** `MAX_STALENESS` of 10-30 seconds ensures the price included in the transaction is recent.
- **Adversarial price selection defense:** User submits the price, but it must pass staleness + confidence + Chainlink deviation checks. They cannot submit an old favorable price.
- Dynamic spread based on OI (Phase 4).

### 4.4 Sandwich Attack on LP Withdrawals

**Vector:**
1. See large pending withdrawal.
2. Open winning trade before.
3. Share price drops.
4. LP withdraws at low price.

**Mitigation:**
- Withdrawal request system with 3-epoch delay.
- Share price at request time is NOT guaranteed.

### 4.5 Griefing Liquidations

**Vector:** Keep positions just above threshold to avoid cheap liquidation.

**Mitigation:**
- Keepers incentivized with fixed reward.
- Phase 2: Lookbacks allowing liquidation if price touched threshold.

### 4.6 DOS via Gas

**Vector:** Make functions consume more gas than expected.

**Mitigation:**
- Limits on loops (max trades per user = 10).
- Batch processing patterns when necessary.
- Gas estimation in frontend.

---

## 5. Circuit Breakers

Automatic pause mechanisms under anomalous conditions.

### 5.1 Price Circuit Breaker

```solidity
uint256 constant MAX_SINGLE_BLOCK_DEVIATION = 5e16; // 5%

function _checkCircuitBreaker(uint256 pairIndex, uint256 newPrice) internal {
    uint256 lastPrice = lastPrices[pairIndex];
    
    if (lastPrice > 0) {
        uint256 deviation = abs(newPrice - lastPrice) * 1e18 / lastPrice;
        
        if (deviation > MAX_SINGLE_BLOCK_DEVIATION) {
            _pauseTrading(pairIndex);
            emit CircuitBreakerTriggered(pairIndex, deviation);
        }
    }
    
    lastPrices[pairIndex] = newPrice;
}
```

### 5.2 Volume Circuit Breaker

```solidity
uint256 constant MAX_HOURLY_VOLUME = 10_000_000e18; // $10M

function _checkVolumeLimit(uint256 amount) internal {
    uint256 hourStart = block.timestamp / 1 hours * 1 hours;
    
    if (hourStart > lastVolumeReset) {
        hourlyVolume = 0;
        lastVolumeReset = hourStart;
    }
    
    hourlyVolume += amount;
    
    if (hourlyVolume > MAX_HOURLY_VOLUME) {
        _pauseAllTrading();
        emit VolumeCircuitBreaker(hourlyVolume);
    }
}
```

### 5.3 Solvency Circuit Breaker

```solidity
uint256 constant CRITICAL_CR = 90e16; // 90%

function _checkSolvency() internal {
    uint256 cr = vault.collateralizationRatio();
    
    if (cr < CRITICAL_CR) {
        _pauseAllTrading();
        _activateEmergencyMode();
        emit SolvencyCircuitBreaker(cr);
    }
}
```

---

## 6. Emergency Process

### Emergency Levels

| Level | Trigger | Actions | Authority |
|:---|:---|:---|:---|\
| **1 - Warning** | CR < 110% | Intensive monitoring | Automatic |
| **2 - Caution** | CR < 100% | Activate Assistant Fund | Automatic |
| **3 - Emergency** | CR < 95% | Activate Bonding | Automatic |
| **4 - Critical** | CR < 90% | Pause trading, emergency mode | Automatic + Multisig |
| **5 - Shutdown** | Exploit detected | Pause all, emergency withdrawals | Immediate multisig |

### Emergency Withdrawal for LPs

In case of Level 5, LPs can withdraw without waiting for timelock:

```solidity
bool public emergencyWithdrawEnabled;

function emergencyWithdraw() external {
    if (!emergencyWithdrawEnabled) revert NotInEmergency();
    
    uint256 shares = balanceOf(msg.sender);
    uint256 assets = previewRedeem(shares);
    
    // Possible penalty if open positions exist
    uint256 penalty = _calculateEmergencyPenalty();
    assets = assets - penalty;
    
    _burn(msg.sender, shares);
    IERC20(usdc).safeTransfer(msg.sender, assets);
}
```

### Post-Mortem Process

1. **Detection:** Circuit breaker or community report.
2. **Pause:** Multisig pauses system (no timelock for pause).
3. **Analysis:** Investigate root cause.
4. **Fix:** Develop and audit patch.
5. **Compensation:** Plan for affected users.
6. **Resume:** Deploy fix, resume operations.
7. **Disclosure:** Publish complete post-mortem.

---

## 7. Audit Checklist

### Pre-Audit

- [ ] Final code frozen (no changes during audit)
- [ ] Tests with >95% coverage
- [ ] Fuzzing of all mathematical functions
- [ ] Invariant tests passing
- [ ] Slither with no critical/high findings
- [ ] Aderyn with no critical findings
- [ ] Complete architecture documentation

### During Audit

- [ ] Private repo access for auditors
- [ ] Direct communication channel
- [ ] Respond to queries in <24h
- [ ] Don't push changes without coordination

### Post-Audit

- [ ] Fixes for all critical/high findings
- [ ] Auditor review of fixes
- [ ] Final report published
- [ ] Bug bounty launched before mainnet

---

## 8. Bug Bounty Scope

### In Scope

| Contract | Maximum Severity |
|:---|:---|
| LiquidityVault.sol | Critical |
| TradingEngine.sol | Critical |
| TradingStorage.sol | High |
| OracleAggregator.sol | Critical |
| SolvencyManager.sol | Critical |
| AssistantFund.sol | High |
| BondDepository.sol | High |
| SynthToken.sol | High |

### Out of Scope

- Third-party contracts (Solady, Pyth SDK, Chainlink)
- Frontend/UI vulnerabilities
- Documented centralization risks
- Attacks requiring >51% stake in $SYNTH
- Social engineering

### Payouts

| Severity | Impact | Reward |
|:---|:---|:---|\
| **Critical** | Loss of user/protocol funds | $50,000 - $150,000 |
| **High** | Fund freezing, price manipulation | $10,000 - $50,000 |
| **Medium** | Griefing, temporary DOS | $2,000 - $10,000 |
| **Low** | Minor issues, improvements | $500 - $2,000 |

### Disclosure Rules

1. Report first to security@synthetictrading.protocol
2. Don't publish before fix deployed (90 days max)
3. Don't exploit on mainnet/public testnet
4. Provide reproducible PoC
5. One vulnerability per report

---

**See also:**
- [Guide 4: Trade-offs and Problems](./04-tradeoffs.md) - Risk analysis
- [Guide 5: Solidity Implementation](./05-implementation.md) - Security patterns in code
