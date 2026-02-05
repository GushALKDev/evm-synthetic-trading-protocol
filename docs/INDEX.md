# 📚 Complete Guide: Synthetic Trading Protocol

**Version:** 1.0  
**Status:** Portfolio/Educational Project

---

## 🎯 Quick Start

| Document | Description | Status |
|:---|:---|:---|
| **[README](../README.md)** | Project overview and setup | ✅ Complete |
| **[ROADMAP](./ROADMAP.md)** | Implementation phases and progress | ✅ Complete |
| **[LICENSE](../LICENSE)** | MIT License | ✅ Complete |

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
   - Decentralized Oracle Network (DON)
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
   - Tech stack (Foundry, OpenZeppelin, Solady)
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
└── es/                          # Spanish documentation
    ├── INDICE.md                # Spanish index
    ├── GUIA_1_CONCEPTOS_FUNDAMENTALES.md
    ├── GUIA_2_MATEMATICAS_PROTOCOLO.md
    ├── GUIA_3_ARQUITECTURA_TECNICA.md
    ├── GUIA_4_TRADEOFFS_PROBLEMAS.md
    ├── GUIA_5_IMPLEMENTACION_SOLIDITY.md
    ├── GUIA_6_MEJORAS_SUGERIDAS.md
    ├── GUIA_7_ARQUITECTURA_VAULT_SSL.md
    └── GUIA_8_SEGURIDAD.md
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
4. [Trade-offs](./04-tradeoffs.md) - Known risks
5. [Solidity Implementation](./05-implementation.md) - Code patterns

### For Researchers

1. [Fundamental Concepts](./01-fundamentals.md) - Model introduction
2. [Protocol Mathematics](./02-mathematics.md) - Mathematical foundation
3. [Trade-offs](./04-tradeoffs.md) - Design decisions
4. [Future Improvements](./06-improvements.md) - Research directions

---

## 📊 Progress Tracking

See [ROADMAP.md](./ROADMAP.md) for detailed implementation progress across 13 phases and 89 trackable items.

**Current Status:** Phase 0 (Documentation) - Complete ✅

---

## 🌐 Language Versions

- **English:** This directory (`docs/*.md`)
- **Spanish:** `docs/es/` directory

Both versions are maintained in parallel and contain identical technical content.

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
- **Chainlink Price Feeds:** https://docs.chain.link/data-feeds
- **GMX Documentation:** https://gmx-docs.io/ (reference implementation)
- **Gains Network Docs:** https://gains-network.gitbook.io/ (reference implementation)

---

**Last Updated:** February 5, 2026  
**Maintained by:** @gush (Portfolio Project)
