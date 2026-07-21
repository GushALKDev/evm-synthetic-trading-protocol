# 📚 Complete Guide: Synthetic Trading Protocol

**Version:** 1.0  
**Status:** Portfolio/Educational Project

> ⚠️ **DISCLAIMER:** This is a **Proof of Concept with an educational purpose**. It has **not been
> audited by an external firm** and **must not be used in production** or with real funds.

---

## 🎯 Quick Start

| Document                    | Description                        | Status      |
| :-------------------------- | :--------------------------------- | :---------- |
| **[README](../README.md)**      | Project overview and setup         | ✅ Complete |
| **[ROADMAP](./ROADMAP.md)**     | Implementation phases and progress | ✅ Complete |
| **[Test Suite](./tests/)**      | Tests, invariants, static analysis | ✅ Complete |
| **[LICENSE](../LICENSE)**       | MIT License                        | ✅ Complete |

---

## 📖 Technical Guides

### Core Concepts (Start Here)

1. **[Fundamental Concepts](./01-fundamentals.md)**
    - What is synthetic trading?
    - Single-Sided Liquidity (SSL) model
    - Key differences vs traditional DEXs
    - Core actors and their incentives

2. **[Protocol Mathematics](./02-mathematics.md)**
    - PnL calculation formulas
    - Funding rates mechanism
    - Dynamic spread calculation
    - Liquidation thresholds
    - Adaptive OI based on volatility

### Architecture & Implementation

3. **[Technical Architecture & Data Flow](./03-architecture.md)**
    - Component diagram
    - Oracle System (Pyth + Chainlink)
    - Oracle Architecture Decision Record (DON → Pyth migration)
    - Contract descriptions
    - Detailed execution flows
    - Design patterns (CEI, Diamond, Pull over Push)

4. **[Trade-offs, Problems, and Solutions](./04-tradeoffs.md)**
    - Latency arbitrage (Toxic Flow)
    - Solvency risk (LP Rekt)
    - Liquidation front-running
    - Oracle manipulation
    - Stablecoin depeg risk
    - Risk matrix

5. **[Solidity Implementation](./05-implementation.md)**
    - Tech stack (Foundry, Solady, Pyth SDK)
    - Data structures (Trade, Pair, Oracle)
    - Contract interfaces
    - Security patterns (Custom errors, CEI, Access control)
    - Numerical precision handling
    - Pre-deployment checklist

### Advanced Topics

6. **[Future Improvements](./06-improvements.md)**
    - Advanced orders (Limit, TP/SL automation)
    - Multi-collateral vault
    - Tiered fees and volume discounts
    - Referral system
    - NFT boost for LPs
    - On-chain copy trading
    - Account abstraction (ERC-4337)

7. **[Vault SSL Architecture](./07-vault-ssl.md)**
    - ERC-4626 Vault mechanics
    - PnL and accounting
    - 3-layer solvency system:
        - Layer 1: Preventive (Profit caps, Dynamic spreads)
        - Layer 2: Reactive (Assistant Fund)
        - Layer 3: Last resort (Token minting & Bonding)
    - Dynamic defense logic
    - Adaptive OI based on volatility

8. **[Security](./08-security.md)**
    - Threat model
    - Access control matrix
    - System invariants
    - Attack vectors and mitigations
    - Circuit breakers
    - Emergency procedures
    - Audit checklist
    - Bug bounty scope

### Testing

9. **[Test Suite](./tests/README.md)**
    - What each test group covers and why
    - Invariants and the properties they protect
    - Fuzz tests over the financial math
    - Fork tests against real Pyth/Chainlink feeds
    - Coverage report
    - Static analysis (Slither, Aderyn) and findings review

---

## 🗂️ Documentation Structure

```
docs/
├── README.md                    # This file
├── ROADMAP.md                   # Implementation roadmap
│
├── 01-fundamentals.md           # Start here
├── 02-mathematics.md            # Core formulas
├── 03-architecture.md           # System design
├── 04-tradeoffs.md              # Risk analysis
├── 05-implementation.md         # Solidity code
├── 06-improvements.md           # Future features
├── 07-vault-ssl.md              # Vault deep dive
├── 08-security.md               # Security analysis
│
└── tests/
    └── README.md                # Test suite, invariants, static analysis
```

---

## 🎓 Recommended Reading Order

### For Developers

1. [Fundamental Concepts](./01-fundamentals.md) - Understand the model
2. [Protocol Mathematics](./02-mathematics.md) - Learn the formulas
3. [Technical Architecture](./03-architecture.md) - See how it fits together
4. [Solidity Implementation](./05-implementation.md) - Study the code
5. [Security](./08-security.md) - Understand the risks
6. [ROADMAP](./ROADMAP.md) - See implementation phases

### For Auditors

1. [Technical Architecture](./03-architecture.md) - System overview
2. [Vault SSL Architecture](./07-vault-ssl.md) - Critical component
3. [Security](./08-security.md) - Threat model and invariants
4. [Test Suite](./tests/README.md) - Coverage, invariants, static analysis
5. [Trade-offs](./04-tradeoffs.md) - Known risks
6. [Solidity Implementation](./05-implementation.md) - Code patterns

### For Researchers

1. [Fundamental Concepts](./01-fundamentals.md) - Model introduction
2. [Protocol Mathematics](./02-mathematics.md) - Mathematical foundation
3. [Trade-offs](./04-tradeoffs.md) - Design decisions
4. [Future Improvements](./06-improvements.md) - Research directions

---

## 📊 Progress Tracking

See [ROADMAP.md](./ROADMAP.md) for detailed implementation progress.

**Current Status:** Phases 0–12 complete ✅ — 530 tests, 100% line coverage on all `src/` contracts.
Phase 13 (V2) is a backlog of theoretical improvements and is not counted toward completion.

---

---

## 📝 Contributing

This is a portfolio/educational project. While not actively seeking contributions, feedback and suggestions are welcome via issues.

---

## ⚖️ License

This project is licensed under the MIT License - see the [LICENSE](../LICENSE) file for details.

---

## 🔗 External Resources

- **Foundry Documentation:** https://book.getfoundry.sh/
- **ERC-4626 Standard:** https://eips.ethereum.org/EIPS/eip-4626
- **OpenZeppelin Contracts:** https://docs.openzeppelin.com/contracts/
- **Pyth Network:** https://docs.pyth.network/ (primary oracle)
- **Chainlink Price Feeds:** https://docs.chain.link/data-feeds (deviation anchor)
- **GMX Documentation:** https://gmx-docs.io/ (reference implementation)
- **Gains Network Docs:** https://gains-network.gitbook.io/ (reference implementation)

---

**Maintained by:** @GushALKDev (Portfolio Project)
