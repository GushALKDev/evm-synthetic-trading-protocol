# 🔮 Synthetic Trading Protocol (In progress...)

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](https://opensource.org/licenses/MIT)
[![Solidity](https://img.shields.io/badge/Solidity-0.8.24-363636.svg)](https://docs.soliditylang.org/)
[![Foundry](https://img.shields.io/badge/Built%20with-Foundry-FFDB1C.svg)](https://getfoundry.sh/)

A **decentralized synthetic leverage trading protocol** with single-sided liquidity. Trade crypto, forex, and commodities with up to 100x leverage — no order books, no counterparty matching.

> ⚠️ **DISCLAIMER:** This is a portfolio/educational project demonstrating advanced smart contract development. **All code is written from scratch.** NOT audited — do not use in production.

---

## 🎯 What is this?

A DeFi protocol where:

- **Traders** open leveraged Long/Short positions on any asset
- **LPs (Liquidity Providers)** deposit USDC and act as the counterparty ("The House")
- **Off-chain bots** (via EOAs) execute liquidations and automated operations

No order books. No AMM curves. Just oracle-priced synthetic exposure.

```
┌─────────────────────────────────────────────────────────────────┐
│                            THE MODEL                            │
│                                                                 │
│   TRADERS ──────┐                                               │
│   (Bet on       │         ┌──────────────────┐                  │
│    price)       ├────────►│                  │                  │
│                 └◄────────┤   VAULT (USDC)   │◄────── LPs       │
│   Win = Payout            │   "The House"    │        (Provide  │
│   Lose = Loss             │                  │         USDC)    │
│   to Vault                └──────────────────┘                  │
│                                    │                            │
│                                    ▼                            │
│                           Traders lose → LPs profit             │
│                           Traders win  → LPs pay                │
└─────────────────────────────────────────────────────────────────┘
```

---

## ✨ Key Features

| Feature                          | Description                                                      |
| :------------------------------- | :--------------------------------------------------------------- |
| **Single-Sided Liquidity (SSL)** | LPs only deposit USDC. No impermanent loss from pair imbalance.  |
| **ERC-4626 Vault**               | Tokenized vault shares (sToken) following the standard.          |
| **DON Oracle Aggregation**       | 6-8 oracle nodes, median of 3 best prices, Chainlink validation. |
| **Dynamic Spread**               | Spread increases with OI and volatility to protect the Vault.    |
| **Adaptive OI Caps**             | Higher volatility = lower max Open Interest allowed.             |
| **3-Layer Solvency**             | Profit caps → Assistant Fund → Token Bonding.                    |
| **Liquidation System**           | 90% loss threshold with keeper incentives.                       |

---

## 🏗️ Architecture

```
              ┌────────────────────────────────────────┐
              │             TRADING ENGINE             │
              │   (openTrade, closeTrade, liquidate).  │
              └───────────────────┬────────────────────┘
                                  │
          ┌───────────────────────┼────────────────────────┐
          │                       │                        │
          ▼                       ▼                        ▼
┌─────────────────┐      ┌─────────────────┐      ┌─────────────────┐
│  TRADING        │      │   VAULT         │      │   ORACLE        │
│  STORAGE        │      │   (ERC-4626)    │      │   AGGREGATOR    │
│                 │      │                 │      │                 │
│  • Trades       │      │  • LP USDC      │      │  • DON nodes    │
│  • Collateral   │      │  • LP shares    │      │  • Chainlink    │
│  • Open Interest│      │  • Payouts      │      │  • Median calc  │
│  • Pairs config │      │                 │      │                 │
└─────────────────┘      └────────┬────────┘      └─────────────────┘
                                  │
                      ┌───────────┴───────────┐
                      │   SOLVENCY MANAGER    │
                      │                       │
                      │  • Assistant Fund     │
                      │  • Bond Depository    │
                      └───────────────────────┘
```

---

## 📚 Documentation

Comprehensive documentation is available in [`/docs`](./docs/):

### English Documentation

| Document                                                      | Description                                 |
| :------------------------------------------------------------ | :------------------------------------------ |
| **[📋 Complete Index](./docs/INDEX.md)**                      | Master index - start here                   |
| **[🗺️ Roadmap](./docs/ROADMAP.md)**                           | Implementation phases & progress (89 items) |
| **[📖 Guide 1: Fundamentals](./docs/01-fundamentals.md)**     | Core concepts & SSL model                   |
| **[🔢 Guide 2: Mathematics](./docs/02-mathematics.md)**       | PnL, funding rates, spreads                 |
| **[⚙️ Guide 3: Architecture](./docs/03-architecture.md)**     | Contracts, DON, data flows                  |
| **[⚖️ Guide 4: Trade-offs](./docs/04-tradeoffs.md)**          | Risks & mitigations                         |
| **[💻 Guide 5: Implementation](./docs/05-implementation.md)** | Solidity patterns & code                    |
| **[🚀 Guide 6: Improvements](./docs/06-improvements.md)**     | Future features (V2)                        |
| **[🏦 Guide 7: Vault SSL](./docs/07-vault-ssl.md)**           | ERC-4626 & 3-layer solvency                 |
| **[🔒 Guide 8: Security](./docs/08-security.md)**             | Threat model & invariants                   |

## 🛠️ Tech Stack

| Component           | Technology                    |
| :------------------ | :---------------------------- |
| **Smart Contracts** | Solidity 0.8.24               |
| **Framework**       | Foundry                       |
| **Testing**         | Forge (unit, fuzz, invariant) |
| **Libraries**       | OpenZeppelin, Solady          |
| **Oracles**         | Chainlink + Custom DON        |
| **Standards**       | ERC-4626, ERC-20              |

---

## 🚀 Getting Started

### Prerequisites

- [Foundry](https://getfoundry.sh/)
- Git

### Installation

```bash
# Clone the repository
git clone https://github.com/GushALKDev/synthetic-trading-protocol.git
cd synthetic-trading-protocol

# Install dependencies
forge install

# Build
forge build

# Run tests
forge test

# Run tests with coverage
forge coverage
```

### Local Development

```bash
# Start local node
anvil

# Deploy to local node
forge script script/Deploy.s.sol --rpc-url http://localhost:8545 --broadcast
```

---

## 🧪 Testing

```bash
# Unit tests
forge test

# Fuzz tests (more runs)
forge test --fuzz-runs 10000

# Invariant tests
forge test --match-contract InvariantTest

# Coverage report
forge coverage --report lcov
```

### Key Invariants

The protocol maintains these invariants at all times:

```solidity
assert(vault.totalAssets() >= 0);           // Vault never has negative balance
assert(globalOI <= calculateMaxOI());       // OI never exceeds cap
assert(oracle.getPrice(pair) > 0);          // Oracle always returns valid price
assert(vault.previewRedeem(1e18) > 0);      // Share price always positive
```

---

## 📁 Project Structure

```
synthetic-trading-protocol/
├── docs/                    # Comprehensive documentation
│   ├── INDEX.md            # Master index
│   ├── ROADMAP.md          # Implementation roadmap
│   ├── 01-fundamentals.md  # Guide 1: Core concepts
│   ├── 02-mathematics.md   # Guide 2: Protocol math
│   ├── 03-architecture.md  # Guide 3: System design
│   ├── 04-tradeoffs.md     # Guide 4: Risks & solutions
│   ├── 05-implementation.md # Guide 5: Solidity code
│   ├── 06-improvements.md  # Guide 6: Future features
│   ├── 07-vault-ssl.md     # Guide 7: Vault architecture
│   └── 08-security.md      # Guide 8: Security analysis
├── src/                     # Smart contracts
│   ├── Vault.sol           # ERC-4626 LP liquidity vault
│   └── TradingStorage.sol  # Trade data + collateral custody
├── test/                    # Test files
│   ├── unit/               # Unit tests
│   ├── fuzz/               # Fuzz tests
│   └── invariant/          # Invariant tests
├── script/                  # Deployment scripts
├── LICENSE                  # MIT License
└── README.md
```

---

## 🎓 What This Project Demonstrates

This project showcases advanced smart contract development skills through **original implementation from scratch**:

**Documentation (Complete):**

- [x] ERC-4626 tokenized vault architecture
- [x] Complex DeFi math (PnL, funding rates, liquidations, dynamic pricing)
- [x] Oracle design with multi-source aggregation
- [x] Risk management (adaptive OI caps, solvency mechanisms)
- [x] Security patterns (CEI, access control, circuit breakers)
- [x] Production-grade architecture documentation (~8,200 lines)

**Implementation (In Progress — Phases 1–9 complete, 64/96 items):**

- [x] Core contracts (Vault, TradingStorage)
- [x] Core contracts (TradingEngine, PythChainlinkOracle via IOracle)
- [x] Fee system, funding rates, dynamic spread (SpreadManager)
- [x] Liquidations (permissionless, funding-adjusted, conf-based conservative pricing)
- [x] Limit orders / automatic TP/SL (permissionless executeLimit, executor reward)
- [x] Solvency Layer 2 (AssistantFund reserve, skimmable overflow)
- [x] Testing (unit + fuzz + fork; 443 tests)
- [ ] Solvency Layer 3 (SolvencyManager, Bond Depository)
- [ ] Invariant testing, deployment scripts

---

## 🤝 Contributing

This is a portfolio project, but contributions are welcome! Feel free to:

- Open issues for bugs or suggestions
- Submit PRs for improvements
- Fork and adapt for your own learning

---

## 📜 License

This project is licensed under the **MIT License** - see the [LICENSE](./LICENSE) file for details.

---

## 👤 Author

**[GushALKDev]**

- GitHub: [@GushALKDev](https://github.com/GushALKDev)
- LinkedIn: [Gustavo Martín](https://www.linkedin.com/in/gustavomaral/)

---

## 🙏 Acknowledgments

- [OpenZeppelin](https://openzeppelin.com/) - Security standards and contract libraries
- [Foundry](https://getfoundry.sh/) - Development framework and testing suite
- [Chainlink](https://chain.link/) - Oracle infrastructure reference
- [Solady](https://github.com/Vectorized/solady) - Gas-optimized libraries
- [Gains Network](https://gains.trade/) - Architectural inspiration

---

<p align="center">
  <i>Built with ❤️ to demonstrate what's possible in DeFi</i>
</p>
